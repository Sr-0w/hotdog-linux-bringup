#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source "$(dirname "$0")/env.sh"

R5_BOOT="$HOTDOG_ROOT/images/pmos-experiments/2026-07-11-130500-lineage414-r5-kexec-fbwait-nopaint-acm-rootwatchdog/boot-noefi-pmosdtb-watchdog-300s.img"
CANDIDATE_DTBO="$HOTDOG_ROOT/images/pmos-experiments/2026-07-12-184800-d5-filtered-dtbo/dtbo_b-d5-filtered.img"
RESTORE_DTBO="$HOTDOG_ROOT/logs/partition-read-vbmeta-dtbo-clean-2026-07-08-230943/dtbo_b.img"
REBOOT_HELPER="$HOTDOG_ROOT/build/hotdog-reboot-mode-aarch64"

R5_SHA=23fa53d382425e9414a2e2a4b6e10f42d59ce1d6623b7fa1fbebf21ffe0c8a50
CANDIDATE_DTBO_SHA=b3424acbe3dce0dd668119a37cfb07f37cd9534da7b09fc5d90f57c6c5453b57
RESTORE_DTBO_SHA=95a111deb5302d0fc677c3d58f880a049461ffcaba856c75471d2789040ae672
REBOOT_HELPER_SHA=045a3d9d696ddee6922e1ce506aeb82a77c261978ea6a3220fd114751952d711

die() { printf 'ERROR: %s\n' "$1" >&2; exit "${2:-1}"; }
check_sha() {
  local label="$1" file="$2" expected="$3" actual=""
  [ -s "$file" ] || die "Missing $label: $file" 2
  actual="$(sha256sum "$file" | awk '{ print $1 }')"
  [ "$actual" = "$expected" ] || die "$label SHA256 mismatch: expected $expected, got $actual" 3
}

VARIANT_LABEL="D5 filtered"
case "${1:-}" in
  --d6-ufs-bridge)
    CANDIDATE_DTBO="$HOTDOG_ROOT/images/pmos-experiments/2026-07-12-191000-d6-ufs-bridge-dtbo/dtbo_b-d6-ufs-bridge-filtered.img"
    CANDIDATE_DTBO_SHA=ece68d9cad3c79f677d4c361f15cc897d7a9c8e8f6a403145624439bf3688df1
    VARIANT_LABEL="D6 UFS-symbol-bridge filtered"
    shift
    ;;
  --d7-ufs-gdsc-bridge)
    CANDIDATE_DTBO="$HOTDOG_ROOT/images/pmos-experiments/2026-07-12-220500-d7-ufs-gdsc-bridge-dtbo/dtbo_b-d7-ufs-gdsc-bridge-filtered.img"
    CANDIDATE_DTBO_SHA=c7b22d3c2b8d9d09d95ee9ef8f3ead91dae2d7ec85e259c03b44bc3b2afa8978
    VARIANT_LABEL="D7 UFS-GDSC-symbol-bridge filtered"
    shift
    ;;
  -h|--help)
  printf '%s\n' 'Usage: test-r5-d5-filtered-dtbo-control.sh [--d6-ufs-bridge | --d7-ufs-gdsc-bridge]'
  printf '%s\n' 'Pinned control: known-good R5 boot_b with a stock-derived filtered dtbo_b.'
  exit 0
    ;;
esac
[ "$#" -eq 0 ] || die "This pinned R5 DTBO control accepts no options" 2
hotdog_require_pmos_password
hotdog_require_target_serial
[ -z "${ANDROID_SERIAL:-}" ] || [ "$ANDROID_SERIAL" = "$HOTDOG_TARGET_SERIAL" ] ||
  die "ANDROID_SERIAL differs from HOTDOG_TARGET_SERIAL" 2

check_sha "R5 candidate and restore boot_b" "$R5_BOOT" "$R5_SHA"
check_sha "candidate $VARIANT_LABEL dtbo_b" "$CANDIDATE_DTBO" "$CANDIDATE_DTBO_SHA"
check_sha "original restore dtbo_b" "$RESTORE_DTBO" "$RESTORE_DTBO_SHA"
check_sha "R5 bootloader reboot helper" "$REBOOT_HELPER" "$REBOOT_HELPER_SHA"

export HOTDOG_FLASH_BOOT_B_SSH_HELPER="$HOTDOG_ROOT/scripts/flash-boot-b-from-pmos-ssh.sh"
export HOTDOG_RESCUE_WATCHER_HELPER="$HOTDOG_ROOT/scripts/rescue-boot-b-when-visible.sh"

exec "$HOTDOG_ROOT/scripts/test-boot-b-image.sh" \
  --image "$R5_BOOT" --image-sha256 "$R5_SHA" \
  --dual-partition-transaction \
  --candidate-dtbo-b "$CANDIDATE_DTBO" --candidate-dtbo-b-sha256 "$CANDIDATE_DTBO_SHA" \
  --restore-dtbo-b "$RESTORE_DTBO" --restore-dtbo-b-sha256 "$RESTORE_DTBO_SHA" \
  --restore-boot-b "$R5_BOOT" --restore-boot-b-sha256 "$R5_SHA" \
  --reboot-helper "$REBOOT_HELPER" --reboot-helper-sha256 "$REBOOT_HELPER_SHA" \
  --serial "$HOTDOG_TARGET_SERIAL" --expected-product 'msmnile hotdog' \
  --from-pmos-ssh --start-rescue-watcher --require-dirty-survival \
  --expect-source-kernel-prefix 4.14.357-openela-perf \
  --expect-source-cmdline-token androidboot.slot_suffix=_b \
  --expect-source-cmdline-token "androidboot.serialno=$HOTDOG_TARGET_SERIAL" \
  --expect-kernel-prefix 4.14.357-openela-perf \
  --expect-cmdline-token androidboot.slot_suffix=_b \
  --expect-cmdline-token "androidboot.serialno=$HOTDOG_TARGET_SERIAL" \
  --restore-after system --boot-wait 240 --poll 2 --fastboot-timeout 15 \
  --rescue-watch-timeout 604800 --rescue-watch-poll 5
