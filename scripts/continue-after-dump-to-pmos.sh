#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/env.sh"
source "$(dirname "$0")/phone-lock.sh"
source "$(dirname "$0")/stock-dump-lib.sh"

EDL_BIN="${EDL_BIN:-$HOTDOG_BIN_ROOT/edl}"
EDL_LOADER="${EDL_LOADER:-$HOTDOG_ROOT/src/qualcomm/edl/Loaders/oneplus/000a50e100514985_2acf3a85fde334e2_fhprg_op7t.bin}"
SIDELOAD_ZIP="${SIDELOAD_ZIP:-$HOTDOG_ROOT/tools/recovery-zips/build/hotdog-reboot-bootloader.zip}"
TIMEOUT_SEC="${TIMEOUT_SEC:-28800}"
POLL_SEC="${POLL_SEC:-5}"
FLASH_TIMEOUT_SEC="${FLASH_TIMEOUT_SEC:-900}"
SSH_TIMEOUT_SEC="${SSH_TIMEOUT_SEC:-1200}"
HANDOFF_TIMEOUT_SEC="${HANDOFF_TIMEOUT_SEC:-180}"
LOCK_DIR="$HOTDOG_LOG_ROOT/continue-after-dump-to-pmos.lock"
stamp="$(date +%F-%H%M%S)"
run_dir="$HOTDOG_LOG_ROOT/continue-after-dump-to-pmos-$stamp"
device_serial="${ANDROID_SERIAL:-}"
SELECTED_DUMP_DIR=""

usage() {
  cat <<'USAGE'
Usage: continue-after-dump-to-pmos.sh [options]

Wait for a complete stock dump, reboot to bootloader when possible, flash the
prepared postmarketOS rootfs, temporary-boot the prepared boot.img, and wait
for postmarketOS SSH over USB.

Options:
  --serial SERIAL          Restrict ADB/fastboot commands to SERIAL.
  --timeout SEC            Seconds to wait for a complete dump. Default: 28800.
  --poll SEC               Poll interval while waiting. Default: 5.
  --flash-timeout SEC      Seconds flash-rootfs waits for fastboot. Default: 900.
  --ssh-timeout SEC        Seconds to wait for postmarketOS SSH. Default: 1200.
  --handoff-timeout SEC    Seconds to try EDL/ADB/sideload handoff. Default: 180.
  -h, --help               Show this help.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --serial)
      [ "$#" -ge 2 ] || { echo "Missing value for --serial" >&2; exit 2; }
      device_serial="$2"
      export ANDROID_SERIAL="$device_serial"
      shift
      ;;
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
  phone_lock_release
  rm -rf "$LOCK_DIR"
}

on_err() {
  local rc=$?
  log "ERROR: command failed near line $1: $2 (exit $rc)"
  exit "$rc"
}

wait_for_stock_dump() {
  local deadline=$((SECONDS + TIMEOUT_SEC))
  local last_status=0
  local dump_dir=""
  local started=""
  local latest=""

  log "Waiting for complete stock dump, timeout ${TIMEOUT_SEC}s"
  while [ "$SECONDS" -lt "$deadline" ]; do
    dump_dir="$(stock_dump_latest_complete || true)"
    if [ -n "$dump_dir" ]; then
      log "Complete stock dump found: $dump_dir"
      SELECTED_DUMP_DIR="$dump_dir"
      printf '%s\n' "$dump_dir" > "$run_dir/selected-stock-dump.txt"
      return 0
    fi

    if [ $((SECONDS - last_status)) -ge 30 ]; then
      started="$(stock_dump_latest_started || true)"
      if [ -n "$started" ]; then
        log "Latest started stock dump is not complete yet: $started"
      else
        latest="$(stock_dump_latest_any || true)"
        if [ -n "$latest" ]; then
          log "No stock dump data yet; latest watcher directory: $latest"
        else
          log "No stock dump candidate yet"
        fi
      fi
      last_status=$SECONDS
    fi
    sleep "$POLL_SEC"
  done

  die "Timed out waiting for complete stock dump" 2
}

