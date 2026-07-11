#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/env.sh"

serial="${ANDROID_SERIAL:-$HOTDOG_TARGET_SERIAL}"
image="$HOTDOG_ROOT/images/pmos-experiments/2026-07-10-172100-mainline617-psci-entry-reset-stockdtbpack-fastbootboot/boot-noefi-pmosdtb-watchdog-420s.img"

# This probe is deliberately temporary: fastboot boot leaves boot_a/boot_b
# untouched, so a successful PSCI reset returns to the persistent bridge.
exec "$HOTDOG_ROOT/scripts/test-fastboot-boot-image.sh" \
  --serial "$serial" \
  --image "$image" \
  --boot-wait 420 \
  --poll 1 \
  "$@"
