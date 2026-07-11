#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/env.sh"

TIMEOUT_SEC="${TIMEOUT_SEC:-604800}"
STATE_POLL_SEC="${STATE_POLL_SEC:-5}"
STALL_POLL_SEC="${STALL_POLL_SEC:-30}"
HEALTH_POLL_SEC="${HEALTH_POLL_SEC:-60}"
HEALTH_RESTART_COOLDOWN_SEC="${HEALTH_RESTART_COOLDOWN_SEC:-300}"
FLASH_TIMEOUT_SEC="${FLASH_TIMEOUT_SEC:-900}"
SSH_TIMEOUT_SEC="${SSH_TIMEOUT_SEC:-1200}"
HANDOFF_TIMEOUT_SEC="${HANDOFF_TIMEOUT_SEC:-180}"
SIDELOAD_ZIP="${SIDELOAD_ZIP:-$HOTDOG_ROOT/tools/recovery-zips/build/hotdog-reboot-bootloader.zip}"
TARGET_SERIAL="${ANDROID_SERIAL:-$HOTDOG_TARGET_SERIAL}"
RESTART=0
HEALTH=1

usage() {
  cat <<'USAGE'
Usage: start-autopilot-watchers.sh [options]

Start the hotdog first-boot automation watchers:
  - fastboot/ADB/sideload stock dump watcher
  - EDL read-only critical dump watcher
  - post-dump postmarketOS continuation watcher
  - passive phone state monitor
  - passive stall summary refresher
  - scrcpy launcher when Android ADB becomes authorized
  - passive autopilot health watcher

Options:
  --restart              Stop existing idle watchers first.
  --timeout SEC          Watcher lifetime. Default: 604800.
  --state-poll SEC       Passive state monitor poll interval. Default: 5.
  --stall-poll SEC       Passive stall summary poll interval. Default: 30.
  --health-poll SEC      Health watcher poll interval. Default: 60.
  --health-cooldown SEC  Health watcher restart cooldown. Default: 300.
  --serial SERIAL        Restrict targetable ADB/fastboot watchers to SERIAL.
                         Defaults to ANDROID_SERIAL or HOTDOG_TARGET_SERIAL.
  --no-health            Do not start or stop the health watcher.
  --flash-timeout SEC    Fastboot wait inside pmOS flash. Default: 900.
  --ssh-timeout SEC      postmarketOS SSH wait. Default: 1200.
  --handoff-timeout SEC  EDL/ADB/sideload handoff wait. Default: 180.
  -h, --help             Show this help.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --restart)
      RESTART=1
      ;;
    --timeout)
      [ "$#" -ge 2 ] || { echo "Missing value for --timeout" >&2; exit 2; }
      TIMEOUT_SEC="$2"
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
    --health-poll)
      [ "$#" -ge 2 ] || { echo "Missing value for --health-poll" >&2; exit 2; }
      HEALTH_POLL_SEC="$2"
      shift
      ;;
    --health-cooldown)
      [ "$#" -ge 2 ] || { echo "Missing value for --health-cooldown" >&2; exit 2; }
      HEALTH_RESTART_COOLDOWN_SEC="$2"
      shift
      ;;
    --serial)
      [ "$#" -ge 2 ] || { echo "Missing value for --serial" >&2; exit 2; }
      TARGET_SERIAL="$2"
      export ANDROID_SERIAL="$TARGET_SERIAL"
      export HOTDOG_TARGET_SERIAL="$TARGET_SERIAL"
      shift
      ;;
    --no-health)
      HEALTH=0
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

stop_idle_watcher() {
  local pid_file="$1"
  local pattern="$2"
  local pid=""
  local deadline=0

  [ -s "$pid_file" ] || return 0
  pid="$(sed -n '1p' "$pid_file" 2>/dev/null || true)"
  if ! pid_alive "$pid"; then
    rm -f "$pid_file"
    return 0
  fi

  if ! pid_matches "$pid" "$pattern"; then
    die "Refusing to stop PID $pid from $pid_file because it does not look like $pattern" 2
  fi

  log "Stopping $pattern PID $pid"
  kill "$pid" 2>/dev/null || true
  deadline=$((SECONDS + 10))
  while pid_alive "$pid" && [ "$SECONDS" -lt "$deadline" ]; do
    sleep 1
  done
  if pid_alive "$pid"; then
    die "$pattern PID $pid did not stop after SIGTERM" 2
  fi
  rm -f "$pid_file"
}