fastboot_target_present() {
  local count

  fastboot devices -l > "$run_dir/fastboot-devices-last.txt" 2>&1 || true
  if [ -n "$device_serial" ]; then
    awk -v serial="$device_serial" 'NF >= 2 && $1 == serial { found=1 } END { exit found ? 0 : 1 }' "$run_dir/fastboot-devices-last.txt"
    return $?
  fi

  count="$(awk 'NF >= 2 { count++ } END { print count + 0 }' "$run_dir/fastboot-devices-last.txt")"
  case "$count" in
    0)
      return 1
      ;;
    1)
      device_serial="$(awk 'NF >= 2 { print $1; exit }' "$run_dir/fastboot-devices-last.txt")"
      export ANDROID_SERIAL="$device_serial"
      return 0
      ;;
    *)
      sed 's/^/[fastboot] /' "$run_dir/fastboot-devices-last.txt"
      die "Multiple fastboot devices found; rerun with --serial SERIAL" 2
      ;;
  esac
}

adb_target_state() {
  local count
  local serial=""
  local state=""

  adb devices -l > "$run_dir/adb-devices-last.txt" 2>&1 || true
  if [ -n "$device_serial" ]; then
    state="$(awk -v serial="$device_serial" 'NF >= 2 && $1 == serial { print $2; exit }' "$run_dir/adb-devices-last.txt")"
    [ -n "$state" ] && printf '%s %s\n' "$device_serial" "$state"
    return 0
  fi

  count="$(awk 'NF >= 2 && $1 != "List" && $1 !~ /^\*/ { count++ } END { print count + 0 }' "$run_dir/adb-devices-last.txt")"
  if [ "$count" -eq 1 ]; then
    serial="$(awk 'NF >= 2 && $1 != "List" && $1 !~ /^\*/ { print $1; exit }' "$run_dir/adb-devices-last.txt")"
    state="$(awk 'NF >= 2 && $1 != "List" && $1 !~ /^\*/ { print $2; exit }' "$run_dir/adb-devices-last.txt")"
    printf '%s %s\n' "$serial" "$state"
  elif [ "$count" -gt 1 ]; then
    sed 's/^/[adb] /' "$run_dir/adb-devices-last.txt"
    die "Multiple adb devices found; rerun with --serial SERIAL" 2
  fi
}

reboot_bootloader_if_possible() {
  local adb_info=""
  local serial=""
  local state=""

  if fastboot_target_present; then
    log "Fastboot is already available for ${device_serial:-auto}"
    return 0
  fi

  adb_info="$(adb_target_state || true)"
  if [ -z "$adb_info" ]; then
    log "No ADB target available; flash step will keep waiting for fastboot"
    return 0
  fi

  serial="${adb_info%% *}"
  state="${adb_info#* }"
  case "$state" in
    device|recovery)
      log "Authorized ADB state detected ($state, serial $serial); rebooting to bootloader"
      adb -s "$serial" reboot bootloader
      device_serial="$serial"
      export ANDROID_SERIAL="$device_serial"
      sleep 5
      ;;
    sideload)
      log "ADB sideload state detected; leaving it untouched and waiting for fastboot in flash step"
      ;;
    unauthorized)
      log "ADB is unauthorized; cannot reboot bootloader from host, flash step will wait for fastboot"
      ;;
    *)
      log "ADB state is $state; flash step will wait for fastboot"
      ;;
  esac
}

edl_connected() {
  lsusb > "$run_dir/lsusb-last.txt" 2>&1 || true
  grep -qi '05c6:9008' "$run_dir/lsusb-last.txt"
}

live_transport_present() {
  local adb_info=""

  if fastboot_target_present; then
    return 0
  fi

  adb_info="$(adb_target_state || true)"
  if [ -n "$adb_info" ]; then
    return 0
  fi

  edl_connected
}

wait_for_live_transport() {
  local deadline=$((SECONDS + TIMEOUT_SEC))
  local last_status=0

  log "Waiting for a live phone transport before taking the phone lock"
  while [ "$SECONDS" -lt "$deadline" ]; do
    if live_transport_present; then
      log "Live phone transport detected"
      return 0
    fi

    if [ $((SECONDS - last_status)) -ge 30 ]; then
      log "No live phone transport yet; leaving fastboot/EDL watchers unblocked"
      last_status=$SECONDS
    fi
    sleep "$POLL_SEC"
  done

  die "Timed out waiting for live phone transport" 2
}

