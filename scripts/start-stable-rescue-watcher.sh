#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/env.sh"

SERIAL="${ANDROID_SERIAL:-b6bd2252}"
RESTORE_IMAGE="${RESTORE_IMAGE:-$HOTDOG_STABLE_PMOS_BOOT_B}"
AFTER_RESTORE="${AFTER_RESTORE:-system}"
TIMEOUT_SEC="${TIMEOUT_SEC:-21600}"
POLL_SEC="${POLL_SEC:-5}"
LABEL="${LABEL:-stable-drm}"

usage() {
  cat <<'USAGE'
Usage: start-stable-rescue-watcher.sh [options]

Start a detached rescue watcher that restores the known-good boot_b image when
the phone appears in fastboot or recovery ADB. This script is intended for long
Codex sessions where a normal background child can be reaped with the command.

Options:
  --serial SERIAL        Target serial. Default: b6bd2252.
  --restore-boot-b FILE  Known-good boot_b image. Default: HOTDOG_STABLE_PMOS_BOOT_B.
  --after-restore MODE   recovery, system, bootloader, or none. Default: system.
  --timeout SEC          Watcher timeout. Default: 21600.
  --poll SEC             Poll interval. Default: 5.
  --label NAME           Log/pid label. Default: stable-drm.
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
pidfile="$watch_dir/rescue-${LABEL}-current.pid"
stdout_log="$watch_dir/rescue-${LABEL}-start-stop-daemon-$stamp.log"
stderr_log="$watch_dir/rescue-${LABEL}-start-stop-daemon-$stamp.err"
current_log="$watch_dir/rescue-${LABEL}-current.log"

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
