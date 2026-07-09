#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/env.sh"
source "$(dirname "$0")/phone-lock.sh"

SERIAL="${ANDROID_SERIAL:-b6bd2252}"
IMAGE=""
RESTORE_IMAGE="${RESTORE_IMAGE:-$HOTDOG_STABLE_PMOS_BOOT_B}"
EXPECTED_FASTBOOT_PRODUCTS="${EXPECTED_FASTBOOT_PRODUCTS:-msmnile hotdog}"
REQUIRE_FASTBOOT_UNLOCKED=1
BOOT_WAIT_SEC="${BOOT_WAIT_SEC:-240}"
POLL_SEC="${POLL_SEC:-2}"
RETURN_RECOVERY=1
RESTORE_AFTER_FASTBOOT="${RESTORE_AFTER_FASTBOOT:-recovery}"
SET_ACTIVE_B=1
START_FROM_PMOS_SSH=0
FASTBOOT_CMD_TIMEOUT_SEC="${FASTBOOT_CMD_TIMEOUT_SEC:-15}"
PMOS_USER="${PMOS_USER:-user}"
PMOS_PASSWORD="${PMOS_PASSWORD:-147147}"
PMOS_HOST="${PMOS_HOST:-172.16.42.1}"
PMOS_TELNET_PORTS="${PMOS_TELNET_PORTS:-23 2323}"
PMOS_BOOT_ID_BEFORE=""
START_RESCUE_WATCHER=0
RESCUE_WATCHER_TIMEOUT_SEC="${RESCUE_WATCHER_TIMEOUT_SEC:-21600}"
RESCUE_WATCHER_POLL_SEC="${RESCUE_WATCHER_POLL_SEC:-5}"
RESCUE_WATCHER_PID=""
KEEP_RESCUE_WATCHER=0

usage() {
  cat <<'USAGE'
Usage: test-boot-b-image.sh --image boot.img [options]

Flash one boot image to boot_b, reboot, classify the result, and run the
configured restore fallback if the bootloader rejects the image.
This script does not flash super, dtbo, vbmeta, recovery, or any other partition.

Options:
  --image FILE           Boot image to flash to boot_b.
  --restore-boot-b FILE  Restore boot_b to FILE if fastboot returns.
  --serial SERIAL        Restrict adb/fastboot commands to SERIAL.
  --expected-product STR Space-separated fastboot products. Default: "msmnile hotdog".
  --allow-locked         Do not fail early if fastboot reports locked.
  --no-set-active-b      Do not run fastboot set_active b before reboot.
  --no-return-recovery   Leave the device in fastboot if the image is rejected.
  --restore-after MODE   recovery, system, bootloader, or none after restoring
                         boot_b from fastboot/ADB fallback. Default: recovery.
  --from-pmos-ssh        Start from the currently booted pmOS SSH userland:
                         flash boot_b via SSH, reboot, then classify result.
  --boot-wait SEC        Seconds to watch for fastboot/ADB/pmOS SSH. Default: 240.
  --poll SEC             Poll interval. Default: 2.
  --fastboot-timeout SEC Seconds to allow individual fastboot getvar/reboot
                          commands before treating them as failed. Default: 15.
  --start-rescue-watcher  Start a companion rescue watcher after rebooting into
                         the test image. If the test times out without any USB
                         recovery path, the watcher is left running.
  --rescue-watch-timeout SEC
                         Companion rescue watcher timeout. Default: 21600.
  --rescue-watch-poll SEC
                         Companion rescue watcher poll interval. Default: 5.
  -h, --help             Show this help.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --image)
      [ "$#" -ge 2 ] || { echo "Missing value for --image" >&2; exit 2; }
      IMAGE="$2"
      shift
      ;;
    --serial)
      [ "$#" -ge 2 ] || { echo "Missing value for --serial" >&2; exit 2; }
      SERIAL="$2"
      export ANDROID_SERIAL="$SERIAL"
      shift
      ;;
    --restore-boot-b)
      [ "$#" -ge 2 ] || { echo "Missing value for --restore-boot-b" >&2; exit 2; }
      RESTORE_IMAGE="$2"
      shift
      ;;
    --expected-product)
      [ "$#" -ge 2 ] || { echo "Missing value for --expected-product" >&2; exit 2; }
      EXPECTED_FASTBOOT_PRODUCTS="$2"
      shift
      ;;
    --allow-locked)
      REQUIRE_FASTBOOT_UNLOCKED=0
      ;;
    --no-set-active-b)
      SET_ACTIVE_B=0
      ;;
    --no-return-recovery)
      RETURN_RECOVERY=0
      RESTORE_AFTER_FASTBOOT=none
      ;;
    --restore-after)
      [ "$#" -ge 2 ] || { echo "Missing value for --restore-after" >&2; exit 2; }
      RESTORE_AFTER_FASTBOOT="$2"
      shift
      ;;
    --from-pmos-ssh)
      START_FROM_PMOS_SSH=1
      ;;
    --boot-wait)
      [ "$#" -ge 2 ] || { echo "Missing value for --boot-wait" >&2; exit 2; }
      BOOT_WAIT_SEC="$2"
      shift
      ;;
    --poll)
      [ "$#" -ge 2 ] || { echo "Missing value for --poll" >&2; exit 2; }
      POLL_SEC="$2"
      shift
      ;;
    --fastboot-timeout)
      [ "$#" -ge 2 ] || { echo "Missing value for --fastboot-timeout" >&2; exit 2; }
      FASTBOOT_CMD_TIMEOUT_SEC="$2"
      shift
      ;;
    --start-rescue-watcher)
      START_RESCUE_WATCHER=1
      ;;
    --rescue-watch-timeout)
      [ "$#" -ge 2 ] || { echo "Missing value for --rescue-watch-timeout" >&2; exit 2; }
      RESCUE_WATCHER_TIMEOUT_SEC="$2"
      shift
      ;;
    --rescue-watch-poll)
      [ "$#" -ge 2 ] || { echo "Missing value for --rescue-watch-poll" >&2; exit 2; }
      RESCUE_WATCHER_POLL_SEC="$2"
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

