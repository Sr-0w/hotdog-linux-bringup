#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/env.sh"

IMAGE="$HOTDOG_ROOT/images/pmos-experiments/2026-07-09-204605-mainline617-minramdisk-pstore-stockdtbpack-entry12-watchdog/boot-noefi-pmosdtb-watchdog-420s.img"
RESTORE_IMAGE="${RESTORE_IMAGE:-$HOTDOG_STABLE_PMOS_BOOT_B}"

exec "$HOTDOG_ROOT/scripts/test-boot-b-image.sh" \
  --image "$IMAGE" \
  --restore-boot-b "$RESTORE_IMAGE" \
  --from-pmos-ssh \
  --restore-after system \
  --boot-wait 720 \
  --poll 2 \
  --fastboot-timeout 12 \
  --start-rescue-watcher \
  --rescue-watch-timeout 21600 \
  --rescue-watch-poll 5
