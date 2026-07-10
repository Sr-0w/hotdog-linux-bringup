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

pattern_lines() {
  local label="$1"
  local pattern="$2"
  local matches=""

  matches="$(pgrep -af "$pattern" 2>/dev/null || true)"
  if [ -z "$matches" ]; then
    printf '%-24s missing\n' "$label"
    return 0
  fi

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    local pid="${line%% *}"
    local ppid=""
    ppid="$(ps -o ppid= -p "$pid" 2>/dev/null | awk '{$1=$1; print}' || true)"
    [ "$ppid" = "1" ] || continue
    printf '%-24s running pid=%s elapsed=%s cmd=%s\n' \
      "$label" \
      "$pid" \
      "$(ps -o etime= -p "$pid" 2>/dev/null | awk '{$1=$1; print}')" \
      "${line#* }"
  done <<EOF
$matches
EOF
}

latest_dir() {
  local base="$1"
  local pattern="$2"
  find "$base" -maxdepth 1 -type d -name "$pattern" -printf '%T@ %p\n' 2>/dev/null |
    sort -n |
    tail -n 1 |
    cut -d' ' -f2-
}

latest_symlink_target() {
  local base="$1"
  local pattern="$2"
  local link=""
  local target=""

  link="$(find "$base" -maxdepth 1 -type l -name "$pattern" -printf '%T@ %p\n' 2>/dev/null |
    sort -n |
    tail -n 1 |
    cut -d' ' -f2-)"
  [ -n "$link" ] || return 0
  target="$(readlink -f "$link" 2>/dev/null || true)"
  [ -d "$target" ] || return 0
  printf '%s\n' "$target"
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

