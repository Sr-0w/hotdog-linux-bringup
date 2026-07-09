#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/env.sh"

serial="${ANDROID_SERIAL:-b6bd2252}"
image="$HOTDOG_ROOT/images/pmos-experiments/2026-07-09-191000-lineage414-fbtest-pstore-dedupcmd-currentroot-stockdtbpack-entry12-simplefb-watchdog/boot-noefi-pmosdtb-watchdog-180s.img"

exec "$HOTDOG_ROOT/scripts/test-boot-b-image.sh" \
  --serial "$serial" \
  --image "$image" \
  --restore-boot-b "$HOTDOG_STABLE_PMOS_BOOT_B" \
  --restore-after system \
  --boot-wait 420 \
  --poll 2 \
  --start-rescue-watcher \
  --rescue-watch-timeout 21600 \
  --rescue-watch-poll 5 \
  "$@"
