#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/env.sh"
source "$(dirname "$0")/phone-lock.sh"

FORCE=0

usage() {
  cat <<'USAGE'
Usage: stop-autopilot-watchers.sh [options]

Stop the hotdog autopilot watcher processes without sending phone commands.
Refuses to stop during an active phone operation unless --force is used.

Options:
  --force     Stop watchers even if logs/phone-operation.lock is present.
  -h, --help  Show this help.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --force)
      FORCE=1
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

pid_alive() {
  local pid="$1"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

pid_matches() {
  local pid="$1"
  local pattern="$2"
  local args=""

  args="$(ps -o args= -p "$pid" 2>/dev/null || true)"
  case "$args" in
    *"$pattern"*) return 0 ;;
    *) return 1 ;;
  esac
}

stop_watcher() {
  local label="$1"
  local pid_file="$2"
  local pattern="$3"
  local lock_dir="$4"
  local pid=""
  local deadline=0

  if [ ! -s "$pid_file" ]; then
    rm -rf "$lock_dir"
    log "$label already stopped"
    return 0
  fi

  pid="$(sed -n '1p' "$pid_file" 2>/dev/null || true)"
  if ! pid_alive "$pid"; then
    log "$label had stale PID file: ${pid:-unknown}"
    rm -f "$pid_file"
    rm -rf "$lock_dir"
    return 0
  fi

  pid_matches "$pid" "$pattern" || die "Refusing to stop PID $pid from $pid_file; command does not match $pattern" 2

  log "Stopping $label PID $pid"
  kill "$pid" 2>/dev/null || true
  deadline=$((SECONDS + 10))
  while pid_alive "$pid" && [ "$SECONDS" -lt "$deadline" ]; do
    sleep 1
  done

  if pid_alive "$pid"; then
    die "$label PID $pid did not stop after SIGTERM" 2
  fi

  rm -f "$pid_file"
  rm -rf "$lock_dir"
  log "$label stopped"
}

ensure_safe_to_stop() {
  [ "$FORCE" -eq 1 ] && return 0
  [ -d "$PHONE_LOCK_DIR" ] || return 0
  phone_lock_break_if_stale && return 0
  die "Phone operation lock is present; refusing to stop watchers during active phone work: $PHONE_LOCK_DIR" 2
}

main() {
  mkdir -p "$HOTDOG_LOG_ROOT"
  ensure_safe_to_stop

  stop_watcher autopilot-health \
    "$HOTDOG_LOG_ROOT/watch-autopilot-health.pid" \
    "watch-autopilot-health.sh" \
    "$HOTDOG_LOG_ROOT/watch-autopilot-health.lock"

  stop_watcher fastboot-dump \
    "$HOTDOG_LOG_ROOT/watch-fastboot-dump.pid" \
    "watch-fastboot-dump.sh" \
    "$HOTDOG_LOG_ROOT/watch-fastboot-dump.lock"

  stop_watcher edl-critical \
    "$HOTDOG_LOG_ROOT/watch-edl-dump-critical.pid" \
    "watch-edl-dump-critical.sh" \
    "$HOTDOG_LOG_ROOT/watch-edl-dump-critical.lock"

  stop_watcher continue-pmos \
    "$HOTDOG_LOG_ROOT/continue-after-dump-to-pmos.pid" \
    "continue-after-dump-to-pmos.sh" \
    "$HOTDOG_LOG_ROOT/continue-after-dump-to-pmos.lock"

  stop_watcher phone-state \
    "$HOTDOG_LOG_ROOT/watch-phone-state.pid" \
    "watch-phone-state.sh" \
    "$HOTDOG_LOG_ROOT/watch-phone-state.lock"

  stop_watcher stall-summary \
    "$HOTDOG_LOG_ROOT/watch-stall-summary.pid" \
    "watch-stall-summary.sh" \
    "$HOTDOG_LOG_ROOT/watch-stall-summary.lock"

  stop_watcher adb-scrcpy \
    "$HOTDOG_LOG_ROOT/watch-adb-scrcpy.pid" \
    "watch-adb-scrcpy.sh" \
    "$HOTDOG_LOG_ROOT/watch-adb-scrcpy.lock"

  log "Autopilot watchers stopped"
}

main "$@"
