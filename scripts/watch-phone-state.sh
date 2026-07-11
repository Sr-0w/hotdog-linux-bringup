#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/env.sh"

TIMEOUT_SEC="${TIMEOUT_SEC:-28800}"
POLL_SEC="${POLL_SEC:-5}"
LOCK_DIR="$HOTDOG_LOG_ROOT/watch-phone-state.lock"
stamp="$(date +%F-%H%M%S)"
run_dir="$HOTDOG_LOG_ROOT/watch-phone-state-$stamp"

usage() {
  cat <<'USAGE'
Usage: watch-phone-state.sh [options]

Passively monitor ADB, fastboot, USB descriptors and recent kernel USB logs.
This script does not reboot, flash, sideload, or take the phone operation lock.

Options:
  --timeout SEC   Seconds to monitor. Default: 28800.
  --poll SEC      Poll interval. Default: 5.
  -h, --help      Show this help.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
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

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

validate_seconds() {
  local name="$1"
  local value="$2"
  if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -lt 1 ]; then
    echo "$name must be a positive integer, got: $value" >&2
    exit 2
  fi
}

cleanup() {
  rm -rf "$LOCK_DIR"
}

on_err() {
  local rc=$?
  log "ERROR: command failed near line $1: $2 (exit $rc)"
  exit "$rc"
}

capture_usb_details() {
  local snapshot_dir="$1"
  local bus=""
  local dev=""
  local node=""

  awk '/18d1|2a70|05c6/ { gsub(":", "", $4); print $2, $4 }' "$snapshot_dir/lsusb.txt" |
    while read -r bus dev; do
      [ -n "$bus" ] || continue
      [ -n "$dev" ] || continue
      node="/dev/bus/usb/$bus/$dev"
      timeout 5s lsusb -s "$bus:$dev" -v > "$snapshot_dir/lsusb-$bus-$dev-v.txt" 2>&1 || true
      if [ -e "$node" ]; then
        udevadm info --query=all --name="$node" > "$snapshot_dir/udev-$bus-$dev.txt" 2>&1 || true
      fi
    done
}

read_dmesg() {
  if dmesg --ctime >/dev/null 2>&1; then
    dmesg --ctime
  elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
    sudo dmesg --ctime
  else
    dmesg --ctime 2>&1 || true
  fi
}

