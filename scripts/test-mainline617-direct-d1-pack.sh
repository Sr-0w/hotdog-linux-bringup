#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source "$(dirname "$0")/env.sh"

BOOT_IMAGE="$HOTDOG_ROOT/images/pmos-experiments/2026-07-11-150010-mainline617-direct-pack-clean/boot.img"
RAW_IMAGE="$HOTDOG_ROOT/images/pmos-experiments/2026-07-11-150010-mainline617-direct-pack-clean/boot-mainline617-direct-d1-pack.img"
RESTORE_IMAGE="$HOTDOG_ROOT/images/pmos-experiments/2026-07-11-130500-lineage414-r5-kexec-fbwait-nopaint-acm-rootwatchdog/boot-noefi-pmosdtb-watchdog-300s.img"
BOOT_WAIT_SEC="${HOTDOG_D1_BOOT_WAIT_SEC:-540}"
RESCUE_WATCH_TIMEOUT_SEC=604800
RESCUE_WATCH_POLL_SEC=5
POLL_SEC=2
FASTBOOT_TIMEOUT_SEC=15

usage() {
	cat <<'USAGE'
Usage: test-mainline617-direct-d1-pack.sh

Run the pinned boot_b test for the D1-pack mainline 6.17 direct boot image.
This launcher hash-checks the D1-pack AVB boot image, its raw validation
artifact and the stable no-paint restore image, requires a healthy pmOS SSH
source, prearms the rescue watcher, expects a 6.17.0-sm8150 kernel after reboot,
and restores boot_b back to the stable system image when the generic boot_b
tester sees a recovery path. The raw artifact is never passed to the tester.

Pinned defaults:
  image:                 2026-07-11-150010 mainline617 direct pack-clean boot.img
  raw validation image:  2026-07-11-150010 D1-pack raw image (never flashed)
  restore image:         2026-07-11-130500 Lineage 4.14 no-paint pmOS bridge
  source:                --from-pmos-ssh
  rescue watcher:        --start-rescue-watcher
  dirty policy:          --require-dirty-survival
  expected kernel:       --expect-kernel-prefix 6.17.0-sm8150
  restore-after:         system
  boot wait:             HOTDOG_D1_BOOT_WAIT_SEC, default 540, minimum 480
  rescue wait:           604800 seconds (pinned)
  rescue poll:           5 seconds (pinned)

The target serial is pinned by `HOTDOG_TARGET_SERIAL`/`ANDROID_SERIAL`.
No command-line override is accepted. A strict 6.17 SSH success intentionally
keeps D1-pack in boot_b; the watcher is stopped only after target identity
validation and rescue-watchdog acknowledgement. Every non-success keeps or
rearms rescue unless a source-SSH restore readback proves boot_b clean.

Environment:
  HOTDOG_D1_BOOT_WAIT_SEC  Override the boot result wait, minimum 480 seconds.

This launcher rejects every argument that could change timing, identity, image,
restore mode, rescue policy, or bootloader safety checks.
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
	[ "$actual" = "$expected" ] || {
		printf '%s hash mismatch: expected %s, got %s\n' "$label" "$expected" "$actual" >&2
		exit 3
	}
}

validate_boot_wait() {
	case "$BOOT_WAIT_SEC" in
		''|*[!0-9]*) die "Invalid HOTDOG_D1_BOOT_WAIT_SEC: $BOOT_WAIT_SEC" 2 ;;
	esac
	[ "$BOOT_WAIT_SEC" -ge 480 ] || die "HOTDOG_D1_BOOT_WAIT_SEC must be at least 480, got $BOOT_WAIT_SEC" 2
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
	usage
	exit 0
fi

validate_boot_wait
[ "$#" -eq 0 ] || die "Unsupported option for pinned D1-pack test: $1" 2

hotdog_require_pmos_password
hotdog_require_target_serial

check_sha "D1-pack AVB boot image" "$BOOT_IMAGE" 2f3bf9b7cde3b2d48a3cf4d6fe2fb2f92e210e1a6b1249505fa15be10c26b754
check_sha "D1-pack raw validation image" "$RAW_IMAGE" f72e8eab80d07fe265bfe5520228b3ff758d47980a2f0204f774b14d5314b1ac
check_sha "stable no-paint restore image" "$RESTORE_IMAGE" 23fa53d382425e9414a2e2a4b6e10f42d59ce1d6623b7fa1fbebf21ffe0c8a50

export HOTDOG_FLASH_BOOT_B_SSH_HELPER="$HOTDOG_ROOT/scripts/flash-boot-b-from-pmos-ssh.sh"
export HOTDOG_RESCUE_WATCHER_HELPER="$HOTDOG_ROOT/scripts/rescue-boot-b-when-visible.sh"

exec "$HOTDOG_ROOT/scripts/test-boot-b-image.sh" \
	--image "$BOOT_IMAGE" \
	--image-sha256 2f3bf9b7cde3b2d48a3cf4d6fe2fb2f92e210e1a6b1249505fa15be10c26b754 \
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
