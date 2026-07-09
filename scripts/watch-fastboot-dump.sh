#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/env.sh"
source "$(dirname "$0")/phone-lock.sh"

TIMEOUT_SEC="${TIMEOUT_SEC:-28800}"
POLL_SEC="${POLL_SEC:-2}"
FLASH_SCRIPT="${FLASH_SCRIPT:-$HOTDOG_ROOT/scripts/flash-adb-recovery-and-dump-blocks.sh}"
SIDELOAD_ZIP="${SIDELOAD_ZIP:-}"
LOCK_DIR="$HOTDOG_LOG_ROOT/watch-fastboot-dump.lock"
stamp="$(date +%F-%H%M%S)"
run_dir="$HOTDOG_LOG_ROOT/watch-fastboot-dump-$stamp"
device_serial="${ANDROID_SERIAL:-}"

usage() {
  cat <<'USAGE'
Usage: watch-fastboot-dump.sh [options]

Wait for a fastboot device, then run flash-adb-recovery-and-dump-blocks.sh.
If an authorized adb device/recovery appears first, reboot it to bootloader
and continue automatically.

Options:
  --serial SERIAL   Restrict to one fastboot serial.
  --sideload ZIP    If adb sideload mode appears, sideload this ZIP.
  --timeout SEC     Seconds to wait. Default: 28800.
  --poll SEC        Poll interval. Default: 2.
  -h, --help        Show this help.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --serial)
      [ "$#" -ge 2 ] || { echo "Missing value for --serial" >&2; exit 2; }
      device_serial="$2"
      export ANDROID_SERIAL="$device_serial"
      shift
      ;;
    --sideload)
      [ "$#" -ge 2 ] || { echo "Missing value for --sideload" >&2; exit 2; }
      SIDELOAD_ZIP="$2"
      shift
      ;;
    --timeout)
      [ "$#" -ge 2 ] || { echo "Missing value for --timeout" >&2; exit 2; }
      TIMEOUT_SEC="$2"
      shift
      ;;
    --poll)
      [ "$#" -ge 2 ] || { echo "Missing value for --poll" >&2; exit 2; }
      POLL_SEC="$2"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

validate_seconds() {
  local name="$1"
  local value="$2"
  if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -lt 1 ]; then
    echo "$name must be a positive integer, got: $value" >&2
    exit 2
  fi
}

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

cleanup() {
  phone_lock_release
  rm -rf "$LOCK_DIR"
}

on_err() {
  local rc=$?
  log "ERROR: command failed near line $1: $2 (exit $rc)"
  exit "$rc"
}

validate_seconds TIMEOUT_SEC "$TIMEOUT_SEC"
validate_seconds POLL_SEC "$POLL_SEC"

mkdir -p "$HOTDOG_LOG_ROOT"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  if [ -f "$LOCK_DIR/pid" ] && ! kill -0 "$(cat "$LOCK_DIR/pid")" 2>/dev/null; then
    rm -rf "$LOCK_DIR"
    mkdir "$LOCK_DIR"
  else
    echo "Another watch-fastboot-dump instance appears to be running: $LOCK_DIR" >&2
    exit 2
  fi
fi
trap cleanup EXIT
trap 'on_err "$LINENO" "$BASH_COMMAND"' ERR
printf '%s\n' "$$" > "$LOCK_DIR/pid"

mkdir -p "$run_dir"
exec > >(tee "$run_dir/watch.log") 2>&1

log "Run directory: $run_dir"
log "Watcher PID: $$"
log "Timeout: ${TIMEOUT_SEC}s"
log "Poll interval: ${POLL_SEC}s"
log "Target serial: ${device_serial:-auto-detect}"
log "Flash/dump script: $FLASH_SCRIPT"
log "Sideload ZIP: ${SIDELOAD_ZIP:-none}"

[ -x "$FLASH_SCRIPT" ] || { log "ERROR: missing executable $FLASH_SCRIPT"; exit 127; }
[ -z "$SIDELOAD_ZIP" ] || [ -r "$SIDELOAD_ZIP" ] || { log "ERROR: sideload ZIP is not readable: $SIDELOAD_ZIP"; exit 2; }

adb_reboot_bootloader() {
  local serial="$1"
  if [ -n "$serial" ]; then
    adb -s "$serial" reboot bootloader
  else
    adb reboot bootloader
  fi
}

adb_sideload_zip() {
  local serial="$1"
  if [ -n "$serial" ]; then
    adb -s "$serial" sideload "$SIDELOAD_ZIP"
  else
    adb sideload "$SIDELOAD_ZIP"
  fi
}

run_flash_script() {
  local rc=0
  if ! phone_lock_acquire "watch-fastboot-dump flash/dump" "$TIMEOUT_SEC"; then
    exit 2
  fi

  if [ "$#" -gt 0 ]; then
    "$FLASH_SCRIPT" "$@"
  else
    "$FLASH_SCRIPT"
  fi
  rc=$?
  phone_lock_release
  exit "$rc"
}

