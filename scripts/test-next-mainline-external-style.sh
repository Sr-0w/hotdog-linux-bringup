#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/env.sh"

serial="${ANDROID_SERIAL:-b6bd2252}"
image="$HOTDOG_ROOT/images/pmos-experiments/2026-07-09-014500-mainline617-external-appenddtb-header0-watchdog60/boot-mainline617-external-appenddtb-header0-watchdog60-stockos-avb.img"
restore="$HOTDOG_STABLE_PMOS_BOOT_B"

exec "$HOTDOG_ROOT/scripts/test-boot-b-image.sh" \
  --serial "$serial" \
  --image "$image" \
  --restore-boot-b "$restore" \
  --restore-after system \
  --from-pmos-ssh \
  --boot-wait 240 \
  --poll 2 \
  --start-rescue-watcher \
  --rescue-watch-timeout 21600 \
  --rescue-watch-poll 5
