#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/env.sh"
source "$(dirname "$0")/phone-lock.sh"

SERIAL="${ANDROID_SERIAL:-$HOTDOG_TARGET_SERIAL}"
PMOS_HOST="${PMOS_HOST:-172.16.42.1}"
PMOS_USER="${PMOS_USER:-user}"
PMOS_PASSWORD="${PMOS_PASSWORD:-$HOTDOG_PMOS_PASSWORD}"
BOOT_IMAGE="$HOTDOG_ROOT/images/pmos-experiments/2026-07-09-011200-mainline617-nokaslr-nobtik-nomte-stockentry-v2dtb-rootwatchdog/boot-mainline617-nokaslr-nobtik-nomte-stockentry-v2dtb-rootwatchdog-600s-stockos-avb.img"
DTBO_IMAGE="$HOTDOG_ROOT/build/experiments/2026-07-09-013000-noop-dtbo-entry5/dtbo_b-entry5-noop-partition-padded.img"
RESTORE_BOOT_IMAGE="$HOTDOG_STABLE_PMOS_BOOT_B"
RESTORE_DTBO_IMAGE="$HOTDOG_ROOT/logs/partition-read-vbmeta-dtbo-clean-2026-07-08-230943/dtbo_b.img"
BOOT_WAIT_SEC="${BOOT_WAIT_SEC:-300}"
POLL_SEC="${POLL_SEC:-2}"
RESCUE_WATCHER_PID=""
KEEP_RESCUE_WATCHER=0

stamp="$(date +%F-%H%M%S)"
run_dir="$HOTDOG_LOG_ROOT/test-mainline-noop-dtbo-$stamp"
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
  if [ "$KEEP_RESCUE_WATCHER" -eq 0 ] && [ -n "$RESCUE_WATCHER_PID" ]; then
    if kill -0 "$RESCUE_WATCHER_PID" 2>/dev/null; then
      log "Stopping companion rescue watcher: PID $RESCUE_WATCHER_PID"
      kill "$RESCUE_WATCHER_PID" 2>/dev/null || true
      wait "$RESCUE_WATCHER_PID" 2>/dev/null || true
    fi
  elif [ -n "$RESCUE_WATCHER_PID" ]; then
    log "Leaving companion rescue watcher running: PID $RESCUE_WATCHER_PID"
  fi
  phone_lock_release || true
}
trap cleanup EXIT

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "Missing command: $cmd" 127
}

remote_quote() {
  local value="$1"
  printf "'%s'" "${value//\'/\'\\\'\'}"
}

ssh_base() {
  sshpass -p "$PMOS_PASSWORD" ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile="$run_dir/known_hosts" \
    -o ConnectTimeout=8 \
    -o PreferredAuthentications=password \
    -o PubkeyAuthentication=no \
    "$PMOS_USER@$PMOS_HOST" "$@"
}

remote_sudo_sh() {
  local script="$1"
  ssh_base "sudo -n sh -c $(remote_quote "$script")"
}

fastboot_do() {
  fastboot -s "$SERIAL" "$@"
}

adb_do() {
  adb -s "$SERIAL" "$@"
}

adb_state() {
  adb devices > "$run_dir/adb-devices-last.txt" 2>&1 || true
  awk -v serial="$SERIAL" '$1 == serial { print $2; found=1 } END { if (!found) print "" }' "$run_dir/adb-devices-last.txt"
}

fastboot_present() {
  fastboot devices -l > "$run_dir/fastboot-devices-last.txt" 2>&1 || true
  awk -v serial="$SERIAL" 'NF >= 1 && $1 == serial { found=1 } END { exit found ? 0 : 1 }' "$run_dir/fastboot-devices-last.txt"
}

pmos_ssh_probe() {
  ping -c 1 -W 1 "$PMOS_HOST" > "$run_dir/ping-last-$PMOS_HOST.txt" 2>&1 || return 1
  sshpass -p "$PMOS_PASSWORD" ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile="$run_dir/known_hosts-pmos-after" \
    -o ConnectTimeout=5 \
    -o PreferredAuthentications=password \
    -o PubkeyAuthentication=no \
    "$PMOS_USER@$PMOS_HOST" 'printf "PMOS_SSH_OK\n"; uname -a; cat /proc/cmdline' \
    > "$run_dir/ssh-probe-after.txt" 2>&1
}

start_rescue_watcher() {
  local wrapper_log="$run_dir/companion-rescue-watcher.log"

  log "Starting companion rescue watcher for boot_b+dtbo_b restore"
  "$HOTDOG_ROOT/scripts/rescue-boot-b-when-visible.sh" \
    --serial "$SERIAL" \
    --restore-boot-b "$RESTORE_BOOT_IMAGE" \
    --restore-dtbo-b "$RESTORE_DTBO_IMAGE" \
    --after-restore system \
    --timeout 604800 \
    --poll 3 \
    > "$wrapper_log" 2>&1 &
  RESCUE_WATCHER_PID="$!"
  printf '%s\n' "$RESCUE_WATCHER_PID" > "$run_dir/companion-rescue-watcher.pid"
  log "Companion rescue watcher PID: $RESCUE_WATCHER_PID"
}

