#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/env.sh"

if [ "${HOTDOG_ALLOW_HISTORICAL_RGB:-0}" != "1" ]; then
  cat >&2 <<'EOF'
ERROR: refusing to run a historical RGB-capable framebuffer test image.
This image contains legacy /hotdog_fb_test.sh RGB fill code. Set
HOTDOG_ALLOW_HISTORICAL_RGB=1 only for an intentional historical diagnostic.
Use scripts/test-lineage414-r5-kexec-bridge.sh for the current no-paint bridge.
EOF
  exit 2
fi

serial="${ANDROID_SERIAL:-$HOTDOG_TARGET_SERIAL}"
image="$HOTDOG_ROOT/images/pmos-experiments/2026-07-10-073742-lineage414-r4-simplefb-nomap-ttykmsg-visibletty-prompt-verbose-acm-rootwatchdog/boot-noefi-pmosdtb-watchdog-300s.img"
restore="$HOTDOG_STABLE_PMOS_BOOT_B"
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