expand_hotdog_path() {
  local path="$1"

  case "$path" in
    '$HOTDOG_ROOT'/*)
      printf '%s/%s\n' "$HOTDOG_ROOT" "${path#\$HOTDOG_ROOT/}"
      ;;
    *)
      printf '%s\n' "$path"
      ;;
  esac
}

print_wrapper_paths() {
  local wrapper="$1"
  local prefix="${2:-}"
  local image=""
  local restore=""

  [ -r "$wrapper" ] || return 0
  image="$(awk -F'"' '/^image=/{ print $2; exit }' "$wrapper")"
  restore="$(awk -F'"' '/^restore=/{ print $2; exit }' "$wrapper")"
  [ -n "$image" ] && printf '%simage=%s\n' "$prefix" "$(expand_hotdog_path "$image")"
  [ -n "$restore" ] && printf '%srestore=%s\n' "$prefix" "$(expand_hotdog_path "$restore")"
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
  pattern_lines rescue-visible "$HOTDOG_ROOT/scripts/rescue-boot-b-when-visible.sh"
  pattern_lines rescue-usb-visible "$HOTDOG_ROOT/scripts/rescue-boot-b-when-usb-visible.sh"
  pattern_lines rescue-supervisor "$HOTDOG_ROOT/scripts/watch-rescue-visible-supervisor.sh"
  pattern_lines wait-simplefb-shell "$HOTDOG_ROOT/scripts/wait-pmos-then-test-next-lineage414-simplefb-shell.sh"
  pattern_lines passive-phone-state "$HOTDOG_ROOT/scripts/watch-phone-state.sh --timeout 21600 --poll 5"

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
  local rescue_dir
  local rescue_usb_dir
  local wait_simplefb_dir

  state_dir="$(latest_dir "$HOTDOG_LOG_ROOT" 'watch-phone-state-*')"
  fastboot_dir="$(latest_dir "$HOTDOG_LOG_ROOT" 'watch-fastboot-dump-*')"
  continue_dir="$(latest_dir "$HOTDOG_LOG_ROOT" 'continue-after-dump-to-pmos-*')"
  stall_dir="$(latest_dir "$HOTDOG_LOG_ROOT" 'watch-stall-summary-*')"
  scrcpy_dir="$(latest_dir "$HOTDOG_LOG_ROOT" 'watch-adb-scrcpy-*')"
  health_dir="$(latest_dir "$HOTDOG_LOG_ROOT" 'watch-autopilot-health-*')"
  edl_dir="$(latest_dir "$HOTDOG_DUMP_ROOT/stock-before-flash" '*-edl-critical-blocks')"
  rescue_dir="$(latest_dir "$HOTDOG_LOG_ROOT" 'rescue-boot-b-when-visible-*')"
  rescue_usb_dir="$(latest_symlink_target "$HOTDOG_LOG_ROOT/manual-rescue-watchers" 'usb-rescue-*-current.run')"
  if [ -z "$rescue_usb_dir" ]; then
    rescue_usb_dir="$(latest_dir "$HOTDOG_LOG_ROOT" 'rescue-boot-b-when-usb-visible-*')"
  fi
  wait_simplefb_dir="$(latest_dir "$HOTDOG_LOG_ROOT" 'wait-pmos-then-test-next-lineage414-simplefb-shell-*')"
  if [ -z "$wait_simplefb_dir" ]; then
    wait_simplefb_dir="$(latest_dir "$HOTDOG_LOG_ROOT" 'wait-pmos-then-test-lineage414-simplefb-shell-*')"
  fi

  printf '\n== latest dirs ==\n'
  printf 'state=%s\n' "${state_dir:-none}"
  printf 'fastboot=%s\n' "${fastboot_dir:-none}"
  printf 'continue=%s\n' "${continue_dir:-none}"
  printf 'stall=%s\n' "${stall_dir:-none}"
  printf 'scrcpy=%s\n' "${scrcpy_dir:-none}"
  printf 'health=%s\n' "${health_dir:-none}"
  printf 'edl=%s\n' "${edl_dir:-none}"
  printf 'rescue=%s\n' "${rescue_dir:-none}"
  printf 'rescue_usb=%s\n' "${rescue_usb_dir:-none}"
  printf 'wait_simplefb=%s\n' "${wait_simplefb_dir:-none}"

  printf '\n== next prepared test ==\n'
  local next_wrapper="$HOTDOG_ROOT/scripts/test-next-lineage414-simplefb-shell.sh"
  local splash_wrapper="$HOTDOG_ROOT/scripts/test-lineage414-splash-ttykmsg.sh"
  local fbcon_wrapper="$HOTDOG_ROOT/scripts/test-lineage414-fbcon-only.sh"
  local mainline_wrapper="$HOTDOG_ROOT/scripts/test-next-mainline617-rammarker.sh"
  local mainline_wait_wrapper="$HOTDOG_ROOT/scripts/wait-pmos-then-test-next-mainline617-rammarker.sh"
  printf 'wrapper=%s\n' "$next_wrapper"
  print_wrapper_paths "$next_wrapper"
  printf 'wait_wrapper=%s\n' "$HOTDOG_ROOT/scripts/wait-pmos-then-test-next-lineage414-simplefb-shell.sh"
  printf 'secondary_splash_wrapper=%s\n' "$splash_wrapper"
  print_wrapper_paths "$splash_wrapper" "secondary_splash_"
  printf 'secondary_fbcon_wrapper=%s\n' "$fbcon_wrapper"
  print_wrapper_paths "$fbcon_wrapper" "secondary_fbcon_"
  printf 'mainline_rammarker_wrapper=%s\n' "$mainline_wrapper"
  print_wrapper_paths "$mainline_wrapper" "mainline_rammarker_"
  printf 'mainline_rammarker_wait_wrapper=%s\n' "$mainline_wait_wrapper"

  [ -n "$state_dir" ] && print_tail phone-state "$state_dir/latest-summary.txt" 40
  [ -n "$rescue_dir" ] && print_tail rescue-visible "$rescue_dir/run.log" 25
  [ -n "$rescue_usb_dir" ] && print_tail rescue-usb-visible "$rescue_usb_dir/run.log" 25
  [ -n "$wait_simplefb_dir" ] && print_tail wait-simplefb-shell "$wait_simplefb_dir/run.log" 25
  [ -n "$fastboot_dir" ] && print_tail fastboot-dump "$fastboot_dir/watch.log" 25
  [ -n "$continue_dir" ] && print_tail continue-pmos "$continue_dir/run.log" 25
  [ -n "$stall_dir" ] && print_tail stall-summary "$stall_dir/run.log" 25
  [ -s "$HOTDOG_LOG_ROOT/current-stall-summary.txt" ] && print_head current-stall-summary "$HOTDOG_LOG_ROOT/current-stall-summary.txt" 90
  [ -n "$scrcpy_dir" ] && print_tail adb-scrcpy "$scrcpy_dir/run.log" 25
  [ -n "$health_dir" ] && print_tail autopilot-health "$health_dir/run.log" 25
  [ -n "$edl_dir" ] && print_tail edl-critical "$edl_dir/run.log" 25
}

main "$@"
