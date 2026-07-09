#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/env.sh"
source "$(dirname "$0")/phone-lock.sh"

TIMEOUT_SEC="${TIMEOUT_SEC:-604800}"
POLL_SEC="${POLL_SEC:-60}"
RESTART_COOLDOWN_SEC="${RESTART_COOLDOWN_SEC:-300}"
STATE_POLL_SEC="${STATE_POLL_SEC:-5}"
STALL_POLL_SEC="${STALL_POLL_SEC:-30}"
FLASH_TIMEOUT_SEC="${FLASH_TIMEOUT_SEC:-900}"
SSH_TIMEOUT_SEC="${SSH_TIMEOUT_SEC:-1200}"
HANDOFF_TIMEOUT_SEC="${HANDOFF_TIMEOUT_SEC:-180}"
CHECK_ONCE=0
TARGET_SERIAL="${ANDROID_SERIAL:-${HOTDOG_TARGET_SERIAL:-}}"
LOCK_DIR="$HOTDOG_LOG_ROOT/watch-autopilot-health.lock"
PID_FILE="$HOTDOG_LOG_ROOT/watch-autopilot-health.pid"
stamp="$(date +%F-%H%M%S)"
run_dir="$HOTDOG_LOG_ROOT/watch-autopilot-health-$stamp"

usage() {
  cat <<'USAGE'
Usage: watch-autopilot-health.sh [options]

Passively supervise the six core autopilot watchers. If one is missing, stale,
or no longer matches its expected script, and no phone operation lock is held,
restart the core watcher set via start-autopilot-watchers.sh --restart.

This script does not run adb/fastboot/edl write actions itself.

Options:
  --timeout SEC           Seconds to supervise. Default: 604800.
  --poll SEC              Poll interval. Default: 60.
  --restart-cooldown SEC  Minimum seconds between restarts. Default: 300.
  --check-once            Check core watchers once without taking the daemon lock
                          or restarting anything.
  --serial SERIAL         Re-arm targetable watchers for this ADB/fastboot serial.
  --state-poll SEC        Re-armed phone-state poll interval. Default: 5.
  --stall-poll SEC        Re-armed stall summary poll interval. Default: 30.
  --flash-timeout SEC     Re-armed pmOS flash fastboot timeout. Default: 900.
  --ssh-timeout SEC       Re-armed postmarketOS SSH timeout. Default: 1200.
  --handoff-timeout SEC   Re-armed handoff timeout. Default: 180.
  -h, --help              Show this help.
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
    --restart-cooldown)
      [ "$#" -ge 2 ] || { echo "Missing value for --restart-cooldown" >&2; exit 2; }
      RESTART_COOLDOWN_SEC="$2"
      shift
      ;;
    --check-once)
      CHECK_ONCE=1
      ;;
    --serial)
      [ "$#" -ge 2 ] || { echo "Missing value for --serial" >&2; exit 2; }
      TARGET_SERIAL="$2"
      export ANDROID_SERIAL="$TARGET_SERIAL"
      export HOTDOG_TARGET_SERIAL="$TARGET_SERIAL"
      shift
      ;;
    --state-poll)
      [ "$#" -ge 2 ] || { echo "Missing value for --state-poll" >&2; exit 2; }
      STATE_POLL_SEC="$2"
      shift
      ;;
    --stall-poll)
      [ "$#" -ge 2 ] || { echo "Missing value for --stall-poll" >&2; exit 2; }
      STALL_POLL_SEC="$2"
      shift
      ;;
    --flash-timeout)
      [ "$#" -ge 2 ] || { echo "Missing value for --flash-timeout" >&2; exit 2; }
      FLASH_TIMEOUT_SEC="$2"
      shift
      ;;
    --ssh-timeout)
      [ "$#" -ge 2 ] || { echo "Missing value for --ssh-timeout" >&2; exit 2; }
      SSH_TIMEOUT_SEC="$2"
      shift
      ;;
    --handoff-timeout)
      [ "$#" -ge 2 ] || { echo "Missing value for --handoff-timeout" >&2; exit 2; }
      HANDOFF_TIMEOUT_SEC="$2"
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
  rm -f "$PID_FILE"
}