stamp="$(date +%F-%H%M%S)"
run_dir="$HOTDOG_LOG_ROOT/test-boot-b-image-$stamp"
mkdir -p "$run_dir"
exec > >(tee "$run_dir/run.log") 2>&1

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

die() {
  log "ERROR: $1"
  exit "${2:-1}"
}

cleanup() {
  if [ "${KEEP_RESCUE_WATCHER:-0}" -eq 0 ]; then
    stop_rescue_watcher || true
  elif [ -n "${RESCUE_WATCHER_PID:-}" ]; then
    log "Leaving companion rescue watcher running: PID $RESCUE_WATCHER_PID"
  fi
  phone_lock_release || true
}
trap cleanup EXIT

validate_seconds() {
  local name="$1"
  local value="$2"
  if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -lt 1 ]; then
    die "$name must be a positive integer, got: $value" 2
  fi
}

adb_do() {
  if [ -n "$SERIAL" ]; then
    adb -s "$SERIAL" "$@"
  else
    adb "$@"
  fi
}

fastboot_do() {
  if [ -n "$SERIAL" ]; then
    fastboot -s "$SERIAL" "$@"
  else
    fastboot "$@"
  fi
}

start_rescue_watcher() {
  local wrapper_log="$run_dir/companion-rescue-watcher.log"
  local wrapper_err="$run_dir/companion-rescue-watcher.err"
  local pidfile="$run_dir/companion-rescue-watcher.pid"

  [ "$START_RESCUE_WATCHER" -eq 1 ] || return 0
  [ -z "$RESCUE_WATCHER_PID" ] || return 0
  [ -n "$SERIAL" ] || die "--start-rescue-watcher requires --serial or an auto-detected serial" 2
  [ -n "$RESTORE_IMAGE" ] || die "--start-rescue-watcher requires --restore-boot-b FILE" 2
  [ -s "$RESTORE_IMAGE" ] || die "Rescue watcher restore image does not exist or is empty: $RESTORE_IMAGE" 2

  log "Starting companion rescue watcher for $SERIAL"
  if command -v start-stop-daemon >/dev/null 2>&1; then
    start-stop-daemon --start --background --make-pidfile --pidfile "$pidfile" \
      --chdir "$HOTDOG_ROOT" \
      --env HOTDOG_RESCUE_LOG_TEE=0 \
      --stdout "$wrapper_log" --stderr "$wrapper_err" \
      --exec "$HOTDOG_ROOT/scripts/rescue-boot-b-when-visible.sh" -- \
      --serial "$SERIAL" \
      --restore-boot-b "$RESTORE_IMAGE" \
      --after-restore "$RESTORE_AFTER_FASTBOOT" \
      --timeout "$RESCUE_WATCHER_TIMEOUT_SEC" \
      --poll "$RESCUE_WATCHER_POLL_SEC"
    RESCUE_WATCHER_PID="$(sed -n '1p' "$pidfile")"
  else
    setsid env HOTDOG_RESCUE_LOG_TEE=0 "$HOTDOG_ROOT/scripts/rescue-boot-b-when-visible.sh" \
      --serial "$SERIAL" \
      --restore-boot-b "$RESTORE_IMAGE" \
      --after-restore "$RESTORE_AFTER_FASTBOOT" \
      --timeout "$RESCUE_WATCHER_TIMEOUT_SEC" \
      --poll "$RESCUE_WATCHER_POLL_SEC" \
      > "$wrapper_log" 2> "$wrapper_err" < /dev/null &
    RESCUE_WATCHER_PID="$!"
    printf '%s\n' "$RESCUE_WATCHER_PID" > "$pidfile"
  fi
  log "Companion rescue watcher PID: $RESCUE_WATCHER_PID"
}

