#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source "$(dirname "$0")/env.sh"

BOOT_IMAGE="$HOTDOG_ROOT/images/pmos-experiments/2026-07-11-150100-mainline617-direct-wdt-d1/boot.img"
CANDIDATE_DTBO="$HOTDOG_ROOT/images/pmos-experiments/2026-07-12-160925-d3-noop-dtbo/dtbo_b-d3-entry5-noop.img"
RESTORE_BOOT="$HOTDOG_ROOT/images/pmos-experiments/2026-07-11-130500-lineage414-r5-kexec-fbwait-nopaint-acm-rootwatchdog/boot-noefi-pmosdtb-watchdog-300s.img"
RESTORE_DTBO="$HOTDOG_ROOT/logs/partition-read-vbmeta-dtbo-clean-2026-07-08-230943/dtbo_b.img"
REBOOT_HELPER="$HOTDOG_ROOT/build/hotdog-reboot-mode-aarch64"

BOOT_SHA=74ab6d70f54257399d6b3afe59eaba337a67fc2254355341e2cba52fd769627d
CANDIDATE_DTBO_SHA=339e55adaf591f114d8a39a86cb0a0e664e26bc7c7b7f2227e0bee794d10c5fb
RESTORE_BOOT_SHA=23fa53d382425e9414a2e2a4b6e10f42d59ce1d6623b7fa1fbebf21ffe0c8a50
RESTORE_DTBO_SHA=95a111deb5302d0fc677c3d58f880a049461ffcaba856c75471d2789040ae672
REBOOT_HELPER_SHA=045a3d9d696ddee6922e1ce506aeb82a77c261978ea6a3220fd114751952d711

die() { printf 'ERROR: %s\n' "$1" >&2; exit "${2:-1}"; }
check_sha() {
  local label="$1" file="$2" expected="$3" actual=""
  [ -s "$file" ] || die "Missing $label: $file" 2
  actual="$(sha256sum "$file" | awk '{ print $1 }')"
  [ "$actual" = "$expected" ] || die "$label SHA256 mismatch: expected $expected, got $actual" 3
}

if [ "${1:-}" = -h ] || [ "${1:-}" = --help ]; then
  printf '%s\n' 'Usage: test-mainline617-direct-d3-wdt.sh'
  printf '%s\n' 'Pinned D3-wdt: no-op dtbo_b plus built-in-QCOM_WDT boot_b.'
  exit 0
fi
[ "$#" -eq 0 ] || die "This pinned D3-wdt launcher accepts no options" 2
hotdog_require_pmos_password
hotdog_require_target_serial
[ -z "${ANDROID_SERIAL:-}" ] || [ "$ANDROID_SERIAL" = "$HOTDOG_TARGET_SERIAL" ] ||
  die "ANDROID_SERIAL differs from HOTDOG_TARGET_SERIAL" 2

check_sha "D1-wdt boot image" "$BOOT_IMAGE" "$BOOT_SHA"
check_sha "candidate no-op dtbo_b" "$CANDIDATE_DTBO" "$CANDIDATE_DTBO_SHA"
check_sha "R5 restore boot_b" "$RESTORE_BOOT" "$RESTORE_BOOT_SHA"
check_sha "original restore dtbo_b" "$RESTORE_DTBO" "$RESTORE_DTBO_SHA"
check_sha "R5 bootloader reboot helper" "$REBOOT_HELPER" "$REBOOT_HELPER_SHA"

export HOTDOG_FLASH_BOOT_B_SSH_HELPER="$HOTDOG_ROOT/scripts/flash-boot-b-from-pmos-ssh.sh"
export HOTDOG_RESCUE_WATCHER_HELPER="$HOTDOG_ROOT/scripts/rescue-boot-b-when-visible.sh"

exec "$HOTDOG_ROOT/scripts/test-boot-b-image.sh" \
  --image "$BOOT_IMAGE" --image-sha256 "$BOOT_SHA" \
  --dual-partition-transaction \
  --candidate-dtbo-b "$CANDIDATE_DTBO" --candidate-dtbo-b-sha256 "$CANDIDATE_DTBO_SHA" \
  --restore-dtbo-b "$RESTORE_DTBO" --restore-dtbo-b-sha256 "$RESTORE_DTBO_SHA" \
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
