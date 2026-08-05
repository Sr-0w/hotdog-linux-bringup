#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source "$(dirname "$0")/env.sh"
# shellcheck disable=SC1091
source "$(dirname "$0")/phone-lock.sh"

PYTHON_BIN="${EDL_PYTHON_BIN:-$HOTDOG_ROOT/tools/venvs/edl/bin/python}"
EDL_SOURCE="${EDL_SOURCE:-$HOTDOG_ROOT/src/qualcomm/edl}"
HELPER="$HOTDOG_ROOT/helpers/hotdog_sahara_900e.py"
RAMOOPS_EXTRACTOR="$HOTDOG_ROOT/scripts/extract-ramoops-console.py"
RAMOOPS_PHYS=0xa9800000
RAMOOPS_SIZE=0x400000

usage() {
	cat <<'USAGE'
Usage: qualcomm-900e-autorescue.sh inspect [--early-breadcrumb-address ADDRESS]
       [--read-memory ADDRESS LENGTH] [--extract-ramoops]
       [--extract-kmsg] [--list-memory-regions]
       qualcomm-900e-autorescue.sh recover
       qualcomm-900e-autorescue.sh state-reset
       qualcomm-900e-autorescue.sh reset

Operate on the configured hotdog target only while Qualcomm 05c6:900e is
visible. "inspect" reads the experimental breadcrumb and restart reason from
physical memory. "recover" resets the Sahara state machine and follows its
fresh handshake with SAHARA_RESET_REQ. "state-reset" sends only
SAHARA_RESET_STATE_MACHINE_ID and "reset" sends only SAHARA_RESET_REQ. None
of these actions reads or writes phone storage. ADDRESS accepts decimal or a
0x-prefixed physical address and reads one additional 64-byte diagnostic
record. --read-memory stores one bounded physical-memory range (maximum 16
MiB) in the new run directory without resetting the target. --extract-ramoops
reads and decodes the pinned 4 MiB hotdog ramoops reservation.
--extract-kmsg reads the firmware-provided KMSG.txt region by name in the same
fresh Sahara session. It can be combined with --extract-ramoops.
--list-memory-regions reads and prints the Sahara crashdump table without
dumping regions or resetting the target.
USAGE
}

log() {
	printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

die() {
	log "ERROR: $1"
	exit "${2:-1}"
}

cleanup() {
	phone_lock_release || true
}
trap cleanup EXIT

case "${1:-}" in
	-h|--help)
		usage
		exit 0
		;;
	inspect|reset|state-reset|recover)
		action="$1"
		;;
	*)
		usage >&2
		exit 2
		;;
esac
shift

early_breadcrumb_address="${HOTDOG_EARLY_BREADCRUMB_PHYS:-}"
memory_address=""
memory_length=""
extract_ramoops=0
extract_kmsg=0
list_memory_regions=0
while [ "$#" -gt 0 ]; do
	case "$1" in
		--early-breadcrumb-address)
			[ "$action" = inspect ] || die "Early breadcrumb reads require inspect" 2
			[ "$#" -ge 2 ] || die "Missing value for $1" 2
			early_breadcrumb_address="$2"
			shift 2
			;;
		--read-memory)
			[ "$action" = inspect ] || die "Physical memory reads require inspect" 2
			[ "$#" -ge 3 ] || die "Missing address or length for $1" 2
			memory_address="$2"
			memory_length="$3"
			shift 3
			;;
		--extract-ramoops)
			[ "$action" = inspect ] || die "Ramoops extraction requires inspect" 2
			extract_ramoops=1
			shift
			;;
		--extract-kmsg)
			[ "$action" = inspect ] || die "KMSG extraction requires inspect" 2
			extract_kmsg=1
			shift
			;;
		--list-memory-regions)
			[ "$action" = inspect ] || die "Memory-region listing requires inspect" 2
			list_memory_regions=1
			shift
			;;
		*)
			die "Unknown argument: $1" 2
			;;
	esac
done

if [ "$extract_ramoops" -eq 1 ]; then
	[ -z "$memory_address" ] || die "--extract-ramoops cannot be combined with --read-memory" 2
	memory_address="$RAMOOPS_PHYS"
	memory_length="$RAMOOPS_SIZE"