stop_rescue_watcher() {
  [ -n "${RESCUE_WATCHER_PID:-}" ] || return 0
  if kill -0 "$RESCUE_WATCHER_PID" 2>/dev/null; then
    log "Stopping companion rescue watcher: PID $RESCUE_WATCHER_PID"
    kill "$RESCUE_WATCHER_PID" 2>/dev/null || true
    wait "$RESCUE_WATCHER_PID" 2>/dev/null || true
  fi
  RESCUE_WATCHER_PID=""
}

normalize_value() {
  local value="$1"
  value="${value,,}"
  value="${value//[[:space:]]/}"
  value="${value#_}"
  printf '%s\n' "$value"
}

get_fastboot_var() {
  local var="$1"
  local safe_name="${var//[:\/]/_}"
  local file="$run_dir/getvar-${safe_name}.txt"

  if [ -n "$SERIAL" ]; then
    timeout "$FASTBOOT_CMD_TIMEOUT_SEC" fastboot -s "$SERIAL" getvar "$var" > "$file" 2>&1 || true
  else
    timeout "$FASTBOOT_CMD_TIMEOUT_SEC" fastboot getvar "$var" > "$file" 2>&1 || true
  fi
  awk -v var="$var" '
    index($0, var ":") {
      sub(".*" var ":[[:space:]]*", "", $0)
      gsub(/\r/, "", $0)
      print $0
      exit
    }
  ' "$file"
}

adb_state() {
  adb devices > "$run_dir/adb-devices-last.txt" 2>&1 || true
  if [ -n "$SERIAL" ]; then
    awk -v serial="$SERIAL" '$1 == serial { print $2; found=1 } END { if (!found) print "" }' "$run_dir/adb-devices-last.txt"
  else
    awk 'NF >= 2 && $2 != "offline" { print $2; exit }' "$run_dir/adb-devices-last.txt"
  fi
}

fastboot_present() {
  fastboot devices -l > "$run_dir/fastboot-devices-last.txt" 2>&1 || true
  if [ -n "$SERIAL" ]; then
    awk -v serial="$SERIAL" 'NF >= 1 && $1 == serial { found=1 } END { exit found ? 0 : 1 }' "$run_dir/fastboot-devices-last.txt"
  else
    awk 'NF >= 1 { found=1 } END { exit found ? 0 : 1 }' "$run_dir/fastboot-devices-last.txt"
  fi
}

qualcomm_900e_present() {
  lsusb > "$run_dir/lsusb-last.txt" 2>&1 || true
  grep -qiE '05c6:900e' "$run_dir/lsusb-last.txt"
}

