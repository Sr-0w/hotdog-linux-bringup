#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/env.sh"

serial="${ANDROID_SERIAL:-b6bd2252}"
image="$HOTDOG_ROOT/images/pmos-experiments/2026-07-10-034500-lineage414-pmaports-kernel-ttykmsg-buttonshell-rootwatchdog/boot-noefi-pmosdtb-watchdog-300s.img"
restore="$HOTDOG_ROOT/images/pmos-experiments/2026-07-09-215005-lineage414-drmconsole-initramfs-rootwatchdog-v2/boot-noefi-pmosdtb-watchdog-300s.img"

exec "$HOTDOG_ROOT/scripts/test-boot-b-image.sh" \
  --serial "$serial" \
  --image "$image" \
  --restore-boot-b "$restore" \
  --restore-after system \
  --boot-wait 420 \
  --poll 2 \
  --start-rescue-watcher \
  --rescue-watch-timeout 21600 \
  --rescue-watch-poll 5 \
  "$@"