run_edl_reset_if_needed() {
  local dump_dir="$1"
  local log_file="$run_dir/edl-reset.txt"

  case "$dump_dir" in
    *-edl-critical-blocks)
      ;;
    *)
      return 0
      ;;
  esac

  if ! edl_connected; then
    log "Selected dump came from EDL, but EDL is no longer visible"
    return 0
  fi

  [ -x "$EDL_BIN" ] || die "Missing executable EDL_BIN: $EDL_BIN" 127
  [ -r "$EDL_LOADER" ] || die "Missing readable EDL_LOADER: $EDL_LOADER" 2

  log "Phone is still in EDL after a valid dump; sending firehose reset"
  printf '$' > "$log_file.cmd"
  printf ' %q' "$EDL_BIN" --vid=0x05c6 --pid=0x9008 --loader="$EDL_LOADER" reset --resetmode=reset >> "$log_file.cmd"
  printf '\n' >> "$log_file.cmd"
  set +e
  "$EDL_BIN" --vid=0x05c6 --pid=0x9008 --loader="$EDL_LOADER" reset --resetmode=reset 2>&1 | tee "$log_file"
  local rc=${PIPESTATUS[0]}
  set -e
  if [ "$rc" -ne 0 ]; then
    log "EDL reset command returned $rc; continuing to wait for a bootloader opportunity"
  fi
  sleep 8
}

adb_sideload_reboot_zip() {
  local serial="$1"

  [ -r "$SIDELOAD_ZIP" ] || {
    log "ADB sideload state detected, but reboot ZIP is not readable: $SIDELOAD_ZIP"
    return 1
  }

  log "ADB sideload state detected; sideloading reboot-bootloader ZIP"
  if [ -n "$serial" ]; then
    adb -s "$serial" sideload "$SIDELOAD_ZIP" 2>&1 | tee "$run_dir/adb-sideload-reboot-bootloader.txt"
  else
    adb sideload "$SIDELOAD_ZIP" 2>&1 | tee "$run_dir/adb-sideload-reboot-bootloader.txt"
  fi
}

wait_for_bootloader_handoff() {
  local deadline=$((SECONDS + HANDOFF_TIMEOUT_SEC))
  local last_status=0
  local adb_info=""
  local serial=""
  local state=""

  log "Trying host-controlled handoff to fastboot, timeout ${HANDOFF_TIMEOUT_SEC}s"
  while [ "$SECONDS" -lt "$deadline" ]; do
    if fastboot_target_present; then
      log "Fastboot handoff is ready for ${device_serial:-auto}"
      return 0
    fi

    adb_info="$(adb_target_state || true)"
    if [ -n "$adb_info" ]; then
      serial="${adb_info%% *}"
      state="${adb_info#* }"
      case "$state" in
        device|recovery)
          log "Authorized ADB state detected ($state, serial $serial); rebooting to bootloader"
          adb -s "$serial" reboot bootloader
          device_serial="$serial"
          export ANDROID_SERIAL="$device_serial"
          sleep 5
          continue
          ;;
        sideload)
          adb_sideload_reboot_zip "$serial" || true
          sleep 8
          continue
          ;;
      esac
    fi

    if [ $((SECONDS - last_status)) -ge 15 ]; then
      if [ -n "$adb_info" ]; then
        log "No handoff yet; current ADB state: ${adb_info#* }"
      else
        log "No handoff yet; no fastboot or ADB target"
      fi
      last_status=$SECONDS
    fi
    sleep "$POLL_SEC"
  done

  log "No host-controlled handoff reached yet; deferring flash until transport changes"
  return 1
}

