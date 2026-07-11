#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/env.sh"

SERIAL="${ANDROID_SERIAL:-$HOTDOG_TARGET_SERIAL}"
RESTORE_IMAGE="${RESTORE_IMAGE:-$HOTDOG_STABLE_PMOS_BOOT_B}"
AFTER_RESTORE="${AFTER_RESTORE:-system}"
TIMEOUT_SEC="${TIMEOUT_SEC:-604800}"
RESCUE_TIMEOUT_SEC="${RESCUE_TIMEOUT_SEC:-604800}"
POLL_SEC="${POLL_SEC:-60}"
LABEL="${LABEL:-stable-guard}"
ALLOW_DUPLICATE="${ALLOW_DUPLICATE:-0}"
SUPERVISOR_RUNNING_PID=""

usage() {
  cat <<'USAGE'
Usage: watch-rescue-visible-supervisor.sh [options]

Passively supervise rescue-boot-b-when-visible.sh. This script does not flash,
reboot, sideload, or take the phone-operation lock. It only starts a detached
stable rescue watcher when no matching rescue watcher is alive.

Options:
  --serial SERIAL             Target serial. Defaults to ANDROID_SERIAL.
  --restore-boot-b FILE       Known-good boot_b image. Default: HOTDOG_STABLE_PMOS_BOOT_B.
  --after-restore MODE        recovery, system, bootloader, or none. Default: system.
  --timeout SEC               Supervisor lifetime. Default: 604800.
  --rescue-timeout SEC        Timeout for launched rescue watchers. Default: 604800.
  --poll SEC                  Supervisor poll interval. Default: 60.
  --label NAME                Label passed to start-stable-rescue-watcher. Default: stable-guard.
  --allow-duplicate           Allow another supervisor for the same serial/label.
  -h, --help                  Show this help.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --serial)
      [ "$#" -ge 2 ] || { echo "Missing value for --serial" >&2; exit 2; }
      SERIAL="$2"
      shift
      ;;
    --restore-boot-b)
      [ "$#" -ge 2 ] || { echo "Missing value for --restore-boot-b" >&2; exit 2; }
      RESTORE_IMAGE="$2"
      shift
      ;;
    --after-restore)
      [ "$#" -ge 2 ] || { echo "Missing value for --after-restore" >&2; exit 2; }
      AFTER_RESTORE="$2"
      shift
      ;;
    --timeout)
      [ "$#" -ge 2 ] || { echo "Missing value for --timeout" >&2; exit 2; }
      TIMEOUT_SEC="$2"
      shift
      ;;
    --rescue-timeout)
      [ "$#" -ge 2 ] || { echo "Missing value for --rescue-timeout" >&2; exit 2; }
      RESCUE_TIMEOUT_SEC="$2"
      shift
      ;;
    --poll)
      [ "$#" -ge 2 ] || { echo "Missing value for --poll" >&2; exit 2; }
      POLL_SEC="$2"
      shift
      ;;
    --label)
      [ "$#" -ge 2 ] || { echo "Missing value for --label" >&2; exit 2; }
      LABEL="$2"
      shift
      ;;
    --allow-duplicate)
      ALLOW_DUPLICATE=1
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

rescue_running() {
  local pid
  local args

  while read -r pid; do
    [ -n "$pid" ] || continue
    [ "$pid" != "$$" ] || continue
    args="$(ps -o args= -p "$pid" 2>/dev/null || true)"
    case "$args" in
      *"$HOTDOG_ROOT/scripts/rescue-boot-b-when-visible.sh"*"--serial $SERIAL"*|*"$HOTDOG_ROOT/scripts/rescue-boot-b-when-visible.sh"*"--serial=$SERIAL"*)
        return 0
        ;;
    esac
  done < <(pgrep -f "$HOTDOG_ROOT/scripts/rescue-boot-b-when-visible.sh" 2>/dev/null || true)

  return 1
}

safe_name() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9_.:-' '_'
}

args_has_option_value() {
  local args_text=" $1 "
  local opt="$2"
  local value="$3"

  printf '%s\n' "$args_text" | grep -F -- " $opt $value " >/dev/null 2>&1 ||
    printf '%s\n' "$args_text" | grep -F -- " $opt=$value " >/dev/null 2>&1
}

