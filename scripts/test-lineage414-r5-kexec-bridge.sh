#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/env.sh"

image="$HOTDOG_ROOT/images/pmos-experiments/2026-07-11-130500-lineage414-r5-kexec-fbwait-nopaint-acm-rootwatchdog/boot-noefi-pmosdtb-watchdog-300s.img"
restore="$HOTDOG_STABLE_PMOS_BOOT_B"
from_pmos_ssh="${HOTDOG_FROM_PMOS_SSH:-0}"
expected_sha256="23fa53d382425e9414a2e2a4b6e10f42d59ce1d6623b7fa1fbebf21ffe0c8a50"

if [ "$#" -ne 0 ]; then
  printf '%s\n' 'This pinned R5 launcher accepts no command-line options; use only the attested environment.' >&2
  exit 2
fi
case "$from_pmos_ssh" in
  0|1) ;;
  *) printf 'HOTDOG_FROM_PMOS_SSH must be exactly 0 or 1, got: %s\n' "$from_pmos_ssh" >&2; exit 2 ;;
esac

hotdog_require_target_serial
serial="$HOTDOG_TARGET_SERIAL"

export HOTDOG_FLASH_BOOT_B_SSH_HELPER="$HOTDOG_ROOT/scripts/flash-boot-b-from-pmos-ssh.sh"
export HOTDOG_RESCUE_WATCHER_HELPER="$HOTDOG_ROOT/scripts/rescue-boot-b-when-visible.sh"

check_sha256() {
  local label="$1"
  local file="$2"
  local actual=""

  [ -s "$file" ] || { printf 'Missing %s: %s\n' "$label" "$file" >&2; return 2; }
  actual="$(sha256sum "$file" | awk '{ print $1 }')"
  [ "$actual" = "$expected_sha256" ] || {
    printf '%s SHA256 mismatch: expected %s, got %s\n' "$label" "$expected_sha256" "$actual" >&2
    return 3
  }
}

check_sha256 "R5 bridge image" "$image"
check_sha256 "R5 restore image" "$restore"

mode_args=()
source_identity_args=()
if [ "$from_pmos_ssh" = "1" ]; then
  mode_args+=(--from-pmos-ssh)
  source_identity_args+=(
    --expect-source-kernel-prefix 4.14.357-openela-perf
    --expect-source-cmdline-token androidboot.slot_suffix=_b
    --expect-source-cmdline-token "androidboot.serialno=$serial"
  )
fi

exec "$HOTDOG_ROOT/scripts/test-boot-b-image.sh" \
  "${mode_args[@]}" \
  --expected-product "msmnile hotdog" \
  --restore-after system \
  --boot-wait 420 \
  --poll 2 \
  --fastboot-timeout 15 \
  --start-rescue-watcher \
  --rescue-watch-timeout 21600 \
  --rescue-watch-poll 5 \
  --serial "$serial" \
  --image "$image" \
  --image-sha256 "$expected_sha256" \
  --restore-boot-b "$restore" \
  --restore-boot-b-sha256 "$expected_sha256" \
  --require-dirty-survival \
  "${source_identity_args[@]}" \
  --expect-kernel-prefix 4.14.357-openela-perf \
  --expect-cmdline-token androidboot.slot_suffix=_b \
  --expect-cmdline-token "androidboot.serialno=$serial"
