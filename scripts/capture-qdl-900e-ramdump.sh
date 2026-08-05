#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=/dev/null
source "$(dirname "$0")/env.sh"
# shellcheck source=/dev/null
source "$(dirname "$0")/phone-lock.sh"

QDL_BIN="${QDL_BIN:-$HOTDOG_BIN_ROOT/qdl}"
RAMOOPS_PHYS=0xa9800000
DDRCS0_BASE=0x80000000
RAMOOPS_SIZE=0x400000
RAMOOPS_EXTRACTOR="$HOTDOG_ROOT/scripts/extract-ramoops-console.py"
MODE="${1:-capture}"
FILTER="${QDL_RAMDUMP_FILTER:-}"

usage() {
	cat <<'USAGE'
Usage: capture-qdl-900e-ramdump.sh [capture|preflight]

Capture every RAM region offered by Qualcomm Sahara while 05c6:900e is
visible. The pinned qdl build closes USB without sending a final reset.
Set QDL_RAMDUMP_FILTER only for an intentional filtered diagnostic capture.
USAGE
}

die() {
	printf 'ERROR: %s\n' "$1" >&2
	exit "${2:-1}"
}

cleanup() {
	phone_lock_release || true
}
trap cleanup EXIT

case "$MODE" in
	capture|preflight)
		;;
	-h|--help)
		usage
		exit 0
		;;
	*)
		usage >&2
		die "unknown mode: $MODE" 2
		;;
esac

[ -x "$QDL_BIN" ] || die "missing qdl binary: $QDL_BIN" 127
"$QDL_BIN" ramdump --help 2>&1 | grep -q -- '--skip-reset' ||
	die "qdl lacks ramdump --skip-reset; run scripts/bootstrap-qdl.sh" 127

if [ "$MODE" = preflight ]; then
	printf 'QDL ramdump preflight passed: %s\n' "$QDL_BIN"
	exit 0
fi

hotdog_require_target_serial
command -v lsusb >/dev/null 2>&1 || die "missing command: lsusb" 127
command -v python3 >/dev/null 2>&1 || die "missing command: python3" 127
command -v sha256sum >/dev/null 2>&1 || die "missing command: sha256sum" 127
[ -r "$RAMOOPS_EXTRACTOR" ] || die "missing ramoops extractor: $RAMOOPS_EXTRACTOR" 127

usb_serial="$(lsusb -v -d 05c6:900e 2>/dev/null |
	awk '$1 == "iSerial" { print $3; exit }')"
[ "$usb_serial" = "$HOTDOG_TARGET_SERIAL" ] ||
	die "900e USB iSerial ${usb_serial:-<missing>} does not match target $HOTDOG_TARGET_SERIAL" 3

mapfile -t crash_devices < <("$QDL_BIN" list | awk '$1 == "05c6:900e" { print $2 }')
[ "${#crash_devices[@]}" -eq 1 ] ||
	die "expected exactly one Qualcomm 05c6:900e target, found ${#crash_devices[@]}" 3
crash_serial="${crash_devices[0]}"

stamp="$(date +%F-%H%M%S)"
run_dir="${OUT:-$HOTDOG_LOG_ROOT/qdl-900e-ramdump-$stamp}"
ramdump_dir="$run_dir/ramdump"
mkdir -p "$ramdump_dir"
exec > >(tee "$run_dir/run.log") 2>&1

printf 'Run directory: %s\n' "$run_dir"
printf 'Fastboot target serial: %s\n' "$HOTDOG_TARGET_SERIAL"
printf 'Sahara crash serial: %s\n' "$crash_serial"
printf 'Reset policy: never\n'
printf 'Phone storage access: none\n'
phone_lock_acquire "QDL 900e full RAM capture" 0 ||
	die "could not acquire phone-operation lock" 4

qdl_args=(
	ramdump
	--skip-reset
	--debug
	--serial "$crash_serial"
	--output "$ramdump_dir"
)
if [ -n "$FILTER" ]; then
	qdl_args+=("$FILTER")
	printf 'Segment filter: %s\n' "$FILTER"
else
	printf 'Segment filter: none (all offered regions)\n'
fi

"$QDL_BIN" "${qdl_args[@]}"

find "$ramdump_dir" -maxdepth 1 -type f -printf '%f\t%s\n' | sort > "$run_dir/segments.tsv"

for ddr_name in DDRCS0_0.BIN DDRCS0_1.BIN DDRCS1_0.BIN DDRCS1_1.BIN; do
	ddr_path="$ramdump_dir/$ddr_name"
	[ -r "$ddr_path" ] || die "full RAM capture is missing $ddr_name" 5
	ddr_size="$(stat -c %s "$ddr_path")"
	[ "$ddr_size" -eq 2147483648 ] ||
		die "$ddr_name is incomplete: $ddr_size of 2147483648 bytes" 5
done

ddr_file="$ramdump_dir/DDRCS0_0.BIN"
if [ -r "$ddr_file" ]; then
	ramoops_bin="$run_dir/ramoops-reservation.bin"
	ramoops_skip=$((RAMOOPS_PHYS - DDRCS0_BASE))
	dd if="$ddr_file" of="$ramoops_bin" iflag=skip_bytes,count_bytes \
		skip="$ramoops_skip" count="$((RAMOOPS_SIZE))" status=none
	python3 "$RAMOOPS_EXTRACTOR" \
		--ddr-phys-base "$RAMOOPS_PHYS" \
		--reservation-phys "$RAMOOPS_PHYS" \
		--reservation-size "$RAMOOPS_SIZE" \
		--scan-reservation "$ramoops_bin" > "$run_dir/ramoops-console.txt" || true
	sha256sum "$ramoops_bin" > "$run_dir/ramoops-SHA256SUMS"
fi

if [ -r "$ramdump_dir/minidump.elf" ]; then
	printf 'Minidump ELF: %s\n' "$ramdump_dir/minidump.elf"
else
	printf 'Minidump ELF: unavailable; raw DDR segments retained\n'
fi
printf 'QDL full RAM capture completed without reset\n'