supervisor_running() {
  local pid
  local args
  local pids_file="$run_dir/supervisor-pids.txt"

  SUPERVISOR_RUNNING_PID=""
  pgrep -f "$HOTDOG_ROOT/scripts/watch-rescue-visible-supervisor.sh" > "$pids_file" 2>/dev/null || true
  while read -r pid; do
    [ -n "$pid" ] || continue
    [ "$pid" != "$$" ] || continue
    args="$(ps -o args= -p "$pid" 2>/dev/null || true)"
    if args_has_option_value "$args" "--serial" "$SERIAL" &&
      args_has_option_value "$args" "--label" "$LABEL"; then
      SUPERVISOR_RUNNING_PID="$pid"
      return 0
    fi
  done < "$pids_file"

  return 1
}

acquire_instance_lock() {
  local owner=""

  while true; do
    if mkdir "$instance_lock" 2>/dev/null; then
      printf '%s\n' "$$" > "$instance_lock/pid"
      return 0
    fi

    owner="$(sed -n '1p' "$instance_lock/pid" 2>/dev/null || true)"
    if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
      echo "Supervisor instance lock is busy by PID $owner: $instance_lock" >&2
      return 1
    fi

    rm -rf "$instance_lock"
  done
}

start_rescue() {
  "$HOTDOG_ROOT/scripts/start-stable-rescue-watcher.sh" \
    --serial "$SERIAL" \
    --restore-boot-b "$RESTORE_IMAGE" \
    --after-restore "$AFTER_RESTORE" \
    --timeout "$RESCUE_TIMEOUT_SEC" \
    --poll 5 \
    --label "$LABEL"
}

main() {
  validate_seconds TIMEOUT_SEC "$TIMEOUT_SEC"
  validate_seconds RESCUE_TIMEOUT_SEC "$RESCUE_TIMEOUT_SEC"
  validate_seconds POLL_SEC "$POLL_SEC"
  [ -n "$SERIAL" ] || {
    echo "Set ANDROID_SERIAL or HOTDOG_TARGET_SERIAL" >&2
    exit 2
  }
  [ -s "$RESTORE_IMAGE" ] || {
    echo "Missing restore image: $RESTORE_IMAGE" >&2
    exit 2
  }

  stamp="$(date +%F-%H%M%S)"
  run_dir="$HOTDOG_LOG_ROOT/watch-rescue-visible-supervisor-$stamp"
  mkdir -p "$run_dir"
  exec > >(tee "$run_dir/run.log") 2>&1

  safe_serial="$(safe_name "$SERIAL")"
  safe_label="$(safe_name "$LABEL")"
  instance_lock="$HOTDOG_LOG_ROOT/manual-rescue-watchers/rescue-supervisor-${safe_serial}-${safe_label}.lock"
  mkdir -p "$HOTDOG_LOG_ROOT/manual-rescue-watchers"
  if [ "$ALLOW_DUPLICATE" -ne 1 ]; then
    if supervisor_running; then
      log "Supervisor already running for $SERIAL/$LABEL: PID $SUPERVISOR_RUNNING_PID"
      exit 0
    fi
  fi
  if ! acquire_instance_lock; then
    exit 0
  fi
  trap 'rm -rf "$instance_lock"' EXIT

  log "Run directory: $run_dir"
  log "Target serial: $SERIAL"
  log "Restore image: $RESTORE_IMAGE"
  log "After restore: $AFTER_RESTORE"
  log "Supervisor timeout: ${TIMEOUT_SEC}s"
  log "Launched rescue timeout: ${RESCUE_TIMEOUT_SEC}s"
  log "Poll: ${POLL_SEC}s"

  local deadline=$((SECONDS + TIMEOUT_SEC))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if rescue_running; then
      log "Rescue watcher already alive for $SERIAL"
    else
      log "No rescue watcher alive for $SERIAL; starting stable rescue watcher"
      start_rescue || log "Failed to start stable rescue watcher"
    fi
    sleep "$POLL_SEC"
  done

  log "Supervisor timeout reached"
}

main "$@"