wait_for_fastboot() {
  local timeout="$1"
  local deadline=$((SECONDS + timeout))
  local count=""

  log "Waiting for fastboot, timeout ${timeout}s"
  while [ "$SECONDS" -lt "$deadline" ]; do
    if fastboot_present; then
      if [ -z "$SERIAL" ]; then
        count="$(awk 'NF >= 1 { count++ } END { print count + 0 }' "$run_dir/fastboot-devices-last.txt")"
        [ "$count" = "1" ] || die "Multiple fastboot devices found; rerun with --serial SERIAL" 2
        SERIAL="$(awk 'NF >= 1 { print $1; exit }' "$run_dir/fastboot-devices-last.txt")"
        export ANDROID_SERIAL="$SERIAL"
      fi
      log "Fastboot target detected: $SERIAL"
      return 0
    fi
    sleep "$POLL_SEC"
  done

  die "Timed out waiting for fastboot. See $run_dir/fastboot-devices-last.txt" 3
}

wait_for_recovery_adb() {
  local timeout="$1"
  local deadline=$((SECONDS + timeout))
  local state=""

  log "Waiting for recovery ADB, timeout ${timeout}s"
  while [ "$SECONDS" -lt "$deadline" ]; do
    state="$(adb_state)"
    if [ "$state" = "recovery" ]; then
      log "Recovery ADB visible"
      adb devices -l > "$run_dir/adb-recovery-final.txt" 2>&1 || true
      return 0
    fi
    sleep "$POLL_SEC"
  done
  return 1
}

validate_fastboot_identity() {
  local product=""
  local serialno=""
  local unlocked=""
  local expected_product=""
  local product_ok=1

  serialno="$(normalize_value "$(get_fastboot_var serialno)")"
  product="$(normalize_value "$(get_fastboot_var product)")"
  unlocked="$(normalize_value "$(get_fastboot_var unlocked)")"

  [ -n "$SERIAL" ] || die "Internal error: SERIAL is empty after wait_for_fastboot" 2

  case "$serialno" in
    "$SERIAL"|"") ;;
    *) die "Fastboot serial mismatch: selected $SERIAL but getvar serialno reports $serialno" 2 ;;
  esac

  if [ -n "$EXPECTED_FASTBOOT_PRODUCTS" ]; then
    for expected_product in $EXPECTED_FASTBOOT_PRODUCTS; do
      expected_product="$(normalize_value "$expected_product")"
      [ -n "$expected_product" ] || continue
      if [ "$product" = "$expected_product" ]; then
        product_ok=0
        break
      fi
    done
    [ "$product_ok" -eq 0 ] || die "Fastboot product mismatch: expected one of [$EXPECTED_FASTBOOT_PRODUCTS], got ${product:-missing}" 2
  fi

  case "$unlocked" in
    yes|true|1|unlocked)
      log "Fastboot identity OK: serial=$SERIAL product=$product unlocked=$unlocked"
      ;;
    *)
      [ "$REQUIRE_FASTBOOT_UNLOCKED" -eq 0 ] || die "Fastboot unlocked state is not yes/true/1 (got ${unlocked:-missing})" 2
      log "Continuing despite unlocked state '${unlocked:-missing}' because --allow-locked was requested"
      ;;
  esac
}

ensure_bootloader_fastboot() {
  local is_userspace=""

  is_userspace="$(normalize_value "$(get_fastboot_var is-userspace)")"
  case "$is_userspace" in
    yes|true|1)
      log "fastbootd detected; rebooting to bootloader"
      fastboot_do reboot bootloader > "$run_dir/fastboot-reboot-bootloader.txt" 2>&1 || die "Failed to reboot bootloader from fastbootd" 3
      sleep 5
      wait_for_fastboot 60
      ;;
    *)
      log "Bootloader fastboot confirmed"
      ;;
  esac
}

pmos_ssh_probe() {
  ping -c 1 -W 1 "$PMOS_HOST" > "$run_dir/ping-last-$PMOS_HOST.txt" 2>&1 || return 1
  sshpass -p "$PMOS_PASSWORD" ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile="$run_dir/known_hosts" \
    -o ConnectTimeout=5 \
    -o PreferredAuthentications=password \
    -o PubkeyAuthentication=no \
    "$PMOS_USER@$PMOS_HOST" 'printf "PMOS_SSH_OK\n"; uname -a' \
    > "$run_dir/ssh-probe.txt" 2>&1
}