stop_pid_file_if_watcher() {
  local pid_file="$1"
  local label="$2"
  local pid=""
  local args=""
  local deadline=0

  [ -s "$pid_file" ] || return 0
  pid="$(sed -n '1p' "$pid_file" 2>/dev/null || true)"
  [ -n "$pid" ] || return 0
  [ "$pid" != "$$" ] || return 0

  if ! kill -0 "$pid" 2>/dev/null; then
    log "$label PID file is stale: $pid"
    rm -f "$pid_file"
    return 0
  fi

  args="$(ps -o args= -p "$pid" 2>/dev/null || true)"
  case "$args" in
    *watch-fastboot-dump.sh*|*watch-edl-dump-critical.sh*)
      log "Stopping conflicting $label watcher PID $pid"
      kill "$pid" 2>/dev/null || true
      deadline=$((SECONDS + 10))
      while kill -0 "$pid" 2>/dev/null && [ "$SECONDS" -lt "$deadline" ]; do
        sleep 1
      done
      if kill -0 "$pid" 2>/dev/null; then
        log "$label watcher PID $pid did not exit after SIGTERM; leaving it because phone lock is held"
      else
        rm -f "$pid_file"
      fi
      ;;
    "")
      log "$label PID $pid vanished"
      rm -f "$pid_file"
      ;;
    *)
      log "Not stopping $label PID $pid; command is not a watcher: $args"
      ;;
  esac
}

stop_conflicting_watchers() {
  stop_pid_file_if_watcher "$HOTDOG_LOG_ROOT/watch-fastboot-dump.pid" "fastboot/dump"
  stop_pid_file_if_watcher "$HOTDOG_LOG_ROOT/watch-edl-dump-critical.pid" "EDL"
}

main() {
  validate_seconds TIMEOUT_SEC "$TIMEOUT_SEC"
  validate_seconds POLL_SEC "$POLL_SEC"
  validate_seconds FLASH_TIMEOUT_SEC "$FLASH_TIMEOUT_SEC"
  validate_seconds SSH_TIMEOUT_SEC "$SSH_TIMEOUT_SEC"
  validate_seconds HANDOFF_TIMEOUT_SEC "$HANDOFF_TIMEOUT_SEC"

  command -v adb >/dev/null 2>&1 || die "Missing adb" 127
  command -v fastboot >/dev/null 2>&1 || die "Missing fastboot" 127
  command -v awk >/dev/null 2>&1 || die "Missing awk" 127
  command -v find >/dev/null 2>&1 || die "Missing find" 127
  command -v lsusb >/dev/null 2>&1 || die "Missing lsusb" 127

  mkdir -p "$HOTDOG_LOG_ROOT"
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    if [ -f "$LOCK_DIR/pid" ] && ! kill -0 "$(cat "$LOCK_DIR/pid")" 2>/dev/null; then
      rm -rf "$LOCK_DIR"
      mkdir "$LOCK_DIR"
    else
      echo "Another continue-after-dump-to-pmos instance appears to be running: $LOCK_DIR" >&2
      exit 2
    fi
  fi
  trap cleanup EXIT
  trap 'on_err "$LINENO" "$BASH_COMMAND"' ERR
  printf '%s\n' "$$" > "$LOCK_DIR/pid"

  mkdir -p "$run_dir"
  exec > >(tee "$run_dir/run.log") 2>&1

  log "Run directory: $run_dir"
  log "Watcher PID: $$"
  log "Target serial: ${device_serial:-auto-detect}"
  log "Dump wait timeout: ${TIMEOUT_SEC}s"
  log "Flash fastboot timeout: ${FLASH_TIMEOUT_SEC}s"
  log "SSH timeout: ${SSH_TIMEOUT_SEC}s"
  log "Handoff timeout: ${HANDOFF_TIMEOUT_SEC}s"

  wait_for_stock_dump
  wait_for_live_transport
  phone_lock_acquire "continue-after-dump-to-pmos flash and first boot" 120 || exit 2
  stop_conflicting_watchers
  run_edl_reset_if_needed "$SELECTED_DUMP_DIR"
  if ! wait_for_bootloader_handoff; then
    log "Exiting without flash because no fastboot handoff is ready"
    exit 0
  fi

  flash_args=(--timeout "$FLASH_TIMEOUT_SEC")
  if [ -n "$device_serial" ]; then
    flash_args+=(--serial "$device_serial")
  fi

  log "Starting postmarketOS flash and temporary boot"
  "$HOTDOG_ROOT/scripts/flash-rootfs-and-boot-pmos.sh" "${flash_args[@]}"

  log "Waiting for postmarketOS USB SSH"
  "$HOTDOG_ROOT/scripts/wait-pmos-usb-ssh.sh" --timeout "$SSH_TIMEOUT_SEC"

  log "Done"
}

main "$@"