fi

hotdog_require_target_serial
command -v lsusb >/dev/null 2>&1 || die "Missing command: lsusb" 127
[ -x "$PYTHON_BIN" ] || die "Missing EDL Python runtime: $PYTHON_BIN" 127
[ -d "$EDL_SOURCE/edlclient" ] || die "Missing bkerler/edl source: $EDL_SOURCE" 127
[ -r "$HELPER" ] || die "Missing Sahara helper: $HELPER" 127
if [ "$extract_ramoops" -eq 1 ] || [ "$extract_kmsg" -eq 1 ]; then
	command -v python3 >/dev/null 2>&1 || die "Missing command: python3" 127
	command -v sha256sum >/dev/null 2>&1 || die "Missing command: sha256sum" 127
fi
if [ "$extract_ramoops" -eq 1 ]; then
	[ -r "$RAMOOPS_EXTRACTOR" ] || die "Missing ramoops extractor: $RAMOOPS_EXTRACTOR" 127
fi
lsusb -d 05c6:900e 2>/dev/null | grep -q . || die "Qualcomm 05c6:900e is not visible" 3

stamp="$(date +%F-%H%M%S)"
run_dir="$HOTDOG_LOG_ROOT/qualcomm-900e-autorescue-$action-$stamp"
mkdir -p "$run_dir"
exec > >(tee "$run_dir/run.log") 2>&1

log "Run directory: $run_dir"
log "Action: $action"
log "Target serial: $HOTDOG_TARGET_SERIAL"
log "Phone storage access: none"
phone_lock_acquire "Qualcomm 900e Sahara $action" 0 || die "Could not acquire phone-operation lock" 4

helper_args=(
	"$action"
	--edl-source "$EDL_SOURCE"
	--serial "$HOTDOG_TARGET_SERIAL"
)
if [ "$action" = inspect ] && [ -n "$early_breadcrumb_address" ]; then
	helper_args+=(--early-breadcrumb-address "$early_breadcrumb_address")
	log "Additional early breadcrumb: $early_breadcrumb_address (64 bytes)"
fi
if [ "$action" = inspect ] && [ -n "$memory_address" ]; then
	memory_output="$run_dir/physical-memory.bin"
	helper_args+=(
		--memory-address "$memory_address"
		--memory-length "$memory_length"
		--memory-output "$memory_output"
	)
	log "Bounded physical read: $memory_address + $memory_length -> $memory_output"
fi
if [ "$action" = inspect ] && [ "$list_memory_regions" -eq 1 ]; then
	helper_args+=(--list-memory-regions)
	log "Sahara memory-region table: read-only listing"
fi
if [ "$action" = inspect ] && [ "$extract_kmsg" -eq 1 ]; then
	kmsg_output="$run_dir/KMSG.txt"
	helper_args+=(--memory-region KMSG.txt "$kmsg_output")
	log "Firmware KMSG region: read-only named extraction -> $kmsg_output"
fi

"$PYTHON_BIN" -u "$HELPER" "${helper_args[@]}"
log "Sahara $action completed"

if [ "$extract_ramoops" -eq 1 ]; then
	ramoops_console="$run_dir/ramoops-console.txt"
	if python3 "$RAMOOPS_EXTRACTOR" \
		--ddr-phys-base "$RAMOOPS_PHYS" \
		--reservation-phys "$RAMOOPS_PHYS" \
		--reservation-size "$RAMOOPS_SIZE" \
		--scan-reservation "$memory_output" > "$ramoops_console"; then
		log "Ramoops console extracted: $ramoops_console"
	else
		rm -f "$ramoops_console"
		die "No populated ramoops zone found in bounded capture" 5
	fi
fi

if [ "$extract_ramoops" -eq 1 ] || [ "$extract_kmsg" -eq 1 ]; then
	capture_files=()
	if [ "$extract_ramoops" -eq 1 ]; then
		capture_files+=("$memory_output" "$ramoops_console")
	fi
	if [ "$extract_kmsg" -eq 1 ]; then
		capture_files+=("$kmsg_output")
		log "Firmware KMSG extracted: $kmsg_output"
	fi
	sha256sum "${capture_files[@]}" > "$run_dir/SHA256SUMS"
fi