pmos_read_boot_id() {
  sshpass -p "$PMOS_PASSWORD" ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile="$run_dir/known_hosts" \
    -o ConnectTimeout=5 \
    -o PreferredAuthentications=password \
    -o PubkeyAuthentication=no \
    "$PMOS_USER@$PMOS_HOST" 'cat /proc/sys/kernel/random/boot_id 2>/dev/null || true' \
    2>/dev/null | tr -d '\r' | awk 'NF { print; exit }'
}

pmos_ping_probe() {
  ping -c 1 -W 1 "$PMOS_HOST" > "$run_dir/ping-last-$PMOS_HOST.txt" 2>&1
}

collect_pmos_telnet_logs() {
  local out="$run_dir/pmos-telnet"
  local port=""
  local transcript=""

  mkdir -p "$out"
  command -v socat >/dev/null 2>&1 || return 1

  for port in $PMOS_TELNET_PORTS; do
    transcript="$out/session-port-${port}.txt"
    local socat_target="TCP:$PMOS_HOST:$port,connect-timeout=3"
    if [ "$port" = "23" ]; then
      socat_target="$socat_target,crnl"
    fi
    {
      sleep 1
      printf ': > /tmp/hotdog_rescue_watchdog.ok 2>/dev/null || true\n'
      printf 'echo HOTDOG_TELNET_CONNECTED port=%s\n' "$port"
      printf 'cat /README 2>&1 || true\n'
      printf 'cat /README.hotdog-debug 2>&1 || true\n'
      printf 'echo ---CMDLINE---\n'
      printf 'cat /proc/cmdline 2>&1\n'
      printf 'echo ---UPTIME---\n'
      printf 'cat /proc/uptime 2>&1\n'
      printf 'echo ---PMOS_INIT_LOG---\n'
      printf 'cat /pmOS_init.log 2>&1 || true\n'
      printf 'echo ---HOTDOG_TELNETD_LOG---\n'
      printf 'cat /tmp/hotdog_telnetd.log 2>&1 || true\n'
      printf 'echo ---HOTDOG_TCPSVD_LOG---\n'
      printf 'cat /tmp/hotdog_tcpsvd.log 2>&1 || true\n'
      printf 'echo ---BLKID---\n'
      printf 'blkid 2>&1 || true\n'
      printf 'echo ---DEV_DISK---\n'
      printf 'ls -l /dev/disk/by-uuid /dev/disk/by-partlabel /dev/disk/by-name /dev/mapper 2>&1 || true\n'
      printf 'echo ---MOUNTS---\n'
      printf 'mount 2>&1\n'
      printf 'echo ---IP---\n'
      printf 'ip addr 2>&1 || ifconfig -a 2>&1 || true\n'
      printf 'echo ---PS---\n'
      printf 'ps ww 2>&1 || ps 2>&1 || true\n'
      printf 'echo ---DMESG_TAIL---\n'
      printf 'dmesg | tail -n 240 2>&1 || true\n'
      printf 'echo HOTDOG_TELNET_DONE\n'
      printf 'exit\n'
      sleep 1
    } | timeout 60 socat - "$socat_target" > "$transcript" 2>&1 || true

    if grep -q 'HOTDOG_TELNET_CONNECTED' "$transcript"; then
      printf '%s\n' "$port" > "$out/connected-port.txt"
      return 0
    fi
  done

  return 1
}

collect_pmos_logs() {
  log "pmOS SSH is reachable; delegating full first-boot collection"
  "$HOTDOG_ROOT/scripts/wait-pmos-usb-ssh.sh" \
    --host "$PMOS_HOST" \
    --user "$PMOS_USER" \
    --password "$PMOS_PASSWORD" \
    --timeout 60 \
    --poll 3 \
    > "$run_dir/wait-pmos-usb-ssh-wrapper.log" 2>&1 || true
}

return_after_restore_from_fastboot() {
  [ "$RETURN_RECOVERY" -eq 1 ] || RESTORE_AFTER_FASTBOOT=none

  case "$RESTORE_AFTER_FASTBOOT" in
    recovery)
      log "Returning to recovery from fastboot"
      fastboot_do reboot recovery > "$run_dir/fastboot-reboot-recovery.txt" 2>&1 || true
      if wait_for_recovery_adb 120; then
        collect_recovery_crash_artifacts "after-fastboot-return"
      else
        log "Recovery ADB did not appear after recovery reboot"
      fi
      ;;
    system)
      log "Rebooting system after boot_b restore"
      fastboot_do reboot > "$run_dir/fastboot-reboot-system-after-restore.txt" 2>&1 || true
      ;;
    bootloader)
      log "Rebooting bootloader after boot_b restore"
      fastboot_do reboot bootloader > "$run_dir/fastboot-reboot-bootloader-after-restore.txt" 2>&1 || true
      ;;
    none)
      log "Leaving target in fastboot after boot_b restore"
      ;;
    *)
      die "Invalid restore-after mode: $RESTORE_AFTER_FASTBOOT" 2
      ;;
  esac
}

