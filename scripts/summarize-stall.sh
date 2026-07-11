#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/env.sh"

OUT_FILE="${OUT_FILE:-$HOTDOG_LOG_ROOT/current-stall-summary.txt}"
SUMMARY_FILE_LABEL="${SUMMARY_FILE_LABEL:-}"

usage() {
  cat <<'USAGE'
Usage: summarize-stall.sh [options]

Summarize the current phone/autopilot stall without changing phone state.

Options:
  --out PATH   Write summary to PATH. Default: logs/current-stall-summary.txt.
  -h, --help   Show this help.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
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

latest_dir() {
  local base="$1"
  local pattern="$2"
  find "$base" -maxdepth 1 -type d -name "$pattern" 2>/dev/null | sort | tail -n 1
}

latest_snapshot_dir() {
  local state_dir="$1"
  [ -n "$state_dir" ] || return 0
  find "$state_dir/snapshots" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -n 1
}

latest_usb_verbose_file_any() {
  local state_dir="$1"
  [ -n "$state_dir" ] || return 0
  find "$state_dir/snapshots" -type f -name 'lsusb-*-v.txt' 2>/dev/null |
    sort |
    tail -n 1
}

latest_usb_verbose_file_stable() {
  local state_dir="$1"
  local cutoff=0
  local file=""
  local mtime=0

  [ -n "$state_dir" ] || return 0
  cutoff=$(($(date +%s) - 10))

  while IFS= read -r file; do
    [ -s "$file" ] || continue
    mtime="$(stat -c %Y "$file" 2>/dev/null || printf '0')"
    if [ "$mtime" -le "$cutoff" ]; then
      printf '%s\n' "$file"
    fi
  done < <(find "$state_dir/snapshots" -type f -name 'lsusb-*-v.txt' 2>/dev/null | sort)
}

pid_state() {
  local label="$1"
  local pid_file="$2"
  local pid=""

  if [ ! -s "$pid_file" ]; then
    printf '%s=missing\n' "$label"
    return 0
  fi

  pid="$(sed -n '1p' "$pid_file" 2>/dev/null || true)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    printf '%s=running pid=%s elapsed=%s\n' "$label" "$pid" "$(ps -o etime= -p "$pid" 2>/dev/null | awk '{$1=$1; print}')"
  else
    printf '%s=stale pid=%s\n' "$label" "${pid:-unknown}"
  fi
}

hash_or_missing() {
  local path="$1"
  if [ -s "$path" ]; then
    sha256sum "$path" | awk '{ print $1 }'
  else
    printf 'missing'
  fi
}

print_matches() {
  local label="$1"
  local file="$2"
  local pattern="$3"

  printf '\n## %s\n' "$label"
  if [ -s "$file" ]; then
    grep -Ein "$pattern" "$file" | tail -20 || printf 'no matches\n'
  else
    printf 'missing: %s\n' "$file"
  fi
}

summarize() {
  local state_dir
  local snapshot_dir
  local usb_snapshot_dir=""
  local fastboot_dir
  local continue_dir
  local scrcpy_dir
  local edl_dir
  local usb_verbose=""
  local udev_info=""
  local fastboot_log=""
  local continue_log=""
  local scrcpy_log=""
  local edl_log=""

  state_dir="$(latest_dir "$HOTDOG_LOG_ROOT" 'watch-phone-state-*')"
  snapshot_dir="$(latest_snapshot_dir "$state_dir")"
  usb_verbose="$(latest_usb_verbose_file_stable "$state_dir" | tail -n 1)"
  [ -n "$usb_verbose" ] || usb_verbose="$(latest_usb_verbose_file_any "$state_dir")"
  [ -n "$usb_verbose" ] && usb_snapshot_dir="$(dirname "$usb_verbose")"
  [ -n "$usb_snapshot_dir" ] || usb_snapshot_dir="$snapshot_dir"
  fastboot_dir="$(latest_dir "$HOTDOG_LOG_ROOT" 'watch-fastboot-dump-*')"
  continue_dir="$(latest_dir "$HOTDOG_LOG_ROOT" 'continue-after-dump-to-pmos-*')"
  scrcpy_dir="$(latest_dir "$HOTDOG_LOG_ROOT" 'watch-adb-scrcpy-*')"
  edl_dir="$(latest_dir "$HOTDOG_DUMP_ROOT/stock-before-flash" '*-edl-critical-blocks')"

  if [ -n "$usb_snapshot_dir" ] && [ -d "$usb_snapshot_dir" ]; then
    udev_info="$(find "$usb_snapshot_dir" -maxdepth 1 -type f -name 'udev-*.txt' 2>/dev/null | sort | tail -n 1 || true)"
  fi
  [ -n "$fastboot_dir" ] && fastboot_log="$fastboot_dir/watch.log"
  [ -n "$continue_dir" ] && continue_log="$continue_dir/run.log"
  [ -n "$scrcpy_dir" ] && scrcpy_log="$scrcpy_dir/run.log"
  [ -n "$edl_dir" ] && edl_log="$edl_dir/run.log"

  printf '# OnePlus 7T Pro autopilot stall summary\n\n'
  printf 'timestamp=%s\n' "$(date '+%F %T')"
  printf 'root=%s\n' "$HOTDOG_ROOT"
  printf 'summary_file=%s\n\n' "${SUMMARY_FILE_LABEL:-$OUT_FILE}"

  printf '## Live state\n'
  adb devices -l 2>&1 | sed 's/^/adb: /' || true
  hotdog_fastboot_devices 2>&1 | sed 's/^/fastboot: /' || true
  lsusb 2>/dev/null | grep -Ei '18d1|2a70|05c6' | sed 's/^/usb: /' || true
  if [ -d "$HOTDOG_LOG_ROOT/phone-operation.lock" ]; then
    printf 'phone_lock=present\n'
    sed 's/^/phone_lock: /' "$HOTDOG_LOG_ROOT/phone-operation.lock/pid" 2>/dev/null || true
  else
    printf 'phone_lock=absent\n'
  fi

  printf '\n## Watchers\n'
  pid_state fastboot_dump "$HOTDOG_LOG_ROOT/watch-fastboot-dump.pid"
  pid_state edl_critical "$HOTDOG_LOG_ROOT/watch-edl-dump-critical.pid"
  pid_state continue_pmos "$HOTDOG_LOG_ROOT/continue-after-dump-to-pmos.pid"
  pid_state phone_state "$HOTDOG_LOG_ROOT/watch-phone-state.pid"
  pid_state stall_summary "$HOTDOG_LOG_ROOT/watch-stall-summary.pid"
  pid_state adb_scrcpy "$HOTDOG_LOG_ROOT/watch-adb-scrcpy.pid"
  pid_state autopilot_health "$HOTDOG_LOG_ROOT/watch-autopilot-health.pid"

  printf '\n## Latest paths\n'
  printf 'state_dir=%s\n' "${state_dir:-none}"
  printf 'snapshot_dir=%s\n' "${snapshot_dir:-none}"
  printf 'usb_descriptor_snapshot_dir=%s\n' "${usb_snapshot_dir:-none}"
  printf 'fastboot_dir=%s\n' "${fastboot_dir:-none}"
  printf 'continue_dir=%s\n' "${continue_dir:-none}"
  printf 'scrcpy_dir=%s\n' "${scrcpy_dir:-none}"
  printf 'edl_dir=%s\n' "${edl_dir:-none}"

  printf '\n## USB descriptor\n'
  if [ -s "$usb_verbose" ]; then
    grep -E 'idVendor|idProduct|iProduct|iSerial|bInterfaceClass|bInterfaceSubClass|bInterfaceProtocol' "$usb_verbose" | sed 's/^/usbv: /'
  else
    printf 'missing verbose USB descriptor\n'
  fi
  if [ -s "$udev_info" ]; then
    grep -E 'ID_MODEL=|ID_MODEL_ID=|ID_VENDOR_ID=|ID_USB_INTERFACES=|ID_MODEL_FROM_DATABASE=' "$udev_info" | sed 's/^/udev: /'
  fi

  printf '\n## ADB key fingerprints\n'
  printf 'host_adbkey_pub=%s\n' "$HOME/.android/adbkey.pub"
  printf 'host_adbkey_pub_sha256=%s\n' "$(hash_or_missing "$HOME/.android/adbkey.pub")"
  printf 'patched_recovery_host_adbkey_pub=%s\n' "$HOTDOG_ROOT/images/lineage/hotdog-20260703/patch-magiskboot-strong/host-adbkey.pub"
  printf 'patched_recovery_host_adbkey_pub_sha256=%s\n' "$(hash_or_missing "$HOTDOG_ROOT/images/lineage/hotdog-20260703/patch-magiskboot-strong/host-adbkey.pub")"
  printf 'recovery_adb_unsecure_img=%s\n' "$HOTDOG_ROOT/images/lineage/hotdog-20260703/recovery-adb-unsecure.img"
  printf 'recovery_adb_unsecure_img_sha256=%s\n' "$(hash_or_missing "$HOTDOG_ROOT/images/lineage/hotdog-20260703/recovery-adb-unsecure.img")"

  print_matches 'Fastboot/ADB watcher signals' "$fastboot_log" 'unauthorized|sideload|Fastboot|authorized|ERROR|Timed out'
  print_matches 'Continuation signals' "$continue_log" 'Complete stock dump|not complete|handoff|EDL reset|Starting postmarketOS|SSH|ERROR|Timed out'
  print_matches 'scrcpy watcher signals' "$scrcpy_log" 'ADB state|Launching scrcpy|ERROR|Timed out'
  print_matches 'EDL watcher signals' "$edl_log" 'EDL|05c6:9008|Dumped|failed|ERROR|Timed out'

  printf '\n## Diagnosis\n'
  if adb devices -l 2>/dev/null | awk 'NF >= 2 && $2 == "unauthorized" { found=1 } END { exit found ? 0 : 1 }'; then
    printf 'blocked_reason=ADB_UNAUTHORIZED\n'
    printf 'blocked_explanation=The host sees the phone as an ADB interface, but adbd has not authorized this host. Host-side adb reboot/shell/sideload are unavailable in this state.\n'
  elif hotdog_fastboot_devices 2>/dev/null | awk 'NF >= 2 { found=1 } END { exit found ? 0 : 1 }'; then
    printf 'blocked_reason=FASTBOOT_AVAILABLE_AUTOPILOT_SHOULD_ACT\n'
  elif lsusb 2>/dev/null | grep -qi '05c6:9008'; then
    printf 'blocked_reason=EDL_AVAILABLE_AUTOPILOT_SHOULD_ACT\n'
  else
    printf 'blocked_reason=WAITING_FOR_USABLE_PHONE_MODE\n'
  fi
}

main() {
  mkdir -p "$(dirname "$OUT_FILE")"
  summarize | tee "$OUT_FILE"
}

main "$@"
