#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/env.sh"
source "$(dirname "$0")/phone-lock.sh"

SERIAL="${ANDROID_SERIAL:-}"
IMAGE=""
BOOT_WAIT_SEC="${BOOT_WAIT_SEC:-240}"
POLL_SEC="${POLL_SEC:-2}"
PMOS_USER="${PMOS_USER:-user}"
PMOS_PASSWORD="${PMOS_PASSWORD:-$HOTDOG_PMOS_PASSWORD}"
PMOS_HOST="${PMOS_HOST:-172.16.42.1}"
EXPECTED_KERNEL_PREFIX="${EXPECTED_KERNEL_PREFIX:-}"

usage() {
  cat <<'USAGE'
Usage: test-fastboot-boot-image.sh --image boot.img [options]

Boot an Android boot image via `fastboot boot` without flashing boot_a/boot_b,
then classify whether fastboot, recovery ADB, Android ADB, or pmOS SSH appears.

Options:
  --image FILE       Boot image to pass to `fastboot boot`.
  --serial SERIAL    Restrict adb/fastboot commands to SERIAL.
  --boot-wait SEC    Seconds to watch for a result. Default: 240.
  --poll SEC         Poll interval. Default: 2.
  --expect-kernel-prefix PREFIX
                     Require pmOS SSH to report a kernel release beginning
                     with PREFIX (for example: 6.17.0-sm8150).
  -h, --help         Show this help.
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
    --expect-kernel-prefix)
      [ "$#" -ge 2 ] || { echo "Missing value for --expect-kernel-prefix" >&2; exit 2; }
      EXPECTED_KERNEL_PREFIX="$2"
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
run_dir="$HOTDOG_LOG_ROOT/test-fastboot-boot-image-$stamp"
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

adb_state() {
  adb devices > "$run_dir/adb-devices-last.txt" 2>&1 || true
  if [ -n "$SERIAL" ]; then
    awk -v serial="$SERIAL" '$1 == serial { print $2; found=1 } END { if (!found) print "" }' "$run_dir/adb-devices-last.txt"
  else
    awk 'NF >= 2 && $2 != "offline" { print $2; exit }' "$run_dir/adb-devices-last.txt"
  fi
}

fastboot_present() {
  hotdog_fastboot_devices > "$run_dir/fastboot-devices-last.txt" 2>&1 || true
  if [ -n "$SERIAL" ]; then
    awk -v serial="$SERIAL" 'NF >= 1 && $1 == serial { found=1 } END { exit found ? 0 : 1 }' "$run_dir/fastboot-devices-last.txt"
  else
    awk 'NF >= 1 { found=1 } END { exit found ? 0 : 1 }' "$run_dir/fastboot-devices-last.txt"
  fi
}

wait_for_fastboot() {
  local timeout="$1"
  local deadline=$((SECONDS + timeout))

  log "Waiting for fastboot, timeout ${timeout}s"
  while [ "$SECONDS" -lt "$deadline" ]; do
    if fastboot_present; then
      if [ -z "$SERIAL" ]; then
        SERIAL="$(awk 'NF >= 1 { print $1; exit }' "$run_dir/fastboot-devices-last.txt")"
        export ANDROID_SERIAL="$SERIAL"
      fi
      log "Fastboot target detected: $SERIAL"
      return 0
    fi
    sleep "$POLL_SEC"
  done
  die "Timed out waiting for fastboot" 3
}

pmos_ssh_probe() {
  ping -c 1 -W 1 "$PMOS_HOST" > "$run_dir/ping-last-$PMOS_HOST.txt" 2>&1 || return 1
  sshpass -p "$PMOS_PASSWORD" ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile="$run_dir/known_hosts" \
    -o ConnectTimeout=5 \
    -o PreferredAuthentications=password \
    -o PubkeyAuthentication=no \
    "$PMOS_USER@$PMOS_HOST" \
    'printf "PMOS_SSH_OK\nPMOS_BOOT_ID="; cat /proc/sys/kernel/random/boot_id; printf "PMOS_UNAME_R="; uname -r; uname -a' \
    > "$run_dir/ssh-probe.txt" 2>&1
}

