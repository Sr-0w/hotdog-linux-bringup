#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source "$(dirname "$0")/env.sh"

BOOT_IMAGE="$HOTDOG_ROOT/images/pmos-experiments/2026-07-11-140000-mainline617-direct-exact-header0/boot-mainline617-direct-exact-header0-stockos-avb.img"
RAW_IMAGE="$HOTDOG_ROOT/images/pmos-experiments/2026-07-11-140000-mainline617-direct-exact-header0/boot-mainline617-direct-exact-header0.img"
PAYLOAD="$HOTDOG_ROOT/images/pmos-experiments/2026-07-11-140000-mainline617-direct-exact-header0/components/boot-mainline617-direct-exact-header0-payload"
RESTORE_IMAGE="$HOTDOG_ROOT/images/pmos-experiments/2026-07-11-130500-lineage414-r5-kexec-fbwait-nopaint-acm-rootwatchdog/boot-noefi-pmosdtb-watchdog-300s.img"
BOOT_WAIT_SEC="${HOTDOG_D2_HEADER0_BOOT_WAIT_SEC:-540}"
RESCUE_WATCH_TIMEOUT_SEC=604800
RESCUE_WATCH_POLL_SEC=5
POLL_SEC=2
FASTBOOT_TIMEOUT_SEC=15

usage() {
	cat <<'USAGE'
Usage: test-mainline617-direct-d2-header0.sh

Run the pinned D2 header-v0 append-DTB control from an attested R5 bridge.
The Linux Image, initramfs, transformed DTB and command line are the exact D1
payloads; only the Android bootloader handoff changes from header v2 with a
separate DTB section to header v0 with the DTB appended to the kernel payload.

No command-line override is accepted. HOTDOG_D2_HEADER0_BOOT_WAIT_SEC may
extend the observation window but cannot reduce it below 480 seconds.
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
	''|*[!0-9]*) die "Invalid HOTDOG_D2_HEADER0_BOOT_WAIT_SEC: $BOOT_WAIT_SEC" 2 ;;
esac
[ "$BOOT_WAIT_SEC" -ge 480 ] ||
	die "HOTDOG_D2_HEADER0_BOOT_WAIT_SEC must be at least 480, got $BOOT_WAIT_SEC" 2

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
	usage
	exit 0
fi
[ "$#" -eq 0 ] || die "Unsupported option for pinned D2-header0 test: $1" 2

hotdog_require_pmos_password
hotdog_require_target_serial

check_sha "D2-header0 AVB image" "$BOOT_IMAGE" 2076c16598a63bfcfea416b47789eacf74086e33919c0715949cd42719f9b71e
check_sha "D2-header0 raw image" "$RAW_IMAGE" c7c07a0cbf1311395343135253a10b555381f97ff32509c77257fc7b3aee3614
check_sha "D2-header0 appended payload" "$PAYLOAD" 9fa9e318cf9d1efea349028a4c1e80b8477fd4839d7a73d3efdc0a0e5811bd09
check_sha "stable no-paint restore image" "$RESTORE_IMAGE" 23fa53d382425e9414a2e2a4b6e10f42d59ce1d6623b7fa1fbebf21ffe0c8a50

export HOTDOG_FLASH_BOOT_B_SSH_HELPER="$HOTDOG_ROOT/scripts/flash-boot-b-from-pmos-ssh.sh"
export HOTDOG_RESCUE_WATCHER_HELPER="$HOTDOG_ROOT/scripts/rescue-boot-b-when-visible.sh"

exec "$HOTDOG_ROOT/scripts/test-boot-b-image.sh" \
	--image "$BOOT_IMAGE" \
	--image-sha256 2076c16598a63bfcfea416b47789eacf74086e33919c0715949cd42719f9b71e \
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
