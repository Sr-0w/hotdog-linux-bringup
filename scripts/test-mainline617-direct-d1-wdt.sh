#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source "$(dirname "$0")/env.sh"

BOOT_IMAGE="$HOTDOG_ROOT/images/pmos-experiments/2026-07-11-150100-mainline617-direct-wdt-d1/boot.img"
RAW_IMAGE="$HOTDOG_ROOT/images/pmos-experiments/2026-07-11-150100-mainline617-direct-wdt-d1/boot-mainline617-direct-wdt-d1.img"
RESTORE_IMAGE="$HOTDOG_ROOT/images/pmos-experiments/2026-07-11-130500-lineage414-r5-kexec-fbwait-nopaint-acm-rootwatchdog/boot-noefi-pmosdtb-watchdog-300s.img"
BOOT_WAIT_SEC="${HOTDOG_D1_WDT_BOOT_WAIT_SEC:-540}"
RESCUE_WATCH_TIMEOUT_SEC=604800
RESCUE_WATCH_POLL_SEC=5
POLL_SEC=2
FASTBOOT_TIMEOUT_SEC=15

usage() {
	cat <<'USAGE'
Usage: test-mainline617-direct-d1-wdt.sh

Run the pinned D1 watchdog-control image from an attested downstream bridge.
Relative to D1, this changes only the Linux Image to the build with
CONFIG_QCOM_WDT=y and CONFIG_WATCHDOG_SYSFS=y. The ramdisk, transformed DTB,
command line, Android header v2 layout, AVB footer and R5 rollback remain pinned.

No command-line override is accepted. HOTDOG_D1_WDT_BOOT_WAIT_SEC may extend
the observation window but cannot reduce it below 480 seconds.
USAGE
}

die() {
	printf 'ERROR: %s\n' "$1" >&2
	exit "${2:-1}"
}

check_sha() {
	local label="$1"
	local file="$2"
	local expected="$3"
	local actual

	[ -s "$file" ] || die "Missing $label: $file" 2
	actual="$(sha256sum "$file" | awk '{ print $1 }')"
	[ "$actual" = "$expected" ] ||
		die "$label hash mismatch: expected $expected, got $actual" 3
}

case "$BOOT_WAIT_SEC" in
	''|*[!0-9]*) die "Invalid HOTDOG_D1_WDT_BOOT_WAIT_SEC: $BOOT_WAIT_SEC" 2 ;;
esac
[ "$BOOT_WAIT_SEC" -ge 480 ] ||
	die "HOTDOG_D1_WDT_BOOT_WAIT_SEC must be at least 480, got $BOOT_WAIT_SEC" 2

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
	usage
	exit 0
fi
[ "$#" -eq 0 ] || die "Unsupported option for pinned D1-wdt test: $1" 2

hotdog_require_pmos_password
hotdog_require_target_serial

check_sha "D1-wdt AVB image" "$BOOT_IMAGE" 74ab6d70f54257399d6b3afe59eaba337a67fc2254355341e2cba52fd769627d
check_sha "D1-wdt raw image" "$RAW_IMAGE" c5b31bc45096705a16255efe059306368de97570cf2e385c6187227e346e4580
check_sha "stable no-paint restore image" "$RESTORE_IMAGE" 23fa53d382425e9414a2e2a4b6e10f42d59ce1d6623b7fa1fbebf21ffe0c8a50

export HOTDOG_FLASH_BOOT_B_SSH_HELPER="$HOTDOG_ROOT/scripts/flash-boot-b-from-pmos-ssh.sh"
export HOTDOG_RESCUE_WATCHER_HELPER="$HOTDOG_ROOT/scripts/rescue-boot-b-when-visible.sh"

exec "$HOTDOG_ROOT/scripts/test-boot-b-image.sh" \
	--image "$BOOT_IMAGE" \
	--image-sha256 74ab6d70f54257399d6b3afe59eaba337a67fc2254355341e2cba52fd769627d \
	--restore-boot-b "$RESTORE_IMAGE" \
	--restore-boot-b-sha256 23fa53d382425e9414a2e2a4b6e10f42d59ce1d6623b7fa1fbebf21ffe0c8a50 \
	--serial "$HOTDOG_TARGET_SERIAL" \
	--expected-product "msmnile hotdog" \
	--from-pmos-ssh \
	--start-rescue-watcher \
	--require-dirty-survival \
	--expect-source-kernel-prefix 4.14.357-openela-perf \
	--expect-source-cmdline-token androidboot.slot_suffix=_b \
	--expect-source-cmdline-token "androidboot.serialno=$HOTDOG_TARGET_SERIAL" \
	--expect-kernel-prefix 6.17.0-sm8150 \
	--expect-cmdline-token rdinit=/hotdog-mainline-wrapper \
	--expect-cmdline-token androidboot.slot_suffix=_b \
	--expect-cmdline-token "androidboot.serialno=$HOTDOG_TARGET_SERIAL" \
	--restore-after system \
	--boot-wait "$BOOT_WAIT_SEC" \
	--poll "$POLL_SEC" \
	--fastboot-timeout "$FASTBOOT_TIMEOUT_SEC" \
	--rescue-watch-timeout "$RESCUE_WATCH_TIMEOUT_SEC" \
	--rescue-watch-poll "$RESCUE_WATCH_POLL_SEC"
