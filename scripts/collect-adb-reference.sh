#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/env.sh"

with_vendor_etc=0
with_root_blocks=0

usage() {
  cat <<'USAGE'
Usage: collect-adb-reference.sh [--vendor-etc] [--root-blocks]

Non-destructive Android reference dump.

  --vendor-etc    Pull /vendor/etc and /odm/etc if readable.
  --root-blocks   Try read-only pulls of boot/dtbo/vbmeta style block images.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --vendor-etc) with_vendor_etc=1 ;;
    --root-blocks) with_root_blocks=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

stamp="$(date +%F-%H%M%S)"
out="$HOTDOG_DUMP_ROOT/stock-before-flash/${stamp}-adb"
mkdir -p "$out"
exec > >(tee "$out/run.log") 2>&1

echo "Dump directory: $out"
adb start-server
adb devices -l | tee "$out/adb-devices.txt"

device_count="$(adb devices | awk 'NR > 1 && $2 == "device" { c++ } END { print c + 0 }')"
if [ "$device_count" -lt 1 ]; then
  echo "No authorized adb device found. Unlock Android and accept the RSA prompt, then rerun." >&2
  exit 2
fi

adb wait-for-device

adb_shell() {
  local name="$1"
  shift
  echo "adb shell $* > $name"
  if ! adb shell "$@" > "$out/$name" 2> "$out/$name.err"; then
    echo "FAILED: adb shell $*" | tee "$out/$name.failed"
  fi
}

adb_pull() {
  local remote="$1"
  local local_name="$2"
  echo "adb pull $remote $local_name"
  if ! adb pull "$remote" "$out/$local_name" > "$out/pull-${local_name//\//_}.log" 2>&1; then
    echo "FAILED: adb pull $remote" | tee "$out/pull-${local_name//\//_}.failed"
  fi
}

adb_shell getprop.txt getprop
adb_shell uname.txt uname -a
adb_shell cmdline.txt cat /proc/cmdline
adb_shell partitions.txt ls -l /dev/block/by-name
adb_shell mounts.txt mount
adb_shell interrupts.txt cat /proc/interrupts
adb_shell iomem.txt cat /proc/iomem
adb_shell cpuinfo.txt cat /proc/cpuinfo
adb_shell meminfo.txt cat /proc/meminfo
adb_shell power-supplies.txt ls -R /sys/class/power_supply
adb_shell input-devices.txt cat /proc/bus/input/devices
adb_shell services.txt service list
adb_shell settings-global.txt settings list global
adb_shell settings-secure.txt settings list secure
adb_shell dumpsys-battery.txt dumpsys battery
adb_shell dumpsys-audio.txt dumpsys audio
adb_shell dumpsys-camera.txt dumpsys media.camera
adb_shell dumpsys-power.txt dumpsys power
adb_shell dumpsys-display.txt dumpsys display
adb_shell dumpsys-usb.txt dumpsys usb
adb_shell dumpsys-sensorservice.txt dumpsys sensorservice
adb_shell dumpsys-thermalservice.txt dumpsys thermalservice

echo "adb logcat -d > logcat.txt"
adb logcat -d > "$out/logcat.txt" 2> "$out/logcat.err" || true

echo "Trying dmesg without root"
adb shell dmesg > "$out/dmesg-android.txt" 2> "$out/dmesg-android.err" || true

echo "Trying dmesg through su if available"
adb shell su -c dmesg > "$out/dmesg-android-root.txt" 2> "$out/dmesg-android-root.err" || true

if [ "$with_vendor_etc" -eq 1 ]; then
  adb_pull /vendor/etc vendor-etc
  adb_pull /odm/etc odm-etc
  adb_pull /vendor/firmware vendor-firmware
fi

if [ "$with_root_blocks" -eq 1 ]; then
  mkdir -p "$out/block-images"
  for part in boot_a boot_b dtbo_a dtbo_b vbmeta_a vbmeta_b vendor_boot_a vendor_boot_b; do
    adb_pull "/dev/block/by-name/$part" "block-images/$part.img"
  done
fi

echo "Done: $out"

