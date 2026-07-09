#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/env.sh"

TIMEOUT_SEC="${TIMEOUT_SEC:-28800}"
POLL_SEC="${POLL_SEC:-30}"
OUT_FILE="${OUT_FILE:-$HOTDOG_LOG_ROOT/current-stall-summary.txt}"
LOCK_DIR="$HOTDOG_LOG_ROOT/watch-stall-summary.lock"
stamp="$(date +%F-%H%M%S)"
run_dir="$HOTDOG_LOG_ROOT/watch-stall-summary-$stamp"

usage() {
  cat <<'USAGE'
Usage: watch-stall-summary.sh [options]

Passively refresh the current autopilot stall summary.
This script does not reboot, flash, sideload, or take the phone operation lock.

Options:
  --timeout SEC  Seconds to monitor. Default: 28800.
  --poll SEC     Poll interval. Default: 30.
  --out PATH     Current summary path. Default: logs/current-stall-summary.txt.
  -h, --help     Show this help.
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
    --out)
      [ "$#" -ge 2 ] || { echo "Missing value for --out" >&2; exit 2; }
      OUT_FILE="$2"
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

summary_key() {
  local file="$1"

  awk '
    /^## Live state$/ { keep=1; next }
    /^## / && keep { keep=0 }
    keep { print }
    /^## Diagnosis$/ { diag=1; next }
    /^## / && diag { diag=0 }
    diag { print }
  ' "$file" | sha256sum | awk '{ print $1 }'
}

main() {
  validate_seconds TIMEOUT_SEC "$TIMEOUT_SEC"
  validate_seconds POLL_SEC "$POLL_SEC"
  command -v adb >/dev/null 2>&1 || { echo "Missing adb" >&2; exit 127; }
  command -v fastboot >/dev/null 2>&1 || { echo "Missing fastboot" >&2; exit 127; }

  mkdir -p "$HOTDOG_LOG_ROOT" "$(dirname "$OUT_FILE")"
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    if [ -f "$LOCK_DIR/pid" ] && ! kill -0 "$(cat "$LOCK_DIR/pid")" 2>/dev/null; then
      rm -rf "$LOCK_DIR"
      mkdir "$LOCK_DIR"
    else
      echo "Another watch-stall-summary instance appears to be running: $LOCK_DIR" >&2
      exit 2
    fi
  fi
  trap cleanup EXIT
  trap 'on_err "$LINENO" "$BASH_COMMAND"' ERR
  printf '%s\n' "$$" > "$LOCK_DIR/pid"

  mkdir -p "$run_dir/summaries"
  exec > >(tee "$run_dir/run.log") 2>&1

  log "Run directory: $run_dir"
  log "Watcher PID: $$"
  log "Timeout: ${TIMEOUT_SEC}s"
  log "Poll interval: ${POLL_SEC}s"
  log "Current summary: $OUT_FILE"

  local deadline=$((SECONDS + TIMEOUT_SEC))
  local count=0
  local key=""
  local last_key=""
  local tmp_file=""
  local out_tmp_file=""
  local latest_tmp_file=""
  local snapshot_file=""
  local refresh_failed=0

  while [ "$SECONDS" -lt "$deadline" ]; do
    count=$((count + 1))
    tmp_file="$run_dir/summaries/current.tmp"
    out_tmp_file="$OUT_FILE.tmp.$$"
    latest_tmp_file="$run_dir/latest-summary.txt.tmp.$$"
    snapshot_file="$run_dir/summaries/$(date +%F-%H%M%S)-$count.txt"

    if SUMMARY_FILE_LABEL="$OUT_FILE" "$HOTDOG_ROOT/scripts/summarize-stall.sh" --out "$tmp_file" > "$run_dir/last-refresh.log" 2>&1; then
      if [ "$refresh_failed" -eq 1 ]; then
        log "Summary refresh recovered"
        refresh_failed=0
      fi
      cp "$tmp_file" "$out_tmp_file"
      mv -f "$out_tmp_file" "$OUT_FILE"
      cp "$tmp_file" "$latest_tmp_file"
      mv -f "$latest_tmp_file" "$run_dir/latest-summary.txt"
      key="$(summary_key "$tmp_file")"
      if [ "$key" != "$last_key" ]; then
        cp "$tmp_file" "$snapshot_file"
        log "Summary changed; snapshot: $snapshot_file"
        grep -E '^(blocked_reason=|adb: |fastboot: |usb: |phone_lock=)' "$tmp_file" | sed 's/^/[stall] /' || true
        last_key="$key"
      fi
      rm -f "$tmp_file"
    else
      rm -f "$out_tmp_file" "$latest_tmp_file"
      log "ERROR: summarize-stall failed; see $run_dir/last-refresh.log"
      refresh_failed=1
    fi

    sleep "$POLL_SEC"
  done

  log "Timed out"
}

main "$@"
