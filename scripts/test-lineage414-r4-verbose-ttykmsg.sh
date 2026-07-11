#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/env.sh"

serial="${ANDROID_SERIAL:-$HOTDOG_TARGET_SERIAL}"
image="$HOTDOG_ROOT/images/pmos-experiments/2026-07-10-073742-lineage414-r4-simplefb-nomap-ttykmsg-visibletty-prompt-verbose-acm-rootwatchdog/boot-noefi-pmosdtb-watchdog-300s.img"
restore="$HOTDOG_ROOT/images/pmos-experiments/2026-07-09-215005-lineage414-drmconsole-initramfs-rootwatchdog-v2/boot-noefi-pmosdtb-watchdog-300s.img"
from_pmos_ssh="${HOTDOG_FROM_PMOS_SSH:-1}"

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