write_snapshot() {
  local snapshot_dir="$1"

  mkdir -p "$snapshot_dir"
  adb devices -l > "$snapshot_dir/adb-devices.txt" 2>&1 || true
  hotdog_fastboot_devices > "$snapshot_dir/fastboot-devices.txt" 2>&1 || true
  lsusb > "$snapshot_dir/lsusb.txt" 2>&1 || true
  read_dmesg | tail -260 > "$snapshot_dir/dmesg-usb-tail.txt"
  grep -Ei 'usb|dwc3|xhci|cdc|ncm|rndis|android|qualcomm|05c6|18d1|2a70|descriptor|enumerat|disconnect|reset' \
    "$snapshot_dir/dmesg-usb-tail.txt" > "$snapshot_dir/dmesg-usb-interesting.txt" 2>/dev/null || true
  ls -l /dev/ttyACM* /dev/serial/by-id/* > "$snapshot_dir/tty-acm.txt" 2>&1 || true
  capture_usb_details "$snapshot_dir"

  {
    printf 'timestamp=%s\n' "$(date '+%F %T')"
    printf 'adb=\n'
    sed 's/^/  /' "$snapshot_dir/adb-devices.txt"
    printf 'fastboot=\n'
    sed 's/^/  /' "$snapshot_dir/fastboot-devices.txt"
    printf 'usb=\n'
    grep -Ei '18d1|2a70|05c6' "$snapshot_dir/lsusb.txt" | sed 's/^/  /' || true
    if [ -s "$snapshot_dir/dmesg-usb-interesting.txt" ]; then
      printf 'dmesg_usb=\n'
      tail -30 "$snapshot_dir/dmesg-usb-interesting.txt" | sed 's/^/  /'
    fi
    if [ -s "$snapshot_dir/tty-acm.txt" ]; then
      printf 'tty_acm=\n'
      sed 's/^/  /' "$snapshot_dir/tty-acm.txt"
    fi
    if [ -d "$HOTDOG_LOG_ROOT/phone-operation.lock" ]; then
      printf 'phone_lock=present\n'
      sed 's/^/  /' "$HOTDOG_LOG_ROOT/phone-operation.lock/pid" 2>/dev/null || true
    else
      printf 'phone_lock=absent\n'
    fi
  } > "$snapshot_dir/summary.txt"
}

snapshot_key() {
  local snapshot_dir="$1"

  {
    cat "$snapshot_dir/adb-devices.txt"
    cat "$snapshot_dir/fastboot-devices.txt"
    grep -Ei '18d1|2a70|05c6' "$snapshot_dir/lsusb.txt" || true
    cat "$snapshot_dir/dmesg-usb-interesting.txt" 2>/dev/null || true
    cat "$snapshot_dir/tty-acm.txt" 2>/dev/null || true
    if [ -d "$HOTDOG_LOG_ROOT/phone-operation.lock" ]; then
      cat "$HOTDOG_LOG_ROOT/phone-operation.lock/pid" 2>/dev/null || true
    fi
  } | sha256sum | awk '{ print $1 }'
}

main() {
  validate_seconds TIMEOUT_SEC "$TIMEOUT_SEC"
  validate_seconds POLL_SEC "$POLL_SEC"
  command -v adb >/dev/null 2>&1 || { echo "Missing adb" >&2; exit 127; }
  command -v fastboot >/dev/null 2>&1 || { echo "Missing fastboot" >&2; exit 127; }
  command -v lsusb >/dev/null 2>&1 || { echo "Missing lsusb" >&2; exit 127; }
  command -v udevadm >/dev/null 2>&1 || { echo "Missing udevadm" >&2; exit 127; }

  mkdir -p "$HOTDOG_LOG_ROOT"
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    if [ -f "$LOCK_DIR/pid" ] && ! kill -0 "$(cat "$LOCK_DIR/pid")" 2>/dev/null; then
      rm -rf "$LOCK_DIR"
      mkdir "$LOCK_DIR"
    else
      echo "Another watch-phone-state instance appears to be running: $LOCK_DIR" >&2
      exit 2
    fi
  fi
  trap cleanup EXIT
  trap 'on_err "$LINENO" "$BASH_COMMAND"' ERR
  printf '%s\n' "$$" > "$LOCK_DIR/pid"

  mkdir -p "$run_dir/snapshots"
  exec > >(tee "$run_dir/run.log") 2>&1

  log "Run directory: $run_dir"
  log "Watcher PID: $$"
  log "Timeout: ${TIMEOUT_SEC}s"
  log "Poll interval: ${POLL_SEC}s"

  local deadline=$((SECONDS + TIMEOUT_SEC))
  local last_key=""
  local key=""
  local count=0
  local snapshot_dir=""

  while [ "$SECONDS" -lt "$deadline" ]; do
    count=$((count + 1))
    snapshot_dir="$run_dir/snapshots/$(date +%F-%H%M%S)-$count"
    write_snapshot "$snapshot_dir"
    key="$(snapshot_key "$snapshot_dir")"
    cp "$snapshot_dir/summary.txt" "$run_dir/latest-summary.txt"

    if [ "$key" != "$last_key" ]; then
      log "State changed; snapshot: $snapshot_dir"
      sed 's/^/[state] /' "$snapshot_dir/summary.txt"
      last_key="$key"
    else
      rm -rf "$snapshot_dir"
    fi

    sleep "$POLL_SEC"
  done

  log "Timed out"
}

main "$@"
