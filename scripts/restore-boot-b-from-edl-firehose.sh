#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/env.sh"
source "$(dirname "$0")/phone-lock.sh"

MODE="validate"
LUN="${LUN:-4}"
PARTITION="${PARTITION:-boot_b}"
EXPECTED_BYTES="${EXPECTED_BYTES:-100663296}"
LOADER="${LOADER:-$HOTDOG_ROOT/downloads/oneplus-unbrick/EU_HD01BA_Q/ops-decrypt/prog_firehose_ddr.elf}"
RESTORE_IMAGE="${RESTORE_IMAGE:-$HOTDOG_ROOT/images/recovery/edl-restore/boot_b-pmos-stable-padded-100663296.img}"
EDL_BIN="${EDL_BIN:-$HOTDOG_ROOT/tools/bin/edl}"
COMMAND_TIMEOUT_SEC="${COMMAND_TIMEOUT_SEC:-180}"
AFTER_WRITE_RESET="${AFTER_WRITE_RESET:-1}"

usage() {
	cat <<'EOF'
Usage: restore-boot-b-from-edl-firehose.sh [options]

Validate or restore the known-good pmOS boot_b image through Qualcomm EDL
Firehose. The default mode is read-only validation. Writing requires --write.

Safety rules:
  - refuses to run unless USB currently shows Qualcomm 05c6:9008
  - refuses to run on 05c6:900e crashdump/memory-debug mode
  - validates live GPT on UFS LUN 4 and reads boot_b before any write
  - writes only boot_b, and only when --write is explicit

Options:
  --validate-only       Read-only validation. Default.
  --write               Write the restore image to boot_b after validation.
  --loader FILE         Firehose loader. Default: official OPS prog_firehose_ddr.elf.
  --restore-image FILE  Padded boot_b image to write in --write mode.
  --edl FILE            edl executable path.
  --lun N               UFS LUN for boot_b. Default: 4.
  --partition NAME      Partition name. Default: boot_b.
  --expected-bytes N    Expected boot_b/image size. Default: 100663296.
  --no-reset            Do not send Firehose reset after successful write.
  --timeout SEC         Timeout for each edl command. Default: 180.
  -h, --help            Show this help.
EOF
}

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

log() {
	printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--validate-only)
			MODE="validate"
			;;
		--write)
			MODE="write"
			;;
		--loader)
			[ "$#" -ge 2 ] || die "--loader requires a value"
			LOADER="$2"
			shift
			;;
		--restore-image)
			[ "$#" -ge 2 ] || die "--restore-image requires a value"
			RESTORE_IMAGE="$2"
			shift
			;;
		--edl)
			[ "$#" -ge 2 ] || die "--edl requires a value"
			EDL_BIN="$2"
			shift
			;;
		--lun)
			[ "$#" -ge 2 ] || die "--lun requires a value"
			LUN="$2"
			shift
			;;
		--partition)
			[ "$#" -ge 2 ] || die "--partition requires a value"
			PARTITION="$2"
			shift
			;;
		--expected-bytes)
			[ "$#" -ge 2 ] || die "--expected-bytes requires a value"
			EXPECTED_BYTES="$2"
			shift
			;;
		--no-reset)
			AFTER_WRITE_RESET=0
			;;
		--timeout)
			[ "$#" -ge 2 ] || die "--timeout requires a value"
			COMMAND_TIMEOUT_SEC="$2"
			shift
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			die "unknown argument: $1"
			;;
	esac
	shift
done

case "$MODE" in
	validate|write)
		;;
	*)
		die "invalid mode: $MODE"
		;;
esac

[[ "$LUN" =~ ^[0-9]+$ ]] || die "--lun must be numeric: $LUN"
[[ "$EXPECTED_BYTES" =~ ^[0-9]+$ ]] || die "--expected-bytes must be numeric: $EXPECTED_BYTES"
[[ "$COMMAND_TIMEOUT_SEC" =~ ^[0-9]+$ ]] || die "--timeout must be numeric: $COMMAND_TIMEOUT_SEC"
[ -x "$EDL_BIN" ] || die "missing edl executable: $EDL_BIN"
[ -s "$LOADER" ] || die "missing loader: $LOADER"
command -v lsusb >/dev/null 2>&1 || die "missing lsusb"
command -v sha256sum >/dev/null 2>&1 || die "missing sha256sum"
command -v stat >/dev/null 2>&1 || die "missing stat"

if [ "$MODE" = "write" ]; then
	[ -s "$RESTORE_IMAGE" ] || die "missing restore image: $RESTORE_IMAGE"
	actual_bytes="$(stat -c '%s' "$RESTORE_IMAGE")"
	[ "$actual_bytes" = "$EXPECTED_BYTES" ] || die "restore image size mismatch: expected $EXPECTED_BYTES, got $actual_bytes"
