#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/env.sh"

stamp="$(date +%F-%H%M%S)"
out="$HOTDOG_DUMP_ROOT/stock-before-flash/${stamp}-fastboot"
mkdir -p "$out"
exec > >(tee "$out/run.log") 2>&1

echo "Dump directory: $out"
fastboot devices | tee "$out/fastboot-devices.txt"

device_count="$(fastboot devices | awk 'NF >= 2 { c++ } END { print c + 0 }')"
if [ "$device_count" -lt 1 ]; then
  echo "No fastboot device found. Boot the phone into bootloader, then rerun." >&2
  exit 2
fi

echo "fastboot getvar all"
fastboot getvar all > "$out/fastboot-getvar-all.txt" 2>&1 || true

for var in product serialno current-slot slot-count unlocked secure is-userspace has-slot:boot has-slot:dtbo has-slot:vendor_boot version-bootloader version-baseband; do
  safe_name="$(printf '%s' "$var" | tr ':/' '__')"
  fastboot getvar "$var" > "$out/getvar-${safe_name}.txt" 2>&1 || true
done

echo "Done: $out"

