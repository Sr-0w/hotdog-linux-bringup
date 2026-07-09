#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/env.sh"

SERIAL="${ANDROID_SERIAL:-b6bd2252}"
RESTORE_IMAGE="$HOTDOG_STABLE_PMOS_BOOT_B"
AFTER_RESTORE="system"
FASTBOOT_TIMEOUT_SEC="${FASTBOOT_TIMEOUT_SEC:-20}"

usage() {
	cat <<'EOF'
Usage: restore-pmos-boot-b-from-fastboot.sh [options]

Restore the known-good pmOS boot_b image from bootloader fastboot, set slot b
active, then reboot.

This script only uses fastboot and only flashes boot_b.

Options:
  --serial SERIAL        Target fastboot serial. Default: b6bd2252.
  --restore-boot-b FILE  Boot image to flash to boot_b.
  --after-restore MODE   system, bootloader, or none. Default: system.
  --timeout SEC          Timeout for each fastboot command. Default: 20.
  -h, --help             Show this help.
EOF
}

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--serial)
			[ "$#" -ge 2 ] || die "--serial requires a value"
			SERIAL="$2"
			shift
			;;
		--restore-boot-b)
			[ "$#" -ge 2 ] || die "--restore-boot-b requires a value"
			RESTORE_IMAGE="$2"
			shift
			;;
		--after-restore)
			[ "$#" -ge 2 ] || die "--after-restore requires a value"
			AFTER_RESTORE="$2"
			shift
			;;
		--timeout)
			[ "$#" -ge 2 ] || die "--timeout requires a value"
			FASTBOOT_TIMEOUT_SEC="$2"
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

case "$AFTER_RESTORE" in
	system|bootloader|none)
		;;
	*)
		die "--after-restore must be one of: system, bootloader, none"
		;;
esac
[ -s "$RESTORE_IMAGE" ] || die "missing restore image: $RESTORE_IMAGE"
command -v fastboot >/dev/null 2>&1 || die "missing fastboot"
command -v sha256sum >/dev/null 2>&1 || die "missing sha256sum"

stamp="$(date +%F-%H%M%S)"
run_dir="$HOTDOG_LOG_ROOT/restore-pmos-boot-b-from-fastboot-$stamp"
mkdir -p "$run_dir"
exec > >(tee "$run_dir/run.log") 2>&1

log() {
	printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

fastboot_do() {
	timeout "$FASTBOOT_TIMEOUT_SEC" fastboot -s "$SERIAL" "$@"
}

log "Run directory: $run_dir"
log "Target serial: $SERIAL"
log "Restore image: $RESTORE_IMAGE"
sha256sum "$RESTORE_IMAGE" | tee "$run_dir/restore-image-sha256.txt"

timeout "$FASTBOOT_TIMEOUT_SEC" fastboot devices -l | tee "$run_dir/fastboot-devices.txt"
if ! grep -q "^${SERIAL}[[:space:]]" "$run_dir/fastboot-devices.txt"; then
	die "target serial is not visible in fastboot: $SERIAL"
fi

fastboot_do getvar product 2>&1 | tee "$run_dir/getvar-product.txt" || true
fastboot_do getvar current-slot 2>&1 | tee "$run_dir/getvar-current-slot-before.txt" || true
fastboot_do getvar slot-retry-count:b 2>&1 | tee "$run_dir/getvar-slot-retry-count-b-before.txt" || true
fastboot_do getvar slot-unbootable:b 2>&1 | tee "$run_dir/getvar-slot-unbootable-b-before.txt" || true

log "Flashing boot_b"
fastboot_do flash boot_b "$RESTORE_IMAGE" 2>&1 | tee "$run_dir/fastboot-flash-boot-b.txt"
log "Setting active slot b"
fastboot_do --set-active=b 2>&1 | tee "$run_dir/fastboot-set-active-b.txt"
fastboot_do getvar slot-retry-count:b 2>&1 | tee "$run_dir/getvar-slot-retry-count-b-after.txt" || true
fastboot_do getvar slot-unbootable:b 2>&1 | tee "$run_dir/getvar-slot-unbootable-b-after.txt" || true

case "$AFTER_RESTORE" in
	system)
		log "Rebooting system"
		fastboot_do reboot 2>&1 | tee "$run_dir/fastboot-reboot-system.txt" || true
		;;
	bootloader)
		log "Rebooting bootloader"
		fastboot_do reboot bootloader 2>&1 | tee "$run_dir/fastboot-reboot-bootloader.txt" || true
		;;
	none)
		log "Leaving target in fastboot"
		;;
esac

log "Done"
printf 'Run directory: %s\n' "$run_dir"