restore_boot_b_if_configured() {
  [ -n "$RESTORE_IMAGE" ] || return 0
  [ -s "$RESTORE_IMAGE" ] || die "Restore image does not exist or is empty: $RESTORE_IMAGE" 2

  log "Restoring boot_b from $RESTORE_IMAGE"
  sha256sum "$RESTORE_IMAGE" | tee "$run_dir/restore-image-sha256.txt"
  fastboot_do flash boot_b "$RESTORE_IMAGE" 2>&1 | tee "$run_dir/fastboot-restore-boot-b.txt"
  log "Rearming active slot b after boot_b restore"
  fastboot_do set_active b 2>&1 | tee "$run_dir/fastboot-set-active-b-after-restore.txt"
  get_fastboot_var slot-retry-count:b | tee "$run_dir/slot-retry-count-b-after-restore.txt" || true
  get_fastboot_var slot-unbootable:b | tee "$run_dir/slot-unbootable-b-after-restore.txt" || true
}

collect_recovery_crash_artifacts() {
  local label="$1"
  local out="$run_dir/recovery-crash-$label"

  log "Collecting recovery crash artifacts: $label"
  "$HOTDOG_ROOT/scripts/collect-recovery-crash-artifacts.sh" \
    --serial "$SERIAL" \
    --out "$out" \
    > "$run_dir/collect-recovery-crash-$label.log" 2>&1 \
    || log "Recovery crash collection failed for $label"
}

restore_boot_b_from_adb_mode_if_configured() {
  local adb_mode="$1"

  [ -n "$RESTORE_IMAGE" ] || return 0
  [ -s "$RESTORE_IMAGE" ] || die "Restore image does not exist or is empty: $RESTORE_IMAGE" 2

  log "ADB mode '$adb_mode' visible after boot attempt; restoring boot_b through bootloader"
  collect_recovery_crash_artifacts "adb-$adb_mode-before-restore"
  adb_do reboot bootloader
  wait_for_fastboot 90
  validate_fastboot_identity
  ensure_bootloader_fastboot
  restore_boot_b_if_configured
  return_after_restore_from_fastboot
}

