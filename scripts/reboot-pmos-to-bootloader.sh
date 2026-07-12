#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/env.sh"
source "$(dirname "$0")/phone-lock.sh"

PMOS_HOST="${PMOS_HOST:-$HOTDOG_PMOS_HOST}"
PMOS_USER="${PMOS_USER:-$HOTDOG_PMOS_USER}"
PMOS_PASSWORD="${PMOS_PASSWORD:-$HOTDOG_PMOS_PASSWORD}"
SERIAL="${ANDROID_SERIAL:-$HOTDOG_TARGET_SERIAL}"
HELPER="$HOTDOG_ROOT/build/hotdog-reboot-mode-aarch64"
MODE="bootloader"
WAIT_SEC="${WAIT_SEC:-120}"
REBOOT_COMMAND_TIMEOUT_SEC="${REBOOT_COMMAND_TIMEOUT_SEC:-20}"
EXPECTED_SOURCE_BOOT_ID=""
EXPECTED_SOURCE_KERNEL=""
EXPECTED_SOURCE_CMDLINE_TOKENS=()
HELPER_EXPECTED_SHA256=""
INHERITED_PHONE_LOCK_FD=""

usage() {
  cat <<'USAGE'
Usage: reboot-pmos-to-bootloader.sh [options]

Upload a static arm64 RESTART2 helper to a running postmarketOS bridge and
request a reboot into the bootloader. The helper writes no partition.

Options:
  --mode MODE       bootloader (default) or recovery.
  --helper FILE     Static arm64 helper binary.
  --host HOST       postmarketOS SSH host. Default: 172.16.42.1.
  --user USER       SSH user. Default: user.
  --password PASS   SSH password. Defaults to PMOS_PASSWORD.
  --serial SERIAL   Expected fastboot/ADB serial. Defaults to ANDROID_SERIAL.
  --wait SEC        Visibility timeout. Default: 120.
  --command-timeout SEC
                    Seconds to wait for SSH to close after RESTART2. Default: 20.
  --expected-source-boot-id ID
  --expected-source-kernel RELEASE
  --expected-source-cmdline-token TOKEN
  --helper-sha256 SHA256
                    Pin and atomically revalidate the source identity/helper.
  --phone-lock-fd FD
                    Adopt an already-held phone-operation lock from the caller.
  -h, --help        Show this help.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --mode) MODE="$2"; shift ;;
    --helper) HELPER="$2"; shift ;;
    --host) PMOS_HOST="$2"; shift ;;
    --user) PMOS_USER="$2"; shift ;;
    --password) PMOS_PASSWORD="$2"; shift ;;
    --serial) SERIAL="$2"; shift ;;
    --wait) WAIT_SEC="$2"; shift ;;
    --command-timeout) REBOOT_COMMAND_TIMEOUT_SEC="$2"; shift ;;
    --expected-source-boot-id) EXPECTED_SOURCE_BOOT_ID="$2"; shift ;;
    --expected-source-kernel) EXPECTED_SOURCE_KERNEL="$2"; shift ;;
    --expected-source-cmdline-token) EXPECTED_SOURCE_CMDLINE_TOKENS+=("$2"); shift ;;
    --helper-sha256) HELPER_EXPECTED_SHA256="${2,,}"; shift ;;
    --phone-lock-fd) INHERITED_PHONE_LOCK_FD="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

stamp="$(date +%F-%H%M%S)"
run_dir="$HOTDOG_LOG_ROOT/reboot-pmos-$MODE-$stamp"
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

adb_state() {
  adb devices > "$run_dir/adb-last.txt" 2>&1 || true
  awk -v serial="$SERIAL" '$1 == serial { print $2; found=1 } END { if (!found) print "" }' "$run_dir/adb-last.txt"
}

fastboot_present() {
  hotdog_fastboot_devices > "$run_dir/fastboot-last.txt" 2>&1 || true
  awk -v serial="$SERIAL" '$1 == serial { found=1 } END { exit found ? 0 : 1 }' "$run_dir/fastboot-last.txt"
}

