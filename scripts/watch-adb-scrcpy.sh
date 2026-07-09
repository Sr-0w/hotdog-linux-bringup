#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/env.sh"

TIMEOUT_SEC="${TIMEOUT_SEC:-86400}"
POLL_SEC="${POLL_SEC:-3}"
RETRY_COOLDOWN_SEC="${RETRY_COOLDOWN_SEC:-20}"
LOCK_DIR="$HOTDOG_LOG_ROOT/watch-adb-scrcpy.lock"
stamp="$(date +%F-%H%M%S)"
run_dir="$HOTDOG_LOG_ROOT/watch-adb-scrcpy-$stamp"
device_serial="${ANDROID_SERIAL:-}"
scrcpy_pid=""
last_launch_attempt=0

usage() {
  cat <<'USAGE'
Usage: watch-adb-scrcpy.sh [options]

Wait for an authorized Android ADB "device" state, then launch scrcpy in the
current KDE/Wayland desktop session. Does not act on recovery, sideload,
unauthorized, fastboot, EDL, or postmarketOS SSH states.

Options:
  --serial SERIAL       Restrict to one ADB serial.
  --timeout SEC         Seconds to monitor. Default: 86400.
  --poll SEC            Poll interval. Default: 3.
  --retry-cooldown SEC  Minimum seconds between scrcpy launches. Default: 20.
  -h, --help            Show this help.
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
    --retry-cooldown)
      [ "$#" -ge 2 ] || { echo "Missing value for --retry-cooldown" >&2; exit 2; }
      RETRY_COOLDOWN_SEC="$2"
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

die() {
  log "ERROR: $1"
  exit "${2:-1}"
}

validate_seconds() {
  local name="$1"
  local value="$2"
  if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -lt 1 ]; then
    die "$name must be a positive integer, got: $value" 2
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

import_env_from_pid() {
  local pid="$1"
  local env_file="/proc/$pid/environ"

  [ -r "$env_file" ] || return 1
  while IFS='=' read -r key value; do
    case "$key" in
      DISPLAY|WAYLAND_DISPLAY|XDG_RUNTIME_DIR|DBUS_SESSION_BUS_ADDRESS|XAUTHORITY)
        export "$key=$value"
        ;;
    esac
  done < <(tr '\0' '\n' < "$env_file")
}

import_kde_env() {
  local pid=""

  for name in kwin_wayland plasmashell kded6; do
    pid="$(pgrep -u "$(id -u)" -n "$name" 2>/dev/null || true)"
    if [ -n "$pid" ] && import_env_from_pid "$pid"; then
      log "Imported desktop environment from $name PID $pid"
      return 0
    fi
  done

  [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ] || return 1
}

adb_target_state() {
  local count
  local serial=""
  local state=""

  adb devices -l > "$run_dir/adb-devices-last.txt" 2>&1 || true
  if [ -n "$device_serial" ]; then
    state="$(awk -v serial="$device_serial" 'NF >= 2 && $1 == serial { print $2; exit }' "$run_dir/adb-devices-last.txt")"
    [ -n "$state" ] && printf '%s %s\n' "$device_serial" "$state"
    return 0
  fi

  count="$(awk 'NF >= 2 && $1 != "List" && $1 !~ /^\*/ { count++ } END { print count + 0 }' "$run_dir/adb-devices-last.txt")"
  if [ "$count" -eq 1 ]; then
    serial="$(awk 'NF >= 2 && $1 != "List" && $1 !~ /^\*/ { print $1; exit }' "$run_dir/adb-devices-last.txt")"
    state="$(awk 'NF >= 2 && $1 != "List" && $1 !~ /^\*/ { print $2; exit }' "$run_dir/adb-devices-last.txt")"
    printf '%s %s\n' "$serial" "$state"
  elif [ "$count" -gt 1 ]; then
    log "Multiple ADB devices found; waiting for --serial-targetable state"
    sed 's/^/[adb] /' "$run_dir/adb-devices-last.txt"
  fi
}