ensure_not_busy() {
  if [ -d "$HOTDOG_LOG_ROOT/phone-operation.lock" ]; then
    die "Phone operation lock is present; refusing to restart watchers during an active phone operation: $HOTDOG_LOG_ROOT/phone-operation.lock" 2
  fi
}

launch_detached() {
  local name="$1"
  local pid_file="$2"
  local log_file="$3"
  shift 3

  if [ -s "$pid_file" ]; then
    local pid
    pid="$(sed -n '1p' "$pid_file" 2>/dev/null || true)"
    if pid_alive "$pid"; then
      log "$name already running as PID $pid"
      return 0
    fi
    rm -f "$pid_file"
  fi

  setsid -f bash -c 'printf "%s\n" "$$" > "$1"; shift; exec "$@"' _ "$pid_file" "$@" > "$log_file" 2>&1
  sleep 1
  local new_pid
  new_pid="$(sed -n '1p' "$pid_file" 2>/dev/null || true)"
  pid_alive "$new_pid" || die "$name did not stay running; see $log_file" 1
  log "$name started as PID $new_pid"
}

main() {
  validate_seconds TIMEOUT_SEC "$TIMEOUT_SEC"
  validate_seconds STATE_POLL_SEC "$STATE_POLL_SEC"
  validate_seconds STALL_POLL_SEC "$STALL_POLL_SEC"
  validate_seconds HEALTH_POLL_SEC "$HEALTH_POLL_SEC"
  validate_seconds HEALTH_RESTART_COOLDOWN_SEC "$HEALTH_RESTART_COOLDOWN_SEC"
  validate_seconds FLASH_TIMEOUT_SEC "$FLASH_TIMEOUT_SEC"
  validate_seconds SSH_TIMEOUT_SEC "$SSH_TIMEOUT_SEC"
  validate_seconds HANDOFF_TIMEOUT_SEC "$HANDOFF_TIMEOUT_SEC"
  [ -n "$TARGET_SERIAL" ] || die "Set ANDROID_SERIAL or HOTDOG_TARGET_SERIAL" 2

  [ -r "$SIDELOAD_ZIP" ] || die "Sideload ZIP is not readable: $SIDELOAD_ZIP" 2
  mkdir -p "$HOTDOG_LOG_ROOT"
  ensure_not_busy

  if [ "$RESTART" -eq 1 ]; then
    stop_idle_watcher "$HOTDOG_LOG_ROOT/watch-fastboot-dump.pid" "watch-fastboot-dump.sh"
    stop_idle_watcher "$HOTDOG_LOG_ROOT/watch-edl-dump-critical.pid" "watch-edl-dump-critical.sh"
    stop_idle_watcher "$HOTDOG_LOG_ROOT/continue-after-dump-to-pmos.pid" "continue-after-dump-to-pmos.sh"
    stop_idle_watcher "$HOTDOG_LOG_ROOT/watch-phone-state.pid" "watch-phone-state.sh"
    stop_idle_watcher "$HOTDOG_LOG_ROOT/watch-stall-summary.pid" "watch-stall-summary.sh"
    stop_idle_watcher "$HOTDOG_LOG_ROOT/watch-adb-scrcpy.pid" "watch-adb-scrcpy.sh"
    if [ "$HEALTH" -eq 1 ]; then
      stop_idle_watcher "$HOTDOG_LOG_ROOT/watch-autopilot-health.pid" "watch-autopilot-health.sh"
    fi
    rm -rf \
      "$HOTDOG_LOG_ROOT/watch-fastboot-dump.lock" \
      "$HOTDOG_LOG_ROOT/watch-edl-dump-critical.lock" \
      "$HOTDOG_LOG_ROOT/continue-after-dump-to-pmos.lock" \
      "$HOTDOG_LOG_ROOT/watch-phone-state.lock" \
      "$HOTDOG_LOG_ROOT/watch-stall-summary.lock" \
      "$HOTDOG_LOG_ROOT/watch-adb-scrcpy.lock"
    if [ "$HEALTH" -eq 1 ]; then
      rm -rf "$HOTDOG_LOG_ROOT/watch-autopilot-health.lock"
    fi
  fi

  launch_detached fastboot-dump \
    "$HOTDOG_LOG_ROOT/watch-fastboot-dump.pid" \
    "$HOTDOG_LOG_ROOT/watch-fastboot-dump-launcher.log" \
    "$HOTDOG_ROOT/scripts/watch-fastboot-dump.sh" --timeout "$TIMEOUT_SEC" --sideload "$SIDELOAD_ZIP" --serial "$TARGET_SERIAL"

  launch_detached edl-critical-dump \
    "$HOTDOG_LOG_ROOT/watch-edl-dump-critical.pid" \
    "$HOTDOG_LOG_ROOT/watch-edl-dump-critical-launcher.log" \
    "$HOTDOG_ROOT/scripts/watch-edl-dump-critical.sh" --timeout "$TIMEOUT_SEC"

  launch_detached continue-to-pmos \
    "$HOTDOG_LOG_ROOT/continue-after-dump-to-pmos.pid" \
    "$HOTDOG_LOG_ROOT/continue-after-dump-to-pmos-launcher.log" \
    "$HOTDOG_ROOT/scripts/continue-after-dump-to-pmos.sh" \
      --timeout "$TIMEOUT_SEC" \
      --flash-timeout "$FLASH_TIMEOUT_SEC" \
      --ssh-timeout "$SSH_TIMEOUT_SEC" \
      --handoff-timeout "$HANDOFF_TIMEOUT_SEC" \
      --serial "$TARGET_SERIAL"

  launch_detached phone-state \
    "$HOTDOG_LOG_ROOT/watch-phone-state.pid" \
    "$HOTDOG_LOG_ROOT/watch-phone-state-launcher.log" \
    "$HOTDOG_ROOT/scripts/watch-phone-state.sh" --timeout "$TIMEOUT_SEC" --poll "$STATE_POLL_SEC"

  launch_detached stall-summary \
    "$HOTDOG_LOG_ROOT/watch-stall-summary.pid" \
    "$HOTDOG_LOG_ROOT/watch-stall-summary-launcher.log" \
    "$HOTDOG_ROOT/scripts/watch-stall-summary.sh" --timeout "$TIMEOUT_SEC" --poll "$STALL_POLL_SEC"

  launch_detached adb-scrcpy \
    "$HOTDOG_LOG_ROOT/watch-adb-scrcpy.pid" \
    "$HOTDOG_LOG_ROOT/watch-adb-scrcpy-launcher.log" \
    "$HOTDOG_ROOT/scripts/watch-adb-scrcpy.sh" --timeout "$TIMEOUT_SEC" --poll 3 --serial "$TARGET_SERIAL"

  if [ "$HEALTH" -eq 1 ]; then
    launch_detached autopilot-health \
      "$HOTDOG_LOG_ROOT/watch-autopilot-health.pid" \
      "$HOTDOG_LOG_ROOT/watch-autopilot-health-launcher.log" \
      "$HOTDOG_ROOT/scripts/watch-autopilot-health.sh" \
        --timeout "$TIMEOUT_SEC" \
        --poll "$HEALTH_POLL_SEC" \
        --restart-cooldown "$HEALTH_RESTART_COOLDOWN_SEC" \
        --state-poll "$STATE_POLL_SEC" \
        --stall-poll "$STALL_POLL_SEC" \
        --flash-timeout "$FLASH_TIMEOUT_SEC" \
        --ssh-timeout "$SSH_TIMEOUT_SEC" \
        --handoff-timeout "$HANDOFF_TIMEOUT_SEC" \
        --serial "$TARGET_SERIAL"
  fi

  log "Autopilot watchers are armed for ${TIMEOUT_SEC}s, target serial $TARGET_SERIAL"
}

main "$@"