main() {
  validate_seconds BOOT_WAIT_SEC "$BOOT_WAIT_SEC"
  validate_seconds POLL_SEC "$POLL_SEC"
  validate_seconds FASTBOOT_CMD_TIMEOUT_SEC "$FASTBOOT_CMD_TIMEOUT_SEC"
  validate_seconds RESCUE_WATCHER_TIMEOUT_SEC "$RESCUE_WATCHER_TIMEOUT_SEC"
  validate_seconds RESCUE_WATCHER_POLL_SEC "$RESCUE_WATCHER_POLL_SEC"
  case "$RESTORE_AFTER_FASTBOOT" in
    recovery|system|bootloader|none) ;;
    *) die "--restore-after must be one of: recovery, system, bootloader, none" 2 ;;
  esac

  [ -n "$IMAGE" ] || die "Missing --image FILE" 2
  [ -s "$IMAGE" ] || die "Image does not exist or is empty: $IMAGE" 2

  command -v adb >/dev/null 2>&1 || die "Missing adb" 127
  command -v fastboot >/dev/null 2>&1 || die "Missing fastboot" 127
  command -v sha256sum >/dev/null 2>&1 || die "Missing sha256sum" 127
  command -v ping >/dev/null 2>&1 || die "Missing ping" 127
  command -v lsusb >/dev/null 2>&1 || die "Missing lsusb" 127
  command -v socat >/dev/null 2>&1 || die "Missing socat" 127
  command -v sshpass >/dev/null 2>&1 || die "Missing sshpass" 127
  command -v ssh >/dev/null 2>&1 || die "Missing ssh" 127

  log "Run directory: $run_dir"
  log "Target serial: ${SERIAL:-auto-detect}"
  log "Image: $IMAGE"
  log "Restore boot_b image: ${RESTORE_IMAGE:-none}"
  log "Start from pmOS SSH: $START_FROM_PMOS_SSH"
  log "Restore-after mode: $RESTORE_AFTER_FASTBOOT"
  log "Companion rescue watcher: $START_RESCUE_WATCHER"
  sha256sum "$IMAGE" | tee "$run_dir/image-sha256.txt"

  if [ "$START_FROM_PMOS_SSH" -eq 1 ]; then
    log "Starting from pmOS SSH; flashing boot_b via SSH helper and rebooting"
    PMOS_BOOT_ID_BEFORE="$(pmos_read_boot_id || true)"
    if [ -n "$PMOS_BOOT_ID_BEFORE" ]; then
      printf '%s\n' "$PMOS_BOOT_ID_BEFORE" > "$run_dir/pmos-boot-id-before.txt"
      log "pmOS boot_id before reboot: $PMOS_BOOT_ID_BEFORE"
    fi
    "$HOTDOG_ROOT/scripts/flash-boot-b-from-pmos-ssh.sh" \
      --image "$IMAGE" \
      --host "$PMOS_HOST" \
      --user "$PMOS_USER" \
      --password "$PMOS_PASSWORD" \
      --reboot \
      > "$run_dir/flash-boot-b-from-pmos-ssh-wrapper.log" 2>&1 || {
        sed 's/^/[flash-ssh] /' "$run_dir/flash-boot-b-from-pmos-ssh-wrapper.log" >&2 || true
        die "pmOS SSH flash/reboot helper failed" 4
      }
    sed 's/^/[flash-ssh] /' "$run_dir/flash-boot-b-from-pmos-ssh-wrapper.log" || true
    phone_lock_acquire "monitor boot_b image after pmOS SSH flash" 0
    start_rescue_watcher
  else
    phone_lock_acquire "test boot_b image" 0

    local state=""
    state="$(adb_state)"
    if [ "$state" = "recovery" ]; then
      log "Starting from recovery ADB; rebooting to bootloader"
      adb_do reboot bootloader
      wait_for_fastboot 90
    elif fastboot_present; then
      [ -n "$SERIAL" ] || SERIAL="$(awk 'NF >= 1 { print $1; exit }' "$run_dir/fastboot-devices-last.txt")"
      export ANDROID_SERIAL="$SERIAL"
      log "Starting from fastboot"
    else
      die "Phone is not visible in recovery ADB or fastboot" 3
    fi

    validate_fastboot_identity
    ensure_bootloader_fastboot
    validate_fastboot_identity

    get_fastboot_var current-slot | tee "$run_dir/current-slot-before.txt" || true
    get_fastboot_var slot-retry-count:b | tee "$run_dir/slot-retry-count-b-before.txt" || true
    get_fastboot_var slot-unbootable:b | tee "$run_dir/slot-unbootable-b-before.txt" || true

    log "Flashing boot_b"
    fastboot_do flash boot_b "$IMAGE" 2>&1 | tee "$run_dir/fastboot-flash-boot-b.txt"

    if [ "$SET_ACTIVE_B" -eq 1 ]; then
      log "Setting active slot b"
      fastboot_do set_active b 2>&1 | tee "$run_dir/fastboot-set-active-b.txt"
    fi

    get_fastboot_var current-slot | tee "$run_dir/current-slot-after-flash.txt" || true
    get_fastboot_var slot-retry-count:b | tee "$run_dir/slot-retry-count-b-after-flash.txt" || true
    get_fastboot_var slot-unbootable:b | tee "$run_dir/slot-unbootable-b-after-flash.txt" || true

    log "Rebooting into flashed boot_b"
    fastboot_do reboot 2>&1 | tee "$run_dir/fastboot-reboot.txt"
    start_rescue_watcher
  fi

  local deadline=$((SECONDS + BOOT_WAIT_SEC))
  local last_status=0
  local pmos_ping_seen=0
  local qualcomm_900e_seen=0
  local result="timeout"
  while [ "$SECONDS" -lt "$deadline" ]; do
    state="$(adb_state)"
    case "$state" in
      recovery|sideload)
        adb devices -l > "$run_dir/adb-visible-after-boot.txt" 2>&1 || true
        result="adb-$state"
        log "ADB visible after boot: $state"
        restore_boot_b_from_adb_mode_if_configured "$state"
        break
        ;;
      device)
        adb devices -l > "$run_dir/adb-visible-after-boot.txt" 2>&1 || true
        result="adb-$state"
        log "ADB visible after boot: $state"
        break
        ;;
    esac

    if fastboot_present; then
      result="fastboot"
      log "Fastboot returned after boot attempt"
      get_fastboot_var current-slot | tee "$run_dir/current-slot-after-return.txt" || true
      get_fastboot_var slot-retry-count:b | tee "$run_dir/slot-retry-count-b-after-return.txt" || true
      get_fastboot_var slot-unbootable:b | tee "$run_dir/slot-unbootable-b-after-return.txt" || true
      restore_boot_b_if_configured
      return_after_restore_from_fastboot
      break
    fi

    if qualcomm_900e_present; then
      if [ "$qualcomm_900e_seen" -eq 0 ]; then
        qualcomm_900e_seen=1
        log "Qualcomm crashdump / QUSB_BULK 900e visible after boot attempt; continuing to watch for fastboot recovery"
        grep -iE '05c6:900e|QUSB_BULK|Qualcomm' "$run_dir/lsusb-last.txt" | sed 's/^/[usb] /' || true
      fi
    fi

    if pmos_ping_probe; then
      if [ "$pmos_ping_seen" -eq 0 ]; then
        log "pmOS USB network ping OK at $PMOS_HOST"
        pmos_ping_seen=1
      fi

      if collect_pmos_telnet_logs; then
        result="pmos-telnet"
        log "pmOS telnet/debug shell collection OK"
        break
      fi
    fi

    if pmos_ssh_probe; then
      local pmos_boot_id_after=""
      result="pmos-ssh"
      log "pmOS SSH probe OK"
      if [ "$START_FROM_PMOS_SSH" -eq 1 ] && [ -n "$PMOS_BOOT_ID_BEFORE" ]; then
        pmos_boot_id_after="$(pmos_read_boot_id || true)"
        if [ -n "$pmos_boot_id_after" ]; then
          printf '%s\n' "$pmos_boot_id_after" > "$run_dir/pmos-boot-id-after.txt"
          if [ "$pmos_boot_id_after" = "$PMOS_BOOT_ID_BEFORE" ]; then
            log "WARNING: pmOS SSH boot_id did not change after requested reboot"
          else
            log "pmOS boot_id changed after reboot: $pmos_boot_id_after"
          fi
        fi
      fi
      collect_pmos_logs
      break
    fi

    if [ $((SECONDS - last_status)) -ge 30 ]; then
      log "Still waiting for boot result"
      ip -br addr > "$run_dir/host-ip-last.txt" 2>&1 || true
      last_status=$SECONDS
    fi
    sleep "$POLL_SEC"
  done

  if [ "$result" = "timeout" ]; then
    if [ "$pmos_ping_seen" -eq 1 ]; then
      result="pmos-ping"
      log "pmOS USB network stayed pingable, but no telnet/SSH/ADB/fastboot appeared before ${BOOT_WAIT_SEC}s"
    elif [ "$qualcomm_900e_seen" -eq 1 ]; then
      result="qualcomm-900e-timeout"
      log "Qualcomm 900e was seen, but no fastboot/ADB/pmOS recovery path appeared before ${BOOT_WAIT_SEC}s"
    else
      log "Timed out waiting for boot result after ${BOOT_WAIT_SEC}s"
    fi
    if fastboot_present; then
      restore_boot_b_if_configured
      return_after_restore_from_fastboot
    elif [ "$START_RESCUE_WATCHER" -eq 1 ] && [ -n "$RESCUE_WATCHER_PID" ]; then
      KEEP_RESCUE_WATCHER=1
      log "No USB recovery path at timeout; companion rescue watcher will keep waiting"
    fi
  fi

  adb devices -l > "$run_dir/adb-final.txt" 2>&1 || true
  fastboot devices -l > "$run_dir/fastboot-final.txt" 2>&1 || true
  log "Result: $result"
  log "Done: $run_dir"
}

main "$@"