deadline=$((SECONDS + TIMEOUT_SEC))
last_status=0
unauthorized_since=0
unauthorized_last_log=0
unauthorized_key=""

while [ "$SECONDS" -lt "$deadline" ]; do
  adb devices -l > "$run_dir/adb-devices-last.txt" 2>&1 || true
  fastboot devices -l > "$run_dir/fastboot-devices-last.txt" 2>&1 || true
  lsusb > "$run_dir/lsusb-last.txt" 2>&1 || true

  if [ -n "$device_serial" ]; then
    if awk -v serial="$device_serial" 'NF >= 2 && $1 == serial { found=1 } END { exit found ? 0 : 1 }' "$run_dir/fastboot-devices-last.txt"; then
      log "Fastboot target detected: $device_serial"
      run_flash_script --serial "$device_serial" --fastboot-timeout 30
    fi
  elif awk 'NF >= 2 { found=1 } END { exit found ? 0 : 1 }' "$run_dir/fastboot-devices-last.txt"; then
    log "Fastboot device detected"
    run_flash_script --fastboot-timeout 30
  fi

  adb_serial=""
  adb_state=""
  if [ -n "$device_serial" ]; then
    adb_state="$(awk -v serial="$device_serial" 'NF >= 2 && $1 == serial { print $2; exit }' "$run_dir/adb-devices-last.txt")"
    adb_serial="$device_serial"
  else
    adb_count="$(awk 'NF >= 2 && $1 != "List" && $1 !~ /^\*/ { count++ } END { print count + 0 }' "$run_dir/adb-devices-last.txt")"
    if [ "$adb_count" -eq 1 ]; then
      adb_serial="$(awk 'NF >= 2 && $1 != "List" && $1 !~ /^\*/ { print $1; exit }' "$run_dir/adb-devices-last.txt")"
      adb_state="$(awk 'NF >= 2 && $1 != "List" && $1 !~ /^\*/ { print $2; exit }' "$run_dir/adb-devices-last.txt")"
    fi
  fi

  case "$adb_state" in
    device|recovery)
      if ! phone_lock_acquire "watch-fastboot-dump adb reboot bootloader and dump" "$TIMEOUT_SEC"; then
        exit 2
      fi
      log "Authorized adb state detected ($adb_state, serial ${adb_serial:-auto}); rebooting to bootloader"
      adb_reboot_bootloader "$adb_serial"
      sleep 5
      if [ -n "$adb_serial" ]; then
        "$FLASH_SCRIPT" --serial "$adb_serial" --fastboot-timeout "$TIMEOUT_SEC"
        rc=$?
        phone_lock_release
        exit "$rc"
      fi
      "$FLASH_SCRIPT" --fastboot-timeout "$TIMEOUT_SEC"
      rc=$?
      phone_lock_release
      exit "$rc"
      ;;
    unauthorized)
      current_unauthorized_key="${adb_serial:-unknown}|$(grep -E '18d1|2a70|05c6' "$run_dir/lsusb-last.txt" | tr '\n' ';' || true)"
      if [ "$current_unauthorized_key" != "$unauthorized_key" ]; then
        unauthorized_key="$current_unauthorized_key"
        unauthorized_since=$SECONDS
        unauthorized_last_log=0
        log "ADB unauthorized detected for serial ${adb_serial:-unknown}; USB signature: ${current_unauthorized_key#*|}"
      elif [ "$unauthorized_since" -gt 0 ] && [ $((SECONDS - unauthorized_since)) -ge 300 ] && [ $((SECONDS - unauthorized_last_log)) -ge 300 ]; then
        log "ADB has stayed unauthorized for $((SECONDS - unauthorized_since))s on the same USB signature; host cannot reboot or sideload until recovery exposes an authorized/sideload/fastboot/EDL state"
        unauthorized_last_log=$SECONDS
      fi
      ;;
    sideload)
      if [ -n "$SIDELOAD_ZIP" ]; then
        if ! phone_lock_acquire "watch-fastboot-dump adb sideload" "$TIMEOUT_SEC"; then
          exit 2
        fi
        log "ADB sideload detected; sideloading $SIDELOAD_ZIP"
        adb_sideload_zip "$adb_serial" | tee "$run_dir/adb-sideload.txt"
        phone_lock_release
        log "Sideload finished; continuing to watch for fastboot/adb"
      fi
      ;;
  esac

  if [ $((SECONDS - last_status)) -ge 30 ]; then
    log "Still waiting for fastboot or authorized adb. Current adb:"
    sed 's/^/[adb] /' "$run_dir/adb-devices-last.txt" || true
    log "Current matching USB devices:"
    grep -E '18d1|2a70|05c6' "$run_dir/lsusb-last.txt" | sed 's/^/[usb] /' || true
    last_status=$SECONDS
  fi

  sleep "$POLL_SEC"
done

log "Timed out waiting for fastboot"
exit 2