on_err() {
  local rc=$?
  log "ERROR: command failed near line $1: $2 (exit $rc)"
  exit "$rc"
}

pid_alive() {
  local pid="$1"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

watcher_status() {
  local label="$1"
  local pid_file="$2"
  local pattern="$3"
  local pid=""
  local args=""

  if [ ! -s "$pid_file" ]; then
    printf '%s missing pid_file=%s\n' "$label" "$pid_file"
    return 1
  fi

  pid="$(sed -n '1p' "$pid_file" 2>/dev/null || true)"
  if ! pid_alive "$pid"; then
    printf '%s stale pid=%s pid_file=%s\n' "$label" "${pid:-unknown}" "$pid_file"
    return 1
  fi

  args="$(ps -o args= -p "$pid" 2>/dev/null || true)"
  case "$args" in
    *"$pattern"*)
      printf '%s ok pid=%s\n' "$label" "$pid"
      return 0
      ;;
    *)
      printf '%s mismatched pid=%s expected=%s args=%s\n' "$label" "$pid" "$pattern" "$args"
      return 1
      ;;
  esac
}

phone_operation_busy() {
  if [ ! -d "$PHONE_LOCK_DIR" ]; then
    return 1
  fi

  if phone_lock_break_if_stale; then
    return 1
  fi

  return 0
}

restart_core_watchers() {
  local restart_args=(
    --restart
    --no-health
    --timeout "$TIMEOUT_SEC"
    --state-poll "$STATE_POLL_SEC"
    --stall-poll "$STALL_POLL_SEC"
    --flash-timeout "$FLASH_TIMEOUT_SEC"
    --ssh-timeout "$SSH_TIMEOUT_SEC"
    --handoff-timeout "$HANDOFF_TIMEOUT_SEC"
  )
  [ -z "$TARGET_SERIAL" ] || restart_args+=(--serial "$TARGET_SERIAL")

  log "Restarting core autopilot watchers"
  "$HOTDOG_ROOT/scripts/start-autopilot-watchers.sh" "${restart_args[@]}"
}

check_core_watchers() {
  local status_file="$1"
  local failures_file="$2"
  local failure_count=0

  : > "$status_file"
  : > "$failures_file"

  watcher_status fastboot-dump "$HOTDOG_LOG_ROOT/watch-fastboot-dump.pid" "watch-fastboot-dump.sh" >> "$status_file" || {
    tail -n 1 "$status_file" >> "$failures_file"
    failure_count=$((failure_count + 1))
  }
  watcher_status edl-critical "$HOTDOG_LOG_ROOT/watch-edl-dump-critical.pid" "watch-edl-dump-critical.sh" >> "$status_file" || {
    tail -n 1 "$status_file" >> "$failures_file"
    failure_count=$((failure_count + 1))
  }
  watcher_status continue-pmos "$HOTDOG_LOG_ROOT/continue-after-dump-to-pmos.pid" "continue-after-dump-to-pmos.sh" >> "$status_file" || {
    tail -n 1 "$status_file" >> "$failures_file"
    failure_count=$((failure_count + 1))
  }
  watcher_status phone-state "$HOTDOG_LOG_ROOT/watch-phone-state.pid" "watch-phone-state.sh" >> "$status_file" || {
    tail -n 1 "$status_file" >> "$failures_file"
    failure_count=$((failure_count + 1))
  }
  watcher_status stall-summary "$HOTDOG_LOG_ROOT/watch-stall-summary.pid" "watch-stall-summary.sh" >> "$status_file" || {
    tail -n 1 "$status_file" >> "$failures_file"
    failure_count=$((failure_count + 1))
  }
  watcher_status adb-scrcpy "$HOTDOG_LOG_ROOT/watch-adb-scrcpy.pid" "watch-adb-scrcpy.sh" >> "$status_file" || {
    tail -n 1 "$status_file" >> "$failures_file"
    failure_count=$((failure_count + 1))
  }

  printf '%s\n' "$failure_count"
}