scrcpy_running_for_serial() {
  local serial="$1"

  if [ -n "$scrcpy_pid" ] && kill -0 "$scrcpy_pid" 2>/dev/null; then
    return 0
  fi

  pgrep -af "scrcpy.*(--serial|-s)[= ]*$serial|scrcpy.*$serial" >/dev/null 2>&1
}

launch_scrcpy() {
  local serial="$1"
  local log_file="$run_dir/scrcpy-$serial-$(date +%F-%H%M%S).log"

  if ! import_kde_env; then
    log "No KDE/Wayland/X11 session environment available yet; cannot launch scrcpy"
    return 1
  fi

  log "Launching scrcpy for serial $serial"
  {
    printf 'DISPLAY=%s\n' "${DISPLAY:-}"
    printf 'WAYLAND_DISPLAY=%s\n' "${WAYLAND_DISPLAY:-}"
    printf 'XDG_RUNTIME_DIR=%s\n' "${XDG_RUNTIME_DIR:-}"
    printf 'DBUS_SESSION_BUS_ADDRESS=%s\n' "${DBUS_SESSION_BUS_ADDRESS:-}"
    printf 'XAUTHORITY=%s\n' "${XAUTHORITY:-}"
  } > "$run_dir/scrcpy-env-$serial.txt"

  setsid -f scrcpy \
    --serial "$serial" \
    --window-title "OnePlus 7T Pro - $serial" \
    --no-audio \
    > "$log_file" 2>&1 &
  scrcpy_pid=$!
  printf '%s\n' "$scrcpy_pid" > "$run_dir/scrcpy.pid"
  log "scrcpy PID $scrcpy_pid; log: $log_file"
}

main() {
  validate_seconds TIMEOUT_SEC "$TIMEOUT_SEC"
  validate_seconds POLL_SEC "$POLL_SEC"
  validate_seconds RETRY_COOLDOWN_SEC "$RETRY_COOLDOWN_SEC"
  command -v adb >/dev/null 2>&1 || die "Missing adb" 127
  command -v scrcpy >/dev/null 2>&1 || die "Missing scrcpy" 127
  command -v pgrep >/dev/null 2>&1 || die "Missing pgrep" 127

  mkdir -p "$HOTDOG_LOG_ROOT"
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    if [ -f "$LOCK_DIR/pid" ] && ! kill -0 "$(cat "$LOCK_DIR/pid")" 2>/dev/null; then
      rm -rf "$LOCK_DIR"
      mkdir "$LOCK_DIR"
    else
      echo "Another watch-adb-scrcpy instance appears to be running: $LOCK_DIR" >&2
      exit 2
    fi
  fi
  trap cleanup EXIT
  trap 'on_err "$LINENO" "$BASH_COMMAND"' ERR
  printf '%s\n' "$$" > "$LOCK_DIR/pid"

  mkdir -p "$run_dir"
  exec > >(tee "$run_dir/run.log") 2>&1

  log "Run directory: $run_dir"
  log "Watcher PID: $$"
  log "Target serial: ${device_serial:-auto-detect}"
  log "Timeout: ${TIMEOUT_SEC}s"
  log "Poll interval: ${POLL_SEC}s"

  local deadline=$((SECONDS + TIMEOUT_SEC))
  local adb_info=""
  local serial=""
  local state=""
  local last_state=""

  while [ "$SECONDS" -lt "$deadline" ]; do
    adb_info="$(adb_target_state || true)"
    if [ -n "$adb_info" ]; then
      serial="${adb_info%% *}"
      state="${adb_info#* }"
    else
      serial=""
      state="none"
    fi

    if [ "$serial $state" != "$last_state" ]; then
      log "ADB state: ${serial:-none} $state"
      last_state="$serial $state"
    fi

    if [ "$state" = "device" ] && [ -n "$serial" ]; then
      if scrcpy_running_for_serial "$serial"; then
        :
      elif [ $((SECONDS - last_launch_attempt)) -ge "$RETRY_COOLDOWN_SEC" ]; then
        last_launch_attempt=$SECONDS
        launch_scrcpy "$serial" || true
      fi
    fi

    sleep "$POLL_SEC"
  done

  log "Timed out"
}

main "$@"
