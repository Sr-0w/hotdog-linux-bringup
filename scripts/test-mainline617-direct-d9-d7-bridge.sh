#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source "$(dirname "$0")/env.sh"

BOOT_IMAGE="$HOTDOG_ROOT/images/pmos-experiments/2026-07-12-232500-mainline617-direct-d9-d7-bridge/boot.img"
D7_DTBO="$HOTDOG_ROOT/images/pmos-experiments/2026-07-12-220500-d7-ufs-gdsc-bridge-dtbo/dtbo_b-d7-ufs-gdsc-bridge-filtered.img"
RESTORE_BOOT="$HOTDOG_ROOT/images/pmos-experiments/2026-07-11-130500-lineage414-r5-kexec-fbwait-nopaint-acm-rootwatchdog/boot-noefi-pmosdtb-watchdog-300s.img"
REBOOT_HELPER="$HOTDOG_ROOT/build/hotdog-reboot-mode-aarch64"

BOOT_SHA=363f47a7ffc818b44aa8f9fc59c47be4c6686b74da8289c4106e78e208d15f3b
D7_DTBO_SHA=c7b22d3c2b8d9d09d95ee9ef8f3ead91dae2d7ec85e259c03b44bc3b2afa8978
RESTORE_BOOT_SHA=23fa53d382425e9414a2e2a4b6e10f42d59ce1d6623b7fa1fbebf21ffe0c8a50
REBOOT_HELPER_SHA=045a3d9d696ddee6922e1ce506aeb82a77c261978ea6a3220fd114751952d711

die() { printf 'ERROR: %s\n' "$1" >&2; exit "${2:-1}"; }

check_sha() {
	local label="$1" file="$2" expected="$3" actual=""
	[ -s "$file" ] || die "Missing $label: $file" 2
	actual="$(sha256sum "$file" | awk '{ print $1 }')"
	[ "$actual" = "$expected" ] ||
		die "$label SHA256 mismatch: expected $expected, got $actual" 3
}

if [ "${1:-}" = -h ] || [ "${1:-}" = --help ]; then
	cat <<'USAGE'
Usage: test-mainline617-direct-d9-d7-bridge.sh

Pair D7 with a direct K1 image whose embedded DTB contains the vendor-symbol
and fixed-regulator bridge used to filter D7. Kernel, ramdisk, command line,
header layout, and rollback remain pinned to the preceding controls.
No command-line override is accepted.
USAGE
	exit 0
fi

[ "$#" -eq 0 ] || die "This pinned D9 launcher accepts no options" 2
hotdog_require_pmos_password
hotdog_require_target_serial
[ -z "${ANDROID_SERIAL:-}" ] || [ "$ANDROID_SERIAL" = "$HOTDOG_TARGET_SERIAL" ] ||
	die "ANDROID_SERIAL differs from HOTDOG_TARGET_SERIAL" 2

check_sha "D9 D7-bridged direct image" "$BOOT_IMAGE" "$BOOT_SHA"
check_sha "D7 candidate and restore dtbo_b" "$D7_DTBO" "$D7_DTBO_SHA"
check_sha "R5 restore boot_b" "$RESTORE_BOOT" "$RESTORE_BOOT_SHA"
check_sha "R5 bootloader reboot helper" "$REBOOT_HELPER" "$REBOOT_HELPER_SHA"

export HOTDOG_FLASH_BOOT_B_SSH_HELPER="$HOTDOG_ROOT/scripts/flash-boot-b-from-pmos-ssh.sh"
export HOTDOG_RESCUE_WATCHER_HELPER="$HOTDOG_ROOT/scripts/rescue-boot-b-when-visible.sh"

exec "$HOTDOG_ROOT/scripts/test-boot-b-image.sh" \
	--image "$BOOT_IMAGE" --image-sha256 "$BOOT_SHA" \
	--dual-partition-transaction \
	--candidate-dtbo-b "$D7_DTBO" --candidate-dtbo-b-sha256 "$D7_DTBO_SHA" \
	--restore-dtbo-b "$D7_DTBO" --restore-dtbo-b-sha256 "$D7_DTBO_SHA" \
	--restore-boot-b "$RESTORE_BOOT" --restore-boot-b-sha256 "$RESTORE_BOOT_SHA" \
	--reboot-helper "$REBOOT_HELPER" --reboot-helper-sha256 "$REBOOT_HELPER_SHA" \
	--serial "$HOTDOG_TARGET_SERIAL" --expected-product 'msmnile hotdog' \
	--from-pmos-ssh --start-rescue-watcher --require-dirty-survival \
	--expect-source-kernel-prefix 4.14.357-openela-perf \
	--expect-source-cmdline-token androidboot.slot_suffix=_b \
	--expect-source-cmdline-token "androidboot.serialno=$HOTDOG_TARGET_SERIAL" \
	--expect-kernel-prefix 6.17.0-sm8150 \
	--expect-cmdline-token rdinit=/hotdog-mainline-wrapper \
	--expect-cmdline-token androidboot.slot_suffix=_b \
	--expect-cmdline-token "androidboot.serialno=$HOTDOG_TARGET_SERIAL" \
	--restore-after system --boot-wait 540 --poll 2 --fastboot-timeout 15 \
	--rescue-watch-timeout 604800 --rescue-watch-poll 5
