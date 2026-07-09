#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/env.sh"

pid_line() {
  local label="$1"
  local pid_file="$2"
  local pid=""

  if [ ! -s "$pid_file" ]; then
    printf '%-24s missing\n' "$label"
    return 0
  fi

  pid="$(sed -n '1p' "$pid_file" 2>/dev/null || true)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    printf '%-24s running pid=%s elapsed=%s\n' \
      "$label" \
      "$pid" \
      "$(ps -o etime= -p "$pid" 2>/dev/null | awk '{$1=$1; print}')"
  else
    printf '%-24s stale pid=%s\n' "$label" "${pid:-unknown}"
  fi
}

latest_dir() {
  local base="$1"
  local pattern="$2"
  find "$base" -maxdepth 1 -type d -name "$pattern" 2>/dev/null | sort | tail -n 1
}

print_tail() {
  local label="$1"
  local file="$2"
  local lines="${3:-20}"

  printf '\n== %s ==\n' "$label"
  if [ -s "$file" ]; then
    tail -n "$lines" "$file"
  else
    printf 'missing: %s\n' "$file"
  fi
}

print_head() {
  local label="$1"
  local file="$2"
  local lines="${3:-80}"

  printf '\n== %s ==\n' "$label"
  if [ -s "$file" ]; then
    sed -n "1,${lines}p" "$file"
  else
    printf 'missing: %s\n' "$file"
  fi
}

main() {
  printf 'timestamp=%s\n' "$(date '+%F %T')"
  printf 'root=%s\n\n' "$HOTDOG_ROOT"

  printf '== processes ==\n'
  pid_line fastboot-dump "$HOTDOG_LOG_ROOT/watch-fastboot-dump.pid"
  pid_line edl-critical "$HOTDOG_LOG_ROOT/watch-edl-dump-critical.pid"
  pid_line continue-pmos "$HOTDOG_LOG_ROOT/continue-after-dump-to-pmos.pid"
  pid_line phone-state "$HOTDOG_LOG_ROOT/watch-phone-state.pid"
  pid_line stall-summary "$HOTDOG_LOG_ROOT/watch-stall-summary.pid"
  pid_line adb-scrcpy "$HOTDOG_LOG_ROOT/watch-adb-scrcpy.pid"
  pid_line autopilot-health "$HOTDOG_LOG_ROOT/watch-autopilot-health.pid"

  printf '\n== phone lock ==\n'
  if [ -d "$HOTDOG_LOG_ROOT/phone-operation.lock" ]; then
    sed -n '1,20p' "$HOTDOG_LOG_ROOT/phone-operation.lock/pid" 2>/dev/null || true
  else
    printf 'absent\n'
  fi

  printf '\n== live devices ==\n'
  adb devices -l 2>&1 || true
  fastboot devices -l 2>&1 || true
  lsusb 2>/dev/null | grep -Ei '18d1|2a70|05c6' || true

  local state_dir
  local fastboot_dir
  local continue_dir
  local stall_dir
  local scrcpy_dir
  local health_dir
  local edl_dir

  state_dir="$(latest_dir "$HOTDOG_LOG_ROOT" 'watch-phone-state-*')"
  fastboot_dir="$(latest_dir "$HOTDOG_LOG_ROOT" 'watch-fastboot-dump-*')"
  continue_dir="$(latest_dir "$HOTDOG_LOG_ROOT" 'continue-after-dump-to-pmos-*')"
  stall_dir="$(latest_dir "$HOTDOG_LOG_ROOT" 'watch-stall-summary-*')"
  scrcpy_dir="$(latest_dir "$HOTDOG_LOG_ROOT" 'watch-adb-scrcpy-*')"
  health_dir="$(latest_dir "$HOTDOG_LOG_ROOT" 'watch-autopilot-health-*')"
  edl_dir="$(latest_dir "$HOTDOG_DUMP_ROOT/stock-before-flash" '*-edl-critical-blocks')"

  printf '\n== latest dirs ==\n'
  printf 'state=%s\n' "${state_dir:-none}"
  printf 'fastboot=%s\n' "${fastboot_dir:-none}"
  printf 'continue=%s\n' "${continue_dir:-none}"
  printf 'stall=%s\n' "${stall_dir:-none}"
  printf 'scrcpy=%s\n' "${scrcpy_dir:-none}"
  printf 'health=%s\n' "${health_dir:-none}"
  printf 'edl=%s\n' "${edl_dir:-none}"

  [ -n "$state_dir" ] && print_tail phone-state "$state_dir/latest-summary.txt" 40
  [ -n "$fastboot_dir" ] && print_tail fastboot-dump "$fastboot_dir/watch.log" 25
  [ -n "$continue_dir" ] && print_tail continue-pmos "$continue_dir/run.log" 25
  [ -n "$stall_dir" ] && print_tail stall-summary "$stall_dir/run.log" 25
  [ -s "$HOTDOG_LOG_ROOT/current-stall-summary.txt" ] && print_head current-stall-summary "$HOTDOG_LOG_ROOT/current-stall-summary.txt" 90
  [ -n "$scrcpy_dir" ] && print_tail adb-scrcpy "$scrcpy_dir/run.log" 25
  [ -n "$health_dir" ] && print_tail autopilot-health "$health_dir/run.log" 25
  [ -n "$edl_dir" ] && print_tail edl-critical "$edl_dir/run.log" 25
}

main "$@"