qualcomm_900e_present() {
  lsusb -d 05c6:900e 2>/dev/null | grep -q .
}

main() {
  validate_seconds BOOT_WAIT_SEC "$BOOT_WAIT_SEC"
  validate_seconds POLL_SEC "$POLL_SEC"

  [ -n "$IMAGE" ] || die "Missing --image FILE" 2
  [ -s "$IMAGE" ] || die "Image does not exist or is empty: $IMAGE" 2
  command -v adb >/dev/null 2>&1 || die "Missing adb" 127
  command -v fastboot >/dev/null 2>&1 || die "Missing fastboot" 127
  command -v sha256sum >/dev/null 2>&1 || die "Missing sha256sum" 127

  log "Run directory: $run_dir"
  log "Target serial: ${SERIAL:-auto-detect}"
  log "Image: $IMAGE"
  sha256sum "$IMAGE" | tee "$run_dir/image-sha256.txt"

  phone_lock_acquire "fastboot boot image" 0

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

  log "Booting image through fastboot boot"
  if ! fastboot_do boot "$IMAGE" 2>&1 | tee "$run_dir/fastboot-boot.txt"; then
    log "fastboot boot command failed"
    hotdog_fastboot_devices > "$run_dir/fastboot-final.txt" 2>&1 || true
    exit 4
  fi

  log "Waiting for the original fastboot USB instance to depart"
  local departure_deadline=$((SECONDS + 10))
  while hotdog_fastboot_usb_visible && [ "$SECONDS" -lt "$departure_deadline" ]; do
    sleep 0.2
  done
  phone_lock_release || true

  local deadline=$((SECONDS + BOOT_WAIT_SEC))
  local last_status=0
  local result="timeout"
  local ssh_kernel=""
  while [ "$SECONDS" -lt "$deadline" ]; do
    state="$(adb_state)"
    case "$state" in
      recovery|sideload|device)
        adb devices -l > "$run_dir/adb-visible-after-boot.txt" 2>&1 || true
        result="adb-$state"
        log "ADB visible after fastboot boot: $state"
        break
        ;;
    esac

    if qualcomm_900e_present; then
      result="qualcomm-900e"
      lsusb -d 05c6:900e > "$run_dir/qualcomm-900e.txt" 2>&1 || true
      log "Qualcomm Sahara crashdump 900e visible after fastboot boot"
      break
    fi

    if fastboot_present; then
      result="fastboot"
      log "Fastboot returned after fastboot boot"
      break
    fi

    if pmos_ssh_probe; then
      ssh_kernel="$(sed -n 's/^PMOS_UNAME_R=//p' "$run_dir/ssh-probe.txt" | tail -n 1)"
      printf '%s\n' "$ssh_kernel" > "$run_dir/ssh-kernel-release.txt"
      if [ -n "$EXPECTED_KERNEL_PREFIX" ] && [[ "$ssh_kernel" != "$EXPECTED_KERNEL_PREFIX"* ]]; then
        case "$ssh_kernel" in
          4.14.357-openela-perf*) result="pmos-bridge-recovery" ;;
          *) result="pmos-unexpected-kernel" ;;
        esac
        log "pmOS SSH returned kernel ${ssh_kernel:-unknown}; expected prefix $EXPECTED_KERNEL_PREFIX"
      else
        result="pmos-ssh"
        log "pmOS SSH probe OK (kernel ${ssh_kernel:-unknown})"
      fi
      break
    fi

    if [ $((SECONDS - last_status)) -ge 30 ]; then
      log "Still waiting for fastboot boot result"
      ip -br addr > "$run_dir/host-ip-last.txt" 2>&1 || true
      last_status=$SECONDS
    fi
    sleep "$POLL_SEC"
  done

  adb devices -l > "$run_dir/adb-final.txt" 2>&1 || true
  hotdog_fastboot_devices > "$run_dir/fastboot-final.txt" 2>&1 || true
  log "Result: $result"
  log "Done: $run_dir"

  case "$result" in
    pmos-bridge-recovery|pmos-unexpected-kernel)
      return 5
      ;;
  esac
}

main "$@"
