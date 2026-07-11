#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/env.sh"

SERIAL="${ANDROID_SERIAL:-$HOTDOG_TARGET_SERIAL}"
RESTORE_IMAGE="${RESTORE_IMAGE:-$HOTDOG_STABLE_PMOS_BOOT_B}"
AFTER_RESTORE="${AFTER_RESTORE:-system}"
TIMEOUT_SEC="${TIMEOUT_SEC:-21600}"
POLL_SEC="${POLL_SEC:-5}"
LABEL="${LABEL:-stable-drm}"
ALLOW_DUPLICATE="${ALLOW_DUPLICATE:-0}"

usage() {
  cat <<'USAGE'
Usage: start-stable-rescue-watcher.sh [options]

Start a detached rescue watcher that restores the known-good boot_b image when
the phone appears in fastboot or recovery ADB. This script is intended for long
Codex sessions where a normal background child can be reaped with the command.

Options:
  --serial SERIAL        Target serial. Defaults to ANDROID_SERIAL.
  --restore-boot-b FILE  Known-good boot_b image. Default: HOTDOG_STABLE_PMOS_BOOT_B.
  --after-restore MODE   recovery, system, bootloader, or none. Default: system.
  --timeout SEC          Watcher timeout. Default: 21600.
  --poll SEC             Poll interval. Default: 5.
  --label NAME           Log/pid label. Default: stable-drm.
  --allow-duplicate      Allow another rescue watcher for the same serial.
  -h, --help             Show this help.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --serial)
      SERIAL="$2"
      shift
      ;;
    --restore-boot-b)
      RESTORE_IMAGE="$2"
      shift
      ;;
    --after-restore)
      AFTER_RESTORE="$2"
      shift
      ;;
    --timeout)
      TIMEOUT_SEC="$2"
      shift
      ;;
    --poll)
      POLL_SEC="$2"
      shift
      ;;
    --label)
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

[ -n "$SERIAL" ] || {
  echo "Set ANDROID_SERIAL or HOTDOG_TARGET_SERIAL" >&2
  exit 2
}
[ -s "$RESTORE_IMAGE" ] || {
  echo "Missing restore image: $RESTORE_IMAGE" >&2
  exit 2
}
command -v start-stop-daemon >/dev/null 2>&1 || {
  echo "Missing start-stop-daemon" >&2
  exit 127
}

watch_dir="$HOTDOG_LOG_ROOT/manual-rescue-watchers"
mkdir -p "$watch_dir"

stamp="$(date +%F-%H%M%S)"
safe_name() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9_.:-' '_'
}

rescue_watcher_pid_for_serial() {
  local pid
  local args

  while read -r pid; do
    [ -n "$pid" ] || continue
    args="$(ps -o args= -p "$pid" 2>/dev/null || true)"
    case "$args" in
      *"$HOTDOG_ROOT/scripts/rescue-boot-b-when-visible.sh"*"--serial $SERIAL"*|*"$HOTDOG_ROOT/scripts/rescue-boot-b-when-visible.sh"*"--serial=$SERIAL"*)
        printf '%s\n' "$pid"
        return 0
        ;;
    esac
  done < <(pgrep -f "$HOTDOG_ROOT/scripts/rescue-boot-b-when-visible.sh" 2>/dev/null || true)

  return 1
}

acquire_start_lock() {
  local owner=""

  while true; do
    if mkdir "$start_lock" 2>/dev/null; then
      printf '%s\n' "$$" > "$start_lock/pid"
      return 0
    fi

    owner="$(sed -n '1p' "$start_lock/pid" 2>/dev/null || true)"
    if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
      echo "Rescue watcher start lock is busy by PID $owner: $start_lock" >&2
      return 1
    fi

    rm -rf "$start_lock"
  done
}

safe_serial="$(safe_name "$SERIAL")"
safe_label="$(safe_name "$LABEL")"
pidfile="$watch_dir/rescue-${safe_serial}-${safe_label}-current.pid"
stdout_log="$watch_dir/rescue-${safe_serial}-${safe_label}-start-stop-daemon-$stamp.log"
stderr_log="$watch_dir/rescue-${safe_serial}-${safe_label}-start-stop-daemon-$stamp.err"
current_log="$watch_dir/rescue-${safe_serial}-${safe_label}-current.log"
start_lock="$watch_dir/rescue-${safe_serial}.start.lock"

if ! acquire_start_lock; then
  exit 0
fi
trap 'rm -rf "$start_lock"' EXIT

if [ "$ALLOW_DUPLICATE" -ne 1 ]; then
  running_pid="$(rescue_watcher_pid_for_serial || true)"
  if [ -n "$running_pid" ]; then
    echo "Rescue watcher already running for $SERIAL: PID $running_pid"
    echo "Use --allow-duplicate only for intentional diagnostics."
    exit 0
  fi
fi

if [ -s "$pidfile" ]; then
  old_pid="$(sed -n '1p' "$pidfile" 2>/dev/null || true)"
  if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
    echo "Watcher already running: PID $old_pid"
    echo "pidfile=$pidfile"
    echo "log=$current_log"
    exit 0
  fi
fi

rm -f "$pidfile"

start-stop-daemon --start --background --make-pidfile --pidfile "$pidfile" \
  --chdir "$HOTDOG_ROOT" \
  --env HOTDOG_RESCUE_LOG_TEE=0 \
  --stdout "$stdout_log" --stderr "$stderr_log" \
  --exec "$HOTDOG_ROOT/scripts/rescue-boot-b-when-visible.sh" -- \
  --serial "$SERIAL" \
  --restore-boot-b "$RESTORE_IMAGE" \
  --after-restore "$AFTER_RESTORE" \
  --timeout "$TIMEOUT_SEC" \
  --poll "$POLL_SEC"

ln -sfn "$stdout_log" "$current_log"
pid="$(sed -n '1p' "$pidfile")"

echo "Watcher started: PID $pid"
echo "pidfile=$pidfile"
echo "log=$current_log"
echo "stderr=$stderr_log"