main() {
  local helper_sha=""
  local remote_helper="/tmp/hotdog-reboot-mode"
  local remote_command=""
  local deadline=0
  local token=""
  local checks=""

  [ -n "$PMOS_PASSWORD" ] || die "Set PMOS_PASSWORD or use --password" 2
  [ -n "$SERIAL" ] || die "Set ANDROID_SERIAL or HOTDOG_TARGET_SERIAL" 2
  case "$MODE" in
    bootloader|recovery) ;;
    *) die "--mode must be bootloader or recovery" 2 ;;
  esac
  [[ "$WAIT_SEC" =~ ^[0-9]+$ ]] && [ "$WAIT_SEC" -gt 0 ] || die "--wait must be a positive integer" 2
  [[ "$REBOOT_COMMAND_TIMEOUT_SEC" =~ ^[0-9]+$ ]] && [ "$REBOOT_COMMAND_TIMEOUT_SEC" -gt 0 ] || die "--command-timeout must be a positive integer" 2

  for command in ssh sshpass sha256sum awk timeout adb fastboot file grep; do
    command -v "$command" >/dev/null 2>&1 || die "Missing command: $command" 127
  done
  [ -s "$HELPER" ] || die "Missing helper: $HELPER" 2
  file "$HELPER" | grep -q 'ARM aarch64' || die "Helper is not an aarch64 executable" 2

  helper_sha="$(sha256sum "$HELPER" | awk '{ print $1 }')"
  if [ -n "$HELPER_EXPECTED_SHA256" ]; then
    [ "$helper_sha" = "$HELPER_EXPECTED_SHA256" ] || die "Helper SHA256 mismatch" 3
  fi
  [ -n "$EXPECTED_SOURCE_BOOT_ID" ] || die "--expected-source-boot-id is required" 2
  [ -n "$EXPECTED_SOURCE_KERNEL" ] || die "--expected-source-kernel is required" 2
  [ "${#EXPECTED_SOURCE_CMDLINE_TOKENS[@]}" -gt 0 ] || die "At least one --expected-source-cmdline-token is required" 2
  log "Run directory: $run_dir"
  log "Mode: $MODE"
  log "Helper sha256: $helper_sha"

  if [ -n "$INHERITED_PHONE_LOCK_FD" ]; then
    phone_lock_adopt_fd "$INHERITED_PHONE_LOCK_FD" ||
      die "Could not adopt inherited phone-operation lock" 3
  else
    phone_lock_acquire "reboot pmOS to $MODE" 0 || die "Could not acquire phone-operation lock" 3
  fi
  log "Requesting RESTART2($MODE)"
  checks="test \"\$(cat /proc/sys/kernel/random/boot_id)\" = $(remote_quote "$EXPECTED_SOURCE_BOOT_ID"); test \"\$(uname -r)\" = $(remote_quote "$EXPECTED_SOURCE_KERNEL"); cmdline=\$(cat /proc/cmdline);"
  for token in "${EXPECTED_SOURCE_CMDLINE_TOKENS[@]}"; do
    checks+=" case \" \$cmdline \" in *$(remote_quote " $token ")*) ;; *) exit 7 ;; esac;"
  done
  remote_command="set -e; cat > $(remote_quote "$remote_helper"); chmod 700 $(remote_quote "$remote_helper"); test \"\$(sha256sum $(remote_quote "$remote_helper") | awk '{ print \$1 }')\" = $(remote_quote "$helper_sha"); $checks sudo -n id; printf 'HOTDOG_BOOTLOADER_DISPATCH=%s\\n' $(remote_quote "$EXPECTED_SOURCE_BOOT_ID"); sudo -n $(remote_quote "$remote_helper") $(remote_quote "$MODE")"
  timeout "$REBOOT_COMMAND_TIMEOUT_SEC" sshpass -p "$PMOS_PASSWORD" ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile="$run_dir/known_hosts" \
    -o ConnectTimeout=2 \
    -o PreferredAuthentications=password \
    -o PubkeyAuthentication=no \
    "$PMOS_USER@$PMOS_HOST" \
    "$remote_command" \
    < "$HELPER" 2>&1 | tee "$run_dir/reboot-command.txt" || true

  phone_lock_release || true
  deadline=$((SECONDS + WAIT_SEC))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if [ "$MODE" = "bootloader" ] && fastboot_present; then
      log "Fastboot visible: $SERIAL"
      return 0
    fi
    if [ "$MODE" = "recovery" ] && [ "$(adb_state)" = "recovery" ]; then
      log "Recovery ADB visible: $SERIAL"
      return 0
    fi
    sleep 2
  done

  die "$MODE did not become visible within ${WAIT_SEC}s" 4
}

main "$@"