main() {
  validate_seconds TIMEOUT_SEC "$TIMEOUT_SEC"
  validate_seconds POLL_SEC "$POLL_SEC"
  validate_seconds RESTART_COOLDOWN_SEC "$RESTART_COOLDOWN_SEC"
  validate_seconds STATE_POLL_SEC "$STATE_POLL_SEC"
  validate_seconds STALL_POLL_SEC "$STALL_POLL_SEC"
  validate_seconds FLASH_TIMEOUT_SEC "$FLASH_TIMEOUT_SEC"
  validate_seconds SSH_TIMEOUT_SEC "$SSH_TIMEOUT_SEC"
  validate_seconds HANDOFF_TIMEOUT_SEC "$HANDOFF_TIMEOUT_SEC"

  mkdir -p "$HOTDOG_LOG_ROOT"
  if [ "$CHECK_ONCE" -eq 1 ]; then
    run_dir="$HOTDOG_LOG_ROOT/check-autopilot-health-$stamp"
  fi
  mkdir -p "$run_dir"

  if [ "$CHECK_ONCE" -eq 1 ]; then
    exec > >(tee "$run_dir/run.log") 2>&1
    log "Run directory: $run_dir"
    log "Mode: check-once"
    log "Target serial for restart policy: ${TARGET_SERIAL:-auto-detect}"
    local failure_count_once=0
    failure_count_once="$(check_core_watchers "$run_dir/status-last.txt" "$run_dir/failures-last.txt")"
    if [ "$failure_count_once" -eq 0 ]; then
      log "All core watchers healthy"
      exit 0
    fi
    log "Detected $failure_count_once unhealthy core watcher(s)"
    sed 's/^/[health] /' "$run_dir/failures-last.txt"
    exit 1
  fi

  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    if [ -f "$LOCK_DIR/pid" ] && ! kill -0 "$(cat "$LOCK_DIR/pid")" 2>/dev/null; then
      rm -rf "$LOCK_DIR"
      mkdir "$LOCK_DIR"
    else
      echo "Another watch-autopilot-health instance appears to be running: $LOCK_DIR" >&2
      exit 2
    fi
  fi
  trap cleanup EXIT
  trap 'on_err "$LINENO" "$BASH_COMMAND"' ERR
  printf '%s\n' "$$" > "$LOCK_DIR/pid"
  printf '%s\n' "$$" > "$PID_FILE"

  exec > >(tee "$run_dir/run.log") 2>&1

  log "Run directory: $run_dir"
  log "Watcher PID: $$"
  log "Timeout: ${TIMEOUT_SEC}s"
  log "Poll interval: ${POLL_SEC}s"
  log "Restart cooldown: ${RESTART_COOLDOWN_SEC}s"
  log "Target serial for restart policy: ${TARGET_SERIAL:-auto-detect}"

  local deadline=$((SECONDS + TIMEOUT_SEC))
  local last_restart=0
  local last_all_ok_log=-300
  local status_file=""
  local failures_file=""
  local failure_count=0

  while [ "$SECONDS" -lt "$deadline" ]; do
    status_file="$run_dir/status-last.txt"
    failures_file="$run_dir/failures-last.txt"
    failure_count="$(check_core_watchers "$status_file" "$failures_file")"

    if [ "$failure_count" -eq 0 ]; then
      if [ $((SECONDS - last_all_ok_log)) -ge 300 ]; then
        log "All core watchers healthy"
        last_all_ok_log=$SECONDS
      fi
      sleep "$POLL_SEC"
      continue
    fi

    log "Detected $failure_count unhealthy core watcher(s)"
    sed 's/^/[health] /' "$failures_file"

    if phone_operation_busy; then
      log "Phone operation lock is present; deferring watcher restart"
      sleep "$POLL_SEC"
      continue
    fi

    if [ "$last_restart" -gt 0 ] && [ $((SECONDS - last_restart)) -lt "$RESTART_COOLDOWN_SEC" ]; then
      log "Restart cooldown active; last restart was $((SECONDS - last_restart))s ago"
      sleep "$POLL_SEC"
      continue
    fi

    restart_core_watchers
    last_restart=$SECONDS
    sleep "$POLL_SEC"
  done

  log "Timed out"
}

main "$@"