fi

stamp="$(date +%F-%H%M%S)"
run_dir="$HOTDOG_LOG_ROOT/restore-boot-b-from-edl-firehose-$stamp"
mkdir -p "$run_dir"
exec > >(tee "$run_dir/run.log") 2>&1

cleanup() {
	phone_lock_release || true
}
trap cleanup EXIT

usb_state_file="$run_dir/lsusb-before.txt"
lsusb > "$usb_state_file"
cat "$usb_state_file"

if grep -qi '05c6:900e' "$usb_state_file"; then
	die "device is in Qualcomm 900e crashdump mode, not Firehose 9008; refusing edl write path"
fi
if ! grep -qi '05c6:9008' "$usb_state_file"; then
	die "device is not visible as Qualcomm 05c6:9008; no Firehose action possible"
fi

phone_lock_acquire "edl firehose $MODE $PARTITION" 0 || exit 1

log "Run directory: $run_dir"
log "Mode: $MODE"
log "EDL: $EDL_BIN"
log "Loader: $LOADER"
log "Target: UFS LUN $LUN partition $PARTITION"
sha256sum "$LOADER" | tee "$run_dir/loader-sha256.txt"
if [ -s "$RESTORE_IMAGE" ]; then
	sha256sum "$RESTORE_IMAGE" | tee "$run_dir/restore-image-sha256.txt"
fi

edl_do() {
	timeout "$COMMAND_TIMEOUT_SEC" "$EDL_BIN" \
		--vid=0x05c6 \
		--pid=0x9008 \
		--loader="$LOADER" \
		--memory=ufs \
		"$@"
}

edl_lun_do() {
	timeout "$COMMAND_TIMEOUT_SEC" "$EDL_BIN" \
		--vid=0x05c6 \
		--pid=0x9008 \
		--loader="$LOADER" \
		--memory=ufs \
		--lun="$LUN" \
		"$@"
}

log "Querying Firehose storage info"
edl_do getstorageinfo 2>&1 | tee "$run_dir/edl-getstorageinfo.txt"

log "Printing GPT for LUN $LUN"
edl_lun_do printgpt 2>&1 | tee "$run_dir/edl-printgpt-lun-$LUN.txt"
grep -Eq "(^|[^[:alnum:]_])${PARTITION}([^[:alnum:]_]|$)" "$run_dir/edl-printgpt-lun-$LUN.txt" \
	|| die "partition $PARTITION was not found in live GPT for LUN $LUN"

before_image="$run_dir/${PARTITION}-before.img"
log "Reading $PARTITION before any write"
edl_lun_do r "$PARTITION" "$before_image" 2>&1 | tee "$run_dir/edl-read-${PARTITION}-before.txt"
before_bytes="$(stat -c '%s' "$before_image")"
log "Readback size before write: $before_bytes bytes"
if [ "$before_bytes" != "$EXPECTED_BYTES" ]; then
	die "live $PARTITION size mismatch: expected $EXPECTED_BYTES, read $before_bytes"
fi
sha256sum "$before_image" | tee "$run_dir/${PARTITION}-before-sha256.txt"

if [ "$MODE" = "validate" ]; then
	log "Validation complete; no writes performed"
	printf 'Run directory: %s\n' "$run_dir"
	exit 0
fi

log "Writing restore image to $PARTITION"
edl_lun_do w "$PARTITION" "$RESTORE_IMAGE" 2>&1 | tee "$run_dir/edl-write-${PARTITION}.txt"

after_image="$run_dir/${PARTITION}-after.img"
log "Reading $PARTITION after write for verification"
edl_lun_do r "$PARTITION" "$after_image" 2>&1 | tee "$run_dir/edl-read-${PARTITION}-after.txt"
sha256sum "$RESTORE_IMAGE" "$after_image" | tee "$run_dir/${PARTITION}-after-compare-sha256.txt"
expected_sha="$(sha256sum "$RESTORE_IMAGE" | awk '{print $1}')"
actual_sha="$(sha256sum "$after_image" | awk '{print $1}')"
[ "$expected_sha" = "$actual_sha" ] || die "post-write readback sha256 mismatch"

if [ "$AFTER_WRITE_RESET" -eq 1 ]; then
	log "Sending Firehose reset"
	edl_do reset --resetmode=reset 2>&1 | tee "$run_dir/edl-reset.txt" || true
fi

log "Done"
printf 'Run directory: %s\n' "$run_dir"