remote_force_reboot() {
  local reboot_cmd='sudo -n sh -c '"'"'sync; echo b > /proc/sysrq-trigger'"'"''

  log "Sending kernel sysrq reboot"
  timeout 10 sshpass -p "$PMOS_PASSWORD" ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile="$run_dir/known_hosts" \
    -o ConnectTimeout=8 \
    -o PreferredAuthentications=password \
    -o PubkeyAuthentication=no \
    "$PMOS_USER@$PMOS_HOST" "$reboot_cmd" \
    > "$run_dir/reboot-sysrq.txt" 2>&1 || true

  for _ in {1..20}; do
    if ! ping -c 1 -W 1 "$PMOS_HOST" > "$run_dir/reboot-ping-last.txt" 2>&1; then
      log "USB ping dropped after reboot command"
      return 0
    fi
    sleep 1
  done
  log "WARNING: did not observe USB ping drop after reboot command"
}

flash_from_pmos() {
  local remote_dir="/tmp/hotdog-dtbo-boot-test-$stamp"
  local remote_boot="$remote_dir/boot.img"
  local remote_dtbo="$remote_dir/dtbo.img"
  local remote_script="$remote_dir/write-dtbo-boot.sh"
  local boot_sha boot_size dtbo_sha dtbo_size

  boot_sha="$(sha256sum "$BOOT_IMAGE" | awk '{ print $1 }')"
  boot_size="$(stat -c '%s' "$BOOT_IMAGE")"
  dtbo_sha="$(sha256sum "$DTBO_IMAGE" | awk '{ print $1 }')"
  dtbo_size="$(stat -c '%s' "$DTBO_IMAGE")"

  log "Boot image: $BOOT_IMAGE"
  log "Boot sha256: $boot_sha"
  log "DTBO image: $DTBO_IMAGE"
  log "DTBO sha256: $dtbo_sha"
  log "Restore boot image: $RESTORE_BOOT_IMAGE"
  log "Restore dtbo image: $RESTORE_DTBO_IMAGE"

  phone_lock_acquire "flash dtbo_b+boot_b from pmOS SSH" 0 ||
    die "Could not acquire local phone-operation lock" 3

  log "Probing SSH and noninteractive root"
  ssh_base 'printf "ssh-ok "; uname -n; sudo -n id'

  log "Creating remote work directory: $remote_dir"
  ssh_base "mkdir -p $(remote_quote "$remote_dir")"

  log "Copying dtbo and boot images over SSH"
  ssh_base "cat > $(remote_quote "$remote_dtbo")" < "$DTBO_IMAGE"
  ssh_base "cat > $(remote_quote "$remote_boot")" < "$BOOT_IMAGE"

  log "Installing remote writer"
  ssh_base "cat > $(remote_quote "$remote_script")" <<'REMOTE_SCRIPT'
#!/bin/sh
set -eu

log() {
  printf '[remote %s] %s\n' "$(date '+%F %T')" "$*"
}

die() {
  log "ERROR: $1"
  exit "${2:-1}"
}

find_part() {
  label="$1"
  for candidate in \
    "/dev/disk/by-partlabel/$label" \
    "/dev/block/by-name/$label" \
    "/dev/$label"
  do
    if [ -b "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

write_and_verify() {
  label="$1"
  img="$2"
  expected_sha="$3"
  expected_size="$4"
  part="$(find_part "$label")" || die "Could not find $label block node" 5

  [ -s "$img" ] || die "Missing remote image: $img" 2
  actual_sha="$(sha256sum "$img" | awk '{ print $1 }')"
  [ "$actual_sha" = "$expected_sha" ] || die "$label image sha mismatch: $actual_sha != $expected_sha" 4
  actual_size="$(wc -c < "$img" | tr -d '[:space:]')"
  [ "$actual_size" = "$expected_size" ] || die "$label image size mismatch: $actual_size != $expected_size" 4

  log "Writing $img to $part"
  dd if="$img" of="$part" bs=4M conv=fsync
  sync

  blocks=$(( (expected_size + 1048575) / 1048576 ))
  log "Verifying first $expected_size bytes from $part"
  readback_sha="$(dd if="$part" bs=1048576 count="$blocks" 2>/dev/null | head -c "$expected_size" | sha256sum | awk '{ print $1 }')"
  [ "$readback_sha" = "$expected_sha" ] || die "$label readback sha mismatch: $readback_sha != $expected_sha" 6
  log "$label verify OK: $readback_sha"
}

if [ -x /etc/local.d/hotdog-devnodes.start ]; then
  log "Refreshing hotdog device nodes"
  /etc/local.d/hotdog-devnodes.start || true
fi

write_and_verify dtbo_b "$REMOTE_DTBO" "$DTBO_SHA" "$DTBO_SIZE"
write_and_verify boot_b "$REMOTE_BOOT" "$BOOT_SHA" "$BOOT_SIZE"
REMOTE_SCRIPT
  ssh_base "chmod 700 $(remote_quote "$remote_script")"

  log "Flashing and verifying dtbo_b then boot_b from pmOS"
  remote_sudo_sh \
    "REMOTE_DTBO=$(remote_quote "$remote_dtbo") DTBO_SHA=$(remote_quote "$dtbo_sha") DTBO_SIZE=$(remote_quote "$dtbo_size") REMOTE_BOOT=$(remote_quote "$remote_boot") BOOT_SHA=$(remote_quote "$boot_sha") BOOT_SIZE=$(remote_quote "$boot_size") sh $(remote_quote "$remote_script")"

  log "Cleaning remote work directory"
  ssh_base "rm -rf $(remote_quote "$remote_dir")" || true

  log "Rebooting phone now"
  remote_force_reboot
}

restore_from_fastboot() {
  log "Restoring dtbo_b then boot_b from fastboot"
  sha256sum "$RESTORE_DTBO_IMAGE" | tee "$run_dir/restore-dtbo-image-sha256.txt"
  sha256sum "$RESTORE_BOOT_IMAGE" | tee "$run_dir/restore-boot-image-sha256.txt"
  fastboot_do flash dtbo_b "$RESTORE_DTBO_IMAGE" 2>&1 | tee "$run_dir/fastboot-restore-dtbo-b.txt"
  fastboot_do flash boot_b "$RESTORE_BOOT_IMAGE" 2>&1 | tee "$run_dir/fastboot-restore-boot-b.txt"
  fastboot_do set_active b 2>&1 | tee "$run_dir/fastboot-set-active-b-after-restore.txt"
  log "Rebooting system after restore"
  fastboot_do reboot 2>&1 | tee "$run_dir/fastboot-reboot-system-after-restore.txt" || true
}

main() {
  require_cmd adb
  require_cmd fastboot
  require_cmd ping
  require_cmd sha256sum
  require_cmd ssh
  require_cmd sshpass
  require_cmd stat
  require_cmd timeout

  [ -s "$BOOT_IMAGE" ] || die "Missing boot image: $BOOT_IMAGE" 2
  [ -s "$DTBO_IMAGE" ] || die "Missing dtbo image: $DTBO_IMAGE" 2
  [ -s "$RESTORE_BOOT_IMAGE" ] || die "Missing restore boot image: $RESTORE_BOOT_IMAGE" 2
  [ -s "$RESTORE_DTBO_IMAGE" ] || die "Missing restore dtbo image: $RESTORE_DTBO_IMAGE" 2

  log "Run directory: $run_dir"
  log "Target serial: $SERIAL"
  log "Boot wait: ${BOOT_WAIT_SEC}s"

  flash_from_pmos
  phone_lock_release || true
  phone_lock_acquire "monitor dtbo_b+boot_b test" 0 ||
    die "Could not acquire monitor lock" 3
  start_rescue_watcher

  local deadline=$((SECONDS + BOOT_WAIT_SEC))
  local last_status=0
  local state=""
  local result="timeout"

  while [ "$SECONDS" -lt "$deadline" ]; do
    if fastboot_present; then
      result="fastboot"
      log "Fastboot returned after dtbo_b+boot_b test"
      restore_from_fastboot
      break
    fi

    state="$(adb_state)"
    case "$state" in
      recovery|sideload)
        result="adb-$state"
        log "ADB visible after dtbo_b+boot_b test: $state"
        adb_do reboot bootloader || true
        sleep 5
        local fb_deadline=$((SECONDS + 90))
        while [ "$SECONDS" -lt "$fb_deadline" ]; do
          if fastboot_present; then
            restore_from_fastboot
            break
          fi
          sleep 2
        done
        break
        ;;
      device)
        result="adb-device"
        log "Android ADB device state appeared unexpectedly"
        break
        ;;
    esac

    if pmos_ssh_probe; then
      result="pmos-ssh"
      log "pmOS SSH probe OK after dtbo_b+boot_b test"
      break
    fi

    if [ $((SECONDS - last_status)) -ge 30 ]; then
      log "Still waiting for dtbo_b+boot_b test result"
      last_status=$SECONDS
    fi
    sleep "$POLL_SEC"
  done

  if [ "$result" = "timeout" ]; then
    KEEP_RESCUE_WATCHER=1
    log "Timed out without USB recovery path; companion rescue watcher will keep waiting"
  fi

  adb devices -l > "$run_dir/adb-final.txt" 2>&1 || true
  fastboot devices -l > "$run_dir/fastboot-final.txt" 2>&1 || true
  log "Result: $result"
  log "Done: $run_dir"
}

main "$@"
