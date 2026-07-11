#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/env.sh"

serial="${ANDROID_SERIAL:-$HOTDOG_TARGET_SERIAL}"
image="$HOTDOG_ROOT/images/pmos-experiments/2026-07-11-130500-lineage414-r5-kexec-fbwait-nopaint-acm-rootwatchdog/boot-noefi-pmosdtb-watchdog-300s.img"
restore="$HOTDOG_STABLE_PMOS_BOOT_B"
from_pmos_ssh="${HOTDOG_FROM_PMOS_SSH:-0}"

args=()
if [ "$from_pmos_ssh" = "1" ]; then
  args+=(--from-pmos-ssh)
fi

exec "$HOTDOG_ROOT/scripts/test-boot-b-image.sh" \
  --serial "$serial" \
  "${args[@]}" \
  --image "$image" \
  --restore-boot-b "$restore" \
  --restore-after system \
  --boot-wait 420 \
  --poll 2 \
  --start-rescue-watcher \
  --rescue-watch-timeout 21600 \
  --rescue-watch-poll 5 \
  "$@"
