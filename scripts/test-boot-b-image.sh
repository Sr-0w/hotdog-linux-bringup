#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=/dev/null
source "$(dirname "$0")/env.sh"
# shellcheck source=/dev/null
source "$(dirname "$0")/phone-lock.sh"

SERIAL="${ANDROID_SERIAL:-$HOTDOG_TARGET_SERIAL}"
IMAGE=""
IMAGE_EXPECTED_SHA256=""
DUAL_PARTITION_TRANSACTION=0
CANDIDATE_DTBO_IMAGE=""
CANDIDATE_DTBO_EXPECTED_SHA256=""
RESTORE_DTBO_IMAGE=""
RESTORE_DTBO_EXPECTED_SHA256=""
RESTORE_COMPLETE_FILE=""
REBOOT_HELPER="$HOTDOG_ROOT/build/hotdog-reboot-mode-aarch64"
REBOOT_HELPER_EXPECTED_SHA256=""
RESTORE_IMAGE="${RESTORE_IMAGE:-$HOTDOG_STABLE_PMOS_BOOT_B}"
RESTORE_IMAGE_EXPECTED_SHA256=""
EXPECTED_FASTBOOT_PRODUCTS="${EXPECTED_FASTBOOT_PRODUCTS:-msmnile hotdog}"
REQUIRE_FASTBOOT_UNLOCKED=1
BOOT_WAIT_SEC="${BOOT_WAIT_SEC:-240}"
POLL_SEC="${POLL_SEC:-2}"
RETURN_RECOVERY=1
RESTORE_AFTER_FASTBOOT="${RESTORE_AFTER_FASTBOOT:-recovery}"
SET_ACTIVE_B=1
START_FROM_PMOS_SSH=0
FASTBOOT_CMD_TIMEOUT_SEC="${FASTBOOT_CMD_TIMEOUT_SEC:-15}"
PMOS_USER="${PMOS_USER:-$HOTDOG_PMOS_USER}"
PMOS_PASSWORD="${PMOS_PASSWORD:-$HOTDOG_PMOS_PASSWORD}"
PMOS_HOST="${PMOS_HOST:-$HOTDOG_PMOS_HOST}"
PMOS_TELNET_PORTS="${PMOS_TELNET_PORTS:-23 2323}"
PMOS_BOOT_ID_BEFORE=""
PMOS_KERNEL_BEFORE=""
PMOS_CMDLINE_BEFORE=""
EXPECT_SOURCE_KERNEL_PREFIX=""
EXPECT_SOURCE_CMDLINE_TOKENS=()
EXPECT_KERNEL_PREFIX=""
EXPECT_CMDLINE_TOKENS=()
PMOS_PROBE_BOOT_ID=""
PMOS_PROBE_KERNEL=""
PMOS_PROBE_CMDLINE=""
PMOS_PROBE_ATOMIC_ACKED=0
STRICT_SSH_EXPECTATION=0
RESTORE_IMAGE_SHA256=""
START_RESCUE_WATCHER=0
RESCUE_WATCHER_TIMEOUT_SEC="${RESCUE_WATCHER_TIMEOUT_SEC:-21600}"
RESCUE_WATCHER_POLL_SEC="${RESCUE_WATCHER_POLL_SEC:-5}"
RESCUE_WATCHER_READY_TIMEOUT_SEC="${RESCUE_WATCHER_READY_TIMEOUT_SEC:-10}"
declare -a RESCUE_WATCHER_PIDS=("" "")
declare -a RESCUE_WATCHER_STARTTIMES=("" "")
declare -a RESCUE_WATCHER_NONCES=("" "")
declare -a RESCUE_WATCHER_READY_FILES=("" "")
declare -a RESCUE_WATCHER_CHALLENGE_FILES=("" "")
declare -a RESCUE_WATCHER_ACK_FILES=("" "")
declare -a RESCUE_WATCHER_SCRIPT_PATHS=("" "")
KEEP_RESCUE_WATCHER=0
BOOT_B_MAY_BE_DIRTY=0
DTBO_B_MAY_BE_DIRTY=0
RESTORE_READBACK_VERIFIED=0
STRICT_MAINLINE_SUCCESS_ACKED=0
REQUIRE_DIRTY_SURVIVAL=0
CLEANUP_RUNNING=0
ACTIVE_TRANSPORT_PID=""
FLASH_BOOT_B_SSH_HELPER="${HOTDOG_FLASH_BOOT_B_SSH_HELPER:-$HOTDOG_ROOT/scripts/flash-boot-b-from-pmos-ssh.sh}"
RESCUE_WATCHER_HELPER="${HOTDOG_RESCUE_WATCHER_HELPER:-$HOTDOG_ROOT/scripts/rescue-boot-b-when-visible.sh}"

usage() {
  cat <<'USAGE'
Usage: test-boot-b-image.sh --image boot.img [options]

Flash one boot image to boot_b, reboot, classify the result, and run the
configured restore fallback if the bootloader rejects the image.
The default mode only writes boot_b. The explicit dual-partition mode also
writes dtbo_b; neither mode writes super, vbmeta, recovery, or other partitions.

Options:
  --image FILE           Boot image to flash to boot_b.
  --image-sha256 SHA256  Require this exact image hash through the final writer.
  --restore-boot-b FILE  Restore boot_b to FILE if fastboot returns.
  --restore-boot-b-sha256 SHA256
                         Require this exact restore hash through every fallback.
  --dual-partition-transaction
                         Explicit v3 dtbo_b + boot_b transaction. Requires all
                         four DTBO path/hash arguments and two rescue watchers.
  --candidate-dtbo-b FILE
  --candidate-dtbo-b-sha256 SHA256
  --restore-dtbo-b FILE
  --restore-dtbo-b-sha256 SHA256
  --reboot-helper FILE
  --reboot-helper-sha256 SHA256
  --serial SERIAL        Restrict adb/fastboot commands to SERIAL.
  --expected-product STR Space-separated fastboot products. Default: "msmnile hotdog".
  --allow-locked         Do not fail early if fastboot reports locked.
  --no-set-active-b      Do not run fastboot set_active b before reboot.
  --no-return-recovery   Leave the device in fastboot if the image is rejected.
  --restore-after MODE   recovery, system, bootloader, or none after restoring
                         boot_b from fastboot/ADB fallback. Default: recovery.
  --from-pmos-ssh        Start from the currently booted pmOS SSH userland:
                         flash boot_b via SSH, reboot, then classify result.
  --expect-kernel-prefix PREFIX
                         Require the post-boot pmOS SSH uname -r to start with
                         PREFIX. A mismatch is classified separately and exits
                         nonzero, so a restored bridge is not a mainline success.
  --expect-cmdline-token TOKEN
                         Require TOKEN as a complete post-boot /proc/cmdline
                         token. Repeat for multiple target identity markers.
  --expect-source-kernel-prefix PREFIX
                         Before flashing from pmOS SSH, require the current
                         uname -r to start with PREFIX.
  --expect-source-cmdline-token TOKEN
                         Before flashing from pmOS SSH, require TOKEN as a
                         complete /proc/cmdline token. Repeat as needed.
  --boot-wait SEC        Seconds to watch for fastboot/ADB/pmOS SSH. Default: 240.
  --poll SEC             Poll interval. Default: 2.
  --fastboot-timeout SEC Seconds to allow individual fastboot getvar/reboot
                          commands before treating them as failed. Default: 15.
  --start-rescue-watcher  Start two independent companion rescue watchers. Both
                         are prearmed and attested before any boot_b write.
                         If the test times out without a USB recovery path, it is
                         left running.
                         A strict mainline success intentionally keeps D1 in
                         boot_b and stops the watcher only after watchdog ACK.
  --require-dirty-survival
                         Pin fail-closed dirty handling even if future caller
                         options change. Requires --start-rescue-watcher.
                         D1 launchers always set both options.
  --rescue-watch-timeout SEC
                         Companion rescue watcher timeout. Default: 21600.
  --rescue-watch-poll SEC
                         Companion rescue watcher poll interval. Default: 5.
  -h, --help             Show this help.
USAGE

  printf '%s\n' \
    'Legacy generic calls without a watcher, strict SSH expectations, or' \
    '--require-dirty-survival retain their historical result status. Such a' \
    'success classifies the observed boot only; it never claims boot_b is clean.'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --image)
      [ "$#" -ge 2 ] || { echo "Missing value for --image" >&2; exit 2; }
      IMAGE="$2"
      shift
      ;;
    --image-sha256)
      [ "$#" -ge 2 ] || { echo "Missing value for --image-sha256" >&2; exit 2; }
      IMAGE_EXPECTED_SHA256="${2,,}"
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
    --restore-boot-b-sha256)
      [ "$#" -ge 2 ] || { echo "Missing value for --restore-boot-b-sha256" >&2; exit 2; }
      RESTORE_IMAGE_EXPECTED_SHA256="${2,,}"
      shift
      ;;
    --dual-partition-transaction)
      DUAL_PARTITION_TRANSACTION=1
      ;;
    --candidate-dtbo-b)
      [ "$#" -ge 2 ] || { echo "Missing value for --candidate-dtbo-b" >&2; exit 2; }
      CANDIDATE_DTBO_IMAGE="$2"
      shift
      ;;
    --candidate-dtbo-b-sha256)
      [ "$#" -ge 2 ] || { echo "Missing value for --candidate-dtbo-b-sha256" >&2; exit 2; }
      CANDIDATE_DTBO_EXPECTED_SHA256="${2,,}"
      shift
      ;;
    --restore-dtbo-b)
      [ "$#" -ge 2 ] || { echo "Missing value for --restore-dtbo-b" >&2; exit 2; }
      RESTORE_DTBO_IMAGE="$2"
      shift
      ;;
    --restore-dtbo-b-sha256)
      [ "$#" -ge 2 ] || { echo "Missing value for --restore-dtbo-b-sha256" >&2; exit 2; }
      RESTORE_DTBO_EXPECTED_SHA256="${2,,}"
      shift
      ;;
    --reboot-helper)
      [ "$#" -ge 2 ] || { echo "Missing value for --reboot-helper" >&2; exit 2; }
      REBOOT_HELPER="$2"
      shift
      ;;
    --reboot-helper-sha256)
      [ "$#" -ge 2 ] || { echo "Missing value for --reboot-helper-sha256" >&2; exit 2; }
      REBOOT_HELPER_EXPECTED_SHA256="${2,,}"
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
    --expect-kernel-prefix)
      [ "$#" -ge 2 ] || { echo "Missing value for --expect-kernel-prefix" >&2; exit 2; }
      EXPECT_KERNEL_PREFIX="$2"
      [ -n "$EXPECT_KERNEL_PREFIX" ] || { echo "--expect-kernel-prefix must not be empty" >&2; exit 2; }
      shift
      ;;
    --expect-cmdline-token)
      [ "$#" -ge 2 ] || { echo "Missing value for --expect-cmdline-token" >&2; exit 2; }
      [ -n "$2" ] || { echo "--expect-cmdline-token must not be empty" >&2; exit 2; }
      EXPECT_CMDLINE_TOKENS+=("$2")
      shift
      ;;
    --expect-source-kernel-prefix)
      [ "$#" -ge 2 ] || { echo "Missing value for --expect-source-kernel-prefix" >&2; exit 2; }
      EXPECT_SOURCE_KERNEL_PREFIX="$2"
      [ -n "$EXPECT_SOURCE_KERNEL_PREFIX" ] || { echo "--expect-source-kernel-prefix must not be empty" >&2; exit 2; }
      shift
      ;;
    --expect-source-cmdline-token)
      [ "$#" -ge 2 ] || { echo "Missing value for --expect-source-cmdline-token" >&2; exit 2; }
      [ -n "$2" ] || { echo "--expect-source-cmdline-token must not be empty" >&2; exit 2; }
      EXPECT_SOURCE_CMDLINE_TOKENS+=("$2")
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
    --fastboot-timeout)
      [ "$#" -ge 2 ] || { echo "Missing value for --fastboot-timeout" >&2; exit 2; }
      FASTBOOT_CMD_TIMEOUT_SEC="$2"
      shift
      ;;
    --start-rescue-watcher)
      START_RESCUE_WATCHER=1
      ;;
    --require-dirty-survival)
      REQUIRE_DIRTY_SURVIVAL=1
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
  local status=$?

  [ "${CLEANUP_RUNNING:-0}" -eq 0 ] || return "$status"
  CLEANUP_RUNNING=1
  trap - ERR INT TERM EXIT

  if [[ "${ACTIVE_TRANSPORT_PID:-}" =~ ^[0-9]+$ ]]; then
    log "Terminating active transport group during cleanup: $ACTIVE_TRANSPORT_PID"
    terminate_transport_group "$ACTIVE_TRANSPORT_PID"
  fi

  if rescue_watcher_must_survive; then
    KEEP_RESCUE_WATCHER=1
    if ! ensure_rescue_watcher_alive "cleanup after possible boot_b write"; then
      log "CRITICAL: boot_b may be dirty and the rescue watcher could not be rearmed"
    fi
  fi

  if [ "${KEEP_RESCUE_WATCHER:-0}" -eq 0 ]; then
    stop_rescue_watcher || true
  elif rescue_watcher_alive; then
    log "Leaving companion rescue watcher pair running: PIDs ${RESCUE_WATCHER_PIDS[*]}"
  else
    log "CRITICAL: requested rescue watcher preservation, but no live watcher is available"
  fi
  phone_lock_release || true
  return "$status"
}
trap cleanup EXIT

on_signal() {
  local signal_name="$1"
  local status="$2"

  if rescue_watcher_must_survive; then
    KEEP_RESCUE_WATCHER=1
  fi
  log "Interrupted by $signal_name"
  exit "$status"
}

on_err() {
  local status=$?
  local line="$1"
  local command="$2"

  if rescue_watcher_must_survive; then
    KEEP_RESCUE_WATCHER=1
  fi
  log "ERROR: command failed near line $line: $command (exit $status)"
  return "$status"
}

trap 'on_signal INT 130' INT
trap 'on_signal TERM 143' TERM
trap 'on_err "$LINENO" "$BASH_COMMAND"' ERR

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

random_hex_256() {
  od -An -N32 -tx1 /dev/urandom | tr -d '[:space:]'
}

process_starttime() {
  local pid="$1"
  local stat_line=""
  local remainder=""
  local -a fields=()

  [ -r "/proc/$pid/stat" ] || return 1
  stat_line="$(< "/proc/$pid/stat")"
  remainder="${stat_line##*) }"
  read -r -a fields <<< "$remainder"
  [ "${#fields[@]}" -ge 20 ] || return 1
  printf '%s\n' "${fields[19]}"
}

process_cmdline_has_token() {
  local pid="$1"
  local expected="$2"
  local token=""

  [ -r "/proc/$pid/cmdline" ] || return 1
  while IFS= read -r -d '' token; do
    [ "$token" = "$expected" ] && return 0
  done < "/proc/$pid/cmdline"
  return 1
}

watcher_ready_expected() {
  local index="$1"

  if [ "$DUAL_PARTITION_TRANSACTION" -eq 1 ]; then
    printf 'contract_version=3\n'
  else
    printf 'contract_version=2\n'
  fi
  printf 'pid=%s\n' "${RESCUE_WATCHER_PIDS[$index]}"
  printf 'starttime=%s\n' "${RESCUE_WATCHER_STARTTIMES[$index]}"
  printf 'serial=%s\n' "$SERIAL"
  printf 'restore_image=%s\n' "$RESTORE_IMAGE"
  printf 'restore_sha256=%s\n' "$RESTORE_IMAGE_SHA256"
  if [ "$DUAL_PARTITION_TRANSACTION" -eq 1 ]; then
    printf 'boot_b_only=0\n'
    printf 'dual_partition=1\n'
    printf 'restore_dtbo_image=%s\n' "$RESTORE_DTBO_IMAGE"
    printf 'restore_dtbo_sha256=%s\n' "$RESTORE_DTBO_EXPECTED_SHA256"
    printf 'restore_complete_file=%s\n' "$RESTORE_COMPLETE_FILE"
  else
    printf 'boot_b_only=1\n'
    printf 'restore_dtbo_image=none\n'
    printf 'restore_dtbo_sha256=none\n'
  fi
  printf 'nonce=%s\n' "${RESCUE_WATCHER_NONCES[$index]}"
  printf 'watcher_script=%s\n' "${RESCUE_WATCHER_SCRIPT_PATHS[$index]}"
  printf 'challenge_file=%s\n' "${RESCUE_WATCHER_CHALLENGE_FILES[$index]}"
  printf 'ack_file=%s\n' "${RESCUE_WATCHER_ACK_FILES[$index]}"
}

rescue_watcher_process_identity_valid() {
  local index="$1"
  local actual_starttime=""
  local pid="${RESCUE_WATCHER_PIDS[$index]:-}"

  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  [[ "${RESCUE_WATCHER_STARTTIMES[$index]}" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  actual_starttime="$(process_starttime "$pid")" || return 1
  [ "$actual_starttime" = "${RESCUE_WATCHER_STARTTIMES[$index]}" ] || return 1
  process_cmdline_has_token "$pid" "${RESCUE_WATCHER_SCRIPT_PATHS[$index]}" || return 1
  process_cmdline_has_token "$pid" --contract-nonce || return 1
  process_cmdline_has_token "$pid" "${RESCUE_WATCHER_NONCES[$index]}" || return 1
  process_cmdline_has_token "$pid" --serial || return 1
  process_cmdline_has_token "$pid" "$SERIAL" || return 1
  process_cmdline_has_token "$pid" --restore-boot-b || return 1
  process_cmdline_has_token "$pid" "$RESTORE_IMAGE" || return 1
  process_cmdline_has_token "$pid" --restore-boot-b-sha256 || return 1
  process_cmdline_has_token "$pid" "$RESTORE_IMAGE_SHA256" || return 1
  if [ "$DUAL_PARTITION_TRANSACTION" -eq 1 ]; then
    process_cmdline_has_token "$pid" --dual-partition || return 1
    ! process_cmdline_has_token "$pid" --boot-b-only || return 1
    process_cmdline_has_token "$pid" --restore-dtbo-b || return 1
    process_cmdline_has_token "$pid" "$RESTORE_DTBO_IMAGE" || return 1
    process_cmdline_has_token "$pid" --restore-dtbo-b-sha256 || return 1
    process_cmdline_has_token "$pid" "$RESTORE_DTBO_EXPECTED_SHA256" || return 1
    process_cmdline_has_token "$pid" --restore-complete-file || return 1
    process_cmdline_has_token "$pid" "$RESTORE_COMPLETE_FILE" || return 1
  else
    process_cmdline_has_token "$pid" --boot-b-only || return 1
    ! process_cmdline_has_token "$pid" --restore-dtbo-b || return 1
    ! process_cmdline_has_token "$pid" --dual-partition || return 1
  fi
  process_cmdline_has_token "$pid" --ready-file || return 1
  process_cmdline_has_token "$pid" "${RESCUE_WATCHER_READY_FILES[$index]}" || return 1
  process_cmdline_has_token "$pid" --contract-challenge-file || return 1
  process_cmdline_has_token "$pid" "${RESCUE_WATCHER_CHALLENGE_FILES[$index]}" || return 1
  process_cmdline_has_token "$pid" --contract-ack-file || return 1
  process_cmdline_has_token "$pid" "${RESCUE_WATCHER_ACK_FILES[$index]}" || return 1
}

rescue_watcher_contract_static_valid() {
  local index="$1"
  local actual=""
  local expected=""
  local ready_file="${RESCUE_WATCHER_READY_FILES[$index]}"

  [ -r "$ready_file" ] || return 1
  rescue_watcher_process_identity_valid "$index" || return 1
  actual="$(< "$ready_file")"
  expected="$(watcher_ready_expected "$index")"
  [ "$actual" = "$expected" ]
}

challenge_rescue_watcher() {
  local index="$1"
  local challenge=""
  local challenge_tmp=""
  local expected_ack=""
  local actual_ack=""
  local deadline=0
  local pid="${RESCUE_WATCHER_PIDS[$index]}"
  local starttime="${RESCUE_WATCHER_STARTTIMES[$index]}"
  local nonce="${RESCUE_WATCHER_NONCES[$index]}"
  local challenge_file="${RESCUE_WATCHER_CHALLENGE_FILES[$index]}"
  local ack_file="${RESCUE_WATCHER_ACK_FILES[$index]}"

  rescue_watcher_contract_static_valid "$index" || return 1
  challenge="$(random_hex_256)"
  [[ "$challenge" =~ ^[0-9a-f]{64}$ ]] || return 1
  challenge_tmp="$challenge_file.$$.tmp"
  rm -f "$ack_file"
  umask 077
  {
    printf 'contract_version=%s\n' "$([ "$DUAL_PARTITION_TRANSACTION" -eq 1 ] && printf 3 || printf 2)"
    printf 'nonce=%s\n' "$nonce"
    printf 'challenge=%s\n' "$challenge"
  } > "$challenge_tmp" || return 1
  mv -f "$challenge_tmp" "$challenge_file" || return 1
  kill -USR1 "$pid" 2>/dev/null || return 1

  expected_ack="$(printf 'contract_version=%s\npid=%s\nstarttime=%s\nnonce=%s\nchallenge=%s\n' \
    "$([ "$DUAL_PARTITION_TRANSACTION" -eq 1 ] && printf 3 || printf 2)" "$pid" "$starttime" "$nonce" "$challenge")"
  deadline=$((SECONDS + 20))
  while [ "$SECONDS" -lt "$deadline" ]; do
    rescue_watcher_contract_static_valid "$index" || return 1
    if [ -r "$ack_file" ]; then
      actual_ack="$(< "$ack_file")"
      if [ "$actual_ack" = "$expected_ack" ]; then
        rescue_watcher_contract_static_valid "$index"
        return
      fi
    fi
    sleep 0.01
  done
  return 1
}

rescue_watcher_pair_static_valid() {
  [ "${RESCUE_WATCHER_PIDS[0]}" != "${RESCUE_WATCHER_PIDS[1]}" ] &&
    [ "${RESCUE_WATCHER_NONCES[0]}" != "${RESCUE_WATCHER_NONCES[1]}" ] &&
    [ "${RESCUE_WATCHER_READY_FILES[0]}" != "${RESCUE_WATCHER_READY_FILES[1]}" ] &&
    [ "${RESCUE_WATCHER_CHALLENGE_FILES[0]}" != "${RESCUE_WATCHER_CHALLENGE_FILES[1]}" ] &&
    [ "${RESCUE_WATCHER_ACK_FILES[0]}" != "${RESCUE_WATCHER_ACK_FILES[1]}" ] &&
    rescue_watcher_contract_static_valid 0 && rescue_watcher_contract_static_valid 1
}

challenge_rescue_watcher_pair() {
  challenge_rescue_watcher 0 || return
  challenge_rescue_watcher 1 || return
  rescue_watcher_pair_static_valid
}

start_rescue_watcher_instance() {
  local index="$1"
  local number=$((index + 1))
  local wrapper_log="$run_dir/companion-rescue-watcher-$number.log"
  local wrapper_err="$run_dir/companion-rescue-watcher-$number.err"
  local pidfile="$run_dir/companion-rescue-watcher-$number.pid"
  local ready_file="$run_dir/companion-rescue-watcher-$number.ready"
  local challenge_file="$run_dir/companion-rescue-watcher-$number.challenge"
  local ack_file="$run_dir/companion-rescue-watcher-$number.ack"
  local nonce=""
  local script_path=""
  local pid=""
  local -a scope_args=(--boot-b-only)

  [ "$START_RESCUE_WATCHER" -eq 1 ] || return 0
  rescue_watcher_contract_static_valid "$index" && return 0
  RESCUE_WATCHER_PIDS[$index]=""
  RESCUE_WATCHER_STARTTIMES[$index]=""
  [ -n "$SERIAL" ] || { log "ERROR: rescue watcher requires a serial"; return 2; }
  [ -n "$RESTORE_IMAGE" ] || { log "ERROR: rescue watcher requires a restore image"; return 2; }
  [ -s "$RESTORE_IMAGE" ] || { log "ERROR: rescue watcher restore image is missing: $RESTORE_IMAGE"; return 2; }
  [ -x "$RESCUE_WATCHER_HELPER" ] || { log "ERROR: rescue watcher helper is not executable: $RESCUE_WATCHER_HELPER"; return 2; }
  nonce="$(random_hex_256)"
  script_path="$(readlink -f "$RESCUE_WATCHER_HELPER")"
  [[ "$nonce" =~ ^[0-9a-f]{64}$ ]] || { log "ERROR: could not generate watcher nonce"; return 3; }
  [ -n "$script_path" ] || { log "ERROR: could not resolve watcher script"; return 3; }
  RESCUE_WATCHER_READY_FILES[$index]="$ready_file"
  RESCUE_WATCHER_CHALLENGE_FILES[$index]="$challenge_file"
  RESCUE_WATCHER_ACK_FILES[$index]="$ack_file"
  RESCUE_WATCHER_NONCES[$index]="$nonce"
  RESCUE_WATCHER_SCRIPT_PATHS[$index]="$script_path"
  if [ "$DUAL_PARTITION_TRANSACTION" -eq 1 ]; then
    scope_args=(
      --dual-partition
      --restore-dtbo-b "$RESTORE_DTBO_IMAGE"
      --restore-dtbo-b-sha256 "$RESTORE_DTBO_EXPECTED_SHA256"
      --restore-complete-file "$RESTORE_COMPLETE_FILE"
    )
  fi
  rm -f "$pidfile" "$ready_file" "$challenge_file" "$ack_file"

  log "Starting companion rescue watcher $number/2 for $SERIAL"
  if [ "${HOTDOG_FORCE_RESCUE_FALLBACK:-0}" -ne 1 ] && command -v start-stop-daemon >/dev/null 2>&1; then
    (
      phone_lock_prepare_detached_child
      exec start-stop-daemon --start --background --make-pidfile --pidfile "$pidfile" \
        --chdir "$HOTDOG_ROOT" \
        --env HOTDOG_RESCUE_LOG_TEE=0 \
        --stdout "$wrapper_log" --stderr "$wrapper_err" \
        --exec "$RESCUE_WATCHER_HELPER" -- \
        --serial "$SERIAL" \
        --restore-boot-b "$RESTORE_IMAGE" \
        --restore-boot-b-sha256 "$RESTORE_IMAGE_SHA256" \
        "${scope_args[@]}" \
        --after-restore "$RESTORE_AFTER_FASTBOOT" \
        --timeout "$RESCUE_WATCHER_TIMEOUT_SEC" \
        --poll "$RESCUE_WATCHER_POLL_SEC" \
        --ready-file "$ready_file" \
        --contract-nonce "$nonce" \
        --contract-challenge-file "$challenge_file" \
        --contract-ack-file "$ack_file"
    ) || return 3
  else
    (
      phone_lock_prepare_detached_child
      exec setsid env HOTDOG_RESCUE_LOG_TEE=0 "$RESCUE_WATCHER_HELPER" \
        --serial "$SERIAL" \
        --restore-boot-b "$RESTORE_IMAGE" \
        --restore-boot-b-sha256 "$RESTORE_IMAGE_SHA256" \
        "${scope_args[@]}" \
        --after-restore "$RESTORE_AFTER_FASTBOOT" \
        --timeout "$RESCUE_WATCHER_TIMEOUT_SEC" \
        --poll "$RESCUE_WATCHER_POLL_SEC" \
        --ready-file "$ready_file" \
        --contract-nonce "$nonce" \
        --contract-challenge-file "$challenge_file" \
        --contract-ack-file "$ack_file"
    ) > "$wrapper_log" 2> "$wrapper_err" < /dev/null &
    pid="$!"
    RESCUE_WATCHER_PIDS[$index]="$pid"
    printf '%s\n' "$pid" > "$pidfile"
  fi

  for _ in {1..50}; do
    [ -s "$pidfile" ] && break
    sleep 0.1
  done
  [ -s "$pidfile" ] || { log "ERROR: companion rescue watcher did not publish a PID file"; return 3; }
  pid="$(sed -n '1p' "$pidfile")"
  case "$pid" in
    ''|*[!0-9]*) log "ERROR: companion rescue watcher $number published an invalid PID: $pid"; return 3 ;;
  esac
  RESCUE_WATCHER_PIDS[$index]="$pid"
  log "Companion rescue watcher $number PID: $pid"
  wait_for_rescue_watcher_ready "$index" "$ready_file" "$wrapper_log" "$wrapper_err"
}

start_rescue_watcher() {
  local index=0

  [ "$START_RESCUE_WATCHER" -eq 1 ] || return 0
  for index in 0 1; do
    if ! start_rescue_watcher_instance "$index"; then
      stop_rescue_watcher || true
      return 3
    fi
  done
  challenge_rescue_watcher_pair
}

rescue_watcher_alive() {
  rescue_watcher_pair_static_valid
}

rescue_watcher_must_survive() {
  [ "${REQUIRE_DIRTY_SURVIVAL:-0}" -eq 1 ] &&
    { [ "${BOOT_B_MAY_BE_DIRTY:-0}" -eq 1 ] || [ "${DTBO_B_MAY_BE_DIRTY:-0}" -eq 1 ]; } &&
    [ "${RESTORE_READBACK_VERIFIED:-0}" -eq 0 ] &&
    [ "${STRICT_MAINLINE_SUCCESS_ACKED:-0}" -eq 0 ]
}

ensure_rescue_watcher_alive() {
  local context="$1"
  local index=0

  if [ "$START_RESCUE_WATCHER" -ne 1 ]; then
    if rescue_watcher_must_survive; then
      log "ERROR: rescue watcher is required but disabled: $context"
      return 3
    fi
    return 0
  fi
  for index in 0 1; do
    if rescue_watcher_contract_static_valid "$index"; then
      if challenge_rescue_watcher "$index"; then
        continue
      fi
      if rescue_watcher_contract_static_valid "$index"; then
        log "ERROR: rescue watcher $((index + 1)) exists but did not ACK during $context"
        return 3
      fi
      log "Rescue watcher $((index + 1)) died during contract challenge in $context; rearming"
    fi
    log "Rescue watcher $((index + 1)) is not alive during $context; rearming"
    RESCUE_WATCHER_PIDS[$index]=""
    start_rescue_watcher_instance "$index" || return
  done
  challenge_rescue_watcher_pair || {
    log "ERROR: rescue watcher pair failed its final attestation during $context"
    return 3
  }
}

wait_for_rescue_watcher_ready() {
  local index="$1"
  local ready_file="$2"
  local wrapper_log="$3"
  local wrapper_err="$4"
  local deadline=$((SECONDS + RESCUE_WATCHER_READY_TIMEOUT_SEC))
  local starttime=""
  local pid="${RESCUE_WATCHER_PIDS[$index]}"

  while [ "$SECONDS" -lt "$deadline" ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      [ -s "$wrapper_err" ] && sed 's/^/[rescue-watcher] /' "$wrapper_err" >&2 || true
      log "ERROR: companion rescue watcher exited before reporting readiness"
      return 3
    fi
    if [ -s "$ready_file" ]; then
      starttime="$(sed -n '3s/^starttime=//p' "$ready_file")"
      if [[ "$starttime" =~ ^[0-9]+$ ]]; then
        RESCUE_WATCHER_STARTTIMES[$index]="$starttime"
        if rescue_watcher_contract_static_valid "$index" && challenge_rescue_watcher "$index"; then
          log "Companion rescue watcher $((index + 1)) readiness and challenge ACK confirmed"
          return 0
        fi
      fi
    fi
    sleep 0.1
  done

  [ -s "$wrapper_log" ] && sed 's/^/[rescue-watcher] /' "$wrapper_log" >&2 || true
  [ -s "$wrapper_err" ] && sed 's/^/[rescue-watcher] /' "$wrapper_err" >&2 || true
  log "ERROR: timed out waiting for companion rescue watcher readiness"
  return 3
}

stop_rescue_watcher() {
  local index=0
  local pid=""

  for index in 0 1; do
    pid="${RESCUE_WATCHER_PIDS[$index]:-}"
    if [ -n "$pid" ] && rescue_watcher_process_identity_valid "$index"; then
      log "Stopping companion rescue watcher $((index + 1)): PID $pid"
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
    RESCUE_WATCHER_PIDS[$index]=""
    RESCUE_WATCHER_STARTTIMES[$index]=""
    RESCUE_WATCHER_NONCES[$index]=""
  done
}

transport_process_running() {
  local pid="$1"
  local stat_line=""
  local remainder=""
  local state=""

  [ -r "/proc/$pid/stat" ] || return 1
  stat_line="$(< "/proc/$pid/stat")"
  remainder="${stat_line##*) }"
  state="${remainder%% *}"
  [ "$state" != "Z" ]
}

terminate_transport_group() {
  local pid="$1"

  kill -TERM -- "-$pid" 2>/dev/null || true
  sleep 0.05
  kill -KILL -- "-$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ "${ACTIVE_TRANSPORT_PID:-}" != "$pid" ] || ACTIVE_TRANSPORT_PID=""
}

run_guarded_transport() {
  local label="$1"
  local output="$2"
  local transport_pid=""
  local status=0
  shift 2

  ensure_rescue_watcher_alive "before $label" || return 3
  setsid --wait "$@" > "$output" 2>&1 &
  transport_pid="$!"
  ACTIVE_TRANSPORT_PID="$transport_pid"
  while transport_process_running "$transport_pid"; do
    if ! rescue_watcher_pair_static_valid; then
      log "ERROR: rescue pair degraded during $label; terminating transport"
      terminate_transport_group "$transport_pid"
      ensure_rescue_watcher_alive "rearm after interrupted $label" || true
      [ -s "$output" ] && sed 's/^/[transport] /' "$output" >&2 || true
      return 3
    fi
    sleep 0.01
  done
  if wait "$transport_pid"; then
    status=0
  else
    status=$?
  fi
  ACTIVE_TRANSPORT_PID=""
  [ -s "$output" ] && sed 's/^/[transport] /' "$output" || true
  ensure_rescue_watcher_alive "after $label" || return 3
  return "$status"
}

run_guarded_fastboot_transport() {
  local label="$1"
  local output="$2"
  shift 2
  run_guarded_transport "$label" "$output" fastboot -s "$SERIAL" "$@"
}

normalize_value() {
  local value="$1"
  value="${value,,}"
  value="${value//[[:space:]]/}"
  value="${value#_}"
  printf '%s\n' "$value"
}

normalize_serial_value() {
  local value="$1"

  value="${value//[[:space:]]/}"
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
  hotdog_fastboot_devices > "$run_dir/fastboot-devices-last.txt" 2>&1 || true
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
  local selected_serial=""
  local unlocked=""
  local expected_product=""
  local product_ok=1

  serialno="$(normalize_serial_value "$(get_fastboot_var serialno)")"
  selected_serial="$(normalize_serial_value "$SERIAL")"
  product="$(normalize_value "$(get_fastboot_var product)")"
  unlocked="$(normalize_value "$(get_fastboot_var unlocked)")"

  [ -n "$SERIAL" ] || die "Internal error: SERIAL is empty after wait_for_fastboot" 2

  [ -n "$serialno" ] || die "Fastboot getvar serialno is empty; refusing write-capable operation" 2
  [ "$serialno" = "$selected_serial" ] ||
    die "Fastboot serial mismatch: selected $SERIAL but getvar serialno reports $serialno" 2

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

parse_fastboot_size() {
  local value="$1"
  local hex=""

  value="${value,,}"
  value="${value//[[:space:]]/}"
  case "$value" in
    0x[0-9a-f]*)
      hex="${value#0x}"
      [[ "$hex" =~ ^[0-9a-f]+$ ]] || return 1
      printf '%s\n' "$((16#$hex))"
      ;;
    [0-9]*)
      [[ "$value" =~ ^[0-9]+$ ]] || return 1
      printf '%s\n' "$((10#$value))"
      ;;
    *) return 1 ;;
  esac
}

validate_fastboot_restore_context() {
  local restore_file="$1"
  local partition_label="${2:-boot_b}"
  local slot_base=""
  local current_slot=""
  local has_slot=""
  local is_userspace=""
  local partition_size_raw=""
  local partition_size=""
  local restore_size=""
  local unlocked=""

  case "$partition_label" in
    boot_b|dtbo_b) slot_base="${partition_label%_b}" ;;
    *) die "Unsupported partition context: $partition_label" 2 ;;
  esac
  [ -n "$EXPECTED_FASTBOOT_PRODUCTS" ] ||
    die "Expected fastboot product list is empty; refusing $partition_label access" 2
  validate_fastboot_identity
  unlocked="$(normalize_value "$(get_fastboot_var unlocked)")"
  case "$unlocked" in
    yes|true|1|unlocked) ;;
    *) die "$partition_label access requires an unlocked bootloader (got ${unlocked:-missing})" 2 ;;
  esac

  is_userspace="$(normalize_value "$(get_fastboot_var is-userspace)")"
  case "$is_userspace" in
    no|false|0) ;;
    yes|true|1) die "fastbootd/userspace detected; refusing $partition_label access" 2 ;;
    *) die "Could not prove bootloader fastboot context (is-userspace=${is_userspace:-missing})" 2 ;;
  esac

  current_slot="$(normalize_value "$(get_fastboot_var current-slot)")"
  case "$current_slot" in
    a|b) ;;
    *) die "Invalid or missing current-slot before boot_b restore: ${current_slot:-missing}" 2 ;;
  esac

  has_slot="$(normalize_value "$(get_fastboot_var "has-slot:$slot_base")")"
  case "$has_slot" in
    yes|true|1) ;;
    *) die "Fastboot does not attest that $slot_base is slotted (has-slot:$slot_base=${has_slot:-missing})" 2 ;;
  esac

  partition_size_raw="$(get_fastboot_var "partition-size:$partition_label")"
  partition_size="$(parse_fastboot_size "$partition_size_raw")" ||
    die "Invalid or missing partition-size:$partition_label: ${partition_size_raw:-missing}" 2
  restore_size="$(stat -c '%s' "$restore_file")"
  [ "$partition_size" -ge "$restore_size" ] ||
    die "$partition_label partition is too small: $partition_size bytes < image $restore_size bytes" 2

  log "Fastboot context OK: serial=$SERIAL slot=$current_slot partition=$partition_label size=$partition_size"
}

ensure_bootloader_fastboot() {
  local is_userspace=""
  local watcher_guard=0

  if [ "$START_RESCUE_WATCHER" -eq 1 ] || [ "$REQUIRE_DIRTY_SURVIVAL" -eq 1 ]; then
    watcher_guard=1
  fi

  is_userspace="$(normalize_value "$(get_fastboot_var is-userspace)")"
  case "$is_userspace" in
    yes|true|1)
      log "fastbootd detected; rebooting to bootloader"
      if [ "$watcher_guard" -eq 1 ]; then
        ensure_rescue_watcher_alive "before fastbootd bootloader handoff" ||
          die "Companion rescue watcher is unavailable before fastbootd handoff" 3
        KEEP_RESCUE_WATCHER=1
        if ! run_guarded_fastboot_transport "fastbootd bootloader reboot" \
          "$run_dir/fastboot-reboot-bootloader.txt" reboot bootloader; then
          ensure_rescue_watcher_alive "after interrupted fastbootd bootloader handoff" || true
          die "Fastbootd bootloader handoff lost its rescue quorum or failed" 3
        fi
        ensure_rescue_watcher_alive "after fastbootd bootloader reboot dispatch" ||
          die "Companion rescue watcher could not be reattested after fastbootd handoff" 3
      else
        fastboot_do reboot bootloader > "$run_dir/fastboot-reboot-bootloader.txt" 2>&1 ||
          die "Failed to reboot bootloader from fastbootd" 3
      fi
      sleep 5
      wait_for_fastboot 60
      if [ "$watcher_guard" -eq 1 ]; then
        ensure_rescue_watcher_alive "after bootloader fastboot returned" ||
          die "Companion rescue watcher could not be reattested in bootloader fastboot" 3
        KEEP_RESCUE_WATCHER=0
      fi
      ;;
    *)
      log "Bootloader fastboot confirmed"
      ;;
  esac
}

pmos_probe_field() {
  local field="$1"
  local file="$2"

  awk -v field="$field" '
    index($0, field "=") == 1 {
      sub("^[^=]*=", "", $0)
      gsub(/\r/, "", $0)
      print
      exit
    }
  ' "$file"
}

pmos_ssh_probe() {
  local label="${1:-after}"
  local output="$run_dir/ssh-probe.txt"

  if [ "$label" != "after" ]; then
    output="$run_dir/ssh-probe-$label.txt"
  fi

  ping -c 1 -W 1 "$PMOS_HOST" > "$run_dir/ping-last-$PMOS_HOST.txt" 2>&1 || return 1
  sshpass -p "$PMOS_PASSWORD" ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile="$run_dir/known_hosts" \
    -o ConnectTimeout=5 \
    -o PreferredAuthentications=password \
    -o PubkeyAuthentication=no \
    "$PMOS_USER@$PMOS_HOST" '
      printf "PMOS_SSH_OK\n"
      printf "PMOS_BOOT_ID="
      cat /proc/sys/kernel/random/boot_id 2>/dev/null || true
      printf "\nPMOS_UNAME_R="
      uname -r 2>/dev/null || true
      printf "\nPMOS_CMDLINE="
      cat /proc/cmdline 2>/dev/null || true
      printf "\n"
    ' > "$output" 2>&1 || return 1

  grep -qx 'PMOS_SSH_OK' "$output" || return 1
  PMOS_PROBE_BOOT_ID="$(pmos_probe_field PMOS_BOOT_ID "$output")"
  PMOS_PROBE_KERNEL="$(pmos_probe_field PMOS_UNAME_R "$output")"
  PMOS_PROBE_CMDLINE="$(pmos_probe_field PMOS_CMDLINE "$output")"
  [ -n "$PMOS_PROBE_BOOT_ID" ] || return 1
  [ -n "$PMOS_PROBE_KERNEL" ] || return 1
  [ -n "$PMOS_PROBE_CMDLINE" ] || return 1

  printf '%s\n' "$PMOS_PROBE_BOOT_ID" > "$run_dir/pmos-boot-id-$label.txt"
  printf '%s\n' "$PMOS_PROBE_KERNEL" > "$run_dir/pmos-uname-r-$label.txt"
  printf '%s\n' "$PMOS_PROBE_CMDLINE" > "$run_dir/pmos-cmdline-$label.txt"
}

pmos_remote_quote() {
  local value="$1"

  printf "'%s'" "${value//\'/\'\\\'\'}"
}

pmos_ssh_probe_and_ack_strict() {
  local output="$run_dir/ssh-probe.txt"
  local expected_tokens=""
  local ack_nonce=""
  local ack_value=""
  local ssh_status=0
  local identity_ok=1
  local token=""

  PMOS_PROBE_ATOMIC_ACKED=0
  [ "$STRICT_SSH_EXPECTATION" -eq 1 ] || return 1
  if [ "${#EXPECT_CMDLINE_TOKENS[@]}" -gt 0 ]; then
    printf -v expected_tokens '%s\n' "${EXPECT_CMDLINE_TOKENS[@]}"
    expected_tokens="${expected_tokens%$'\n'}"
  fi
  ack_nonce="$(random_hex_256)"
  [[ "$ack_nonce" =~ ^[0-9a-f]{64}$ ]] || return 1

  ping -c 1 -W 1 "$PMOS_HOST" > "$run_dir/ping-last-$PMOS_HOST.txt" 2>&1 || return 1
  sshpass -p "$PMOS_PASSWORD" ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile="$run_dir/known_hosts" \
    -o ConnectTimeout=5 \
    -o PreferredAuthentications=password \
    -o PubkeyAuthentication=no \
    "$PMOS_USER@$PMOS_HOST" \
    "HOTDOG_ATOMIC_IDENTITY_ACK=1 EXPECTED_OLD_BOOT_ID=$(pmos_remote_quote "$PMOS_BOOT_ID_BEFORE") EXPECTED_KERNEL_PREFIX=$(pmos_remote_quote "$EXPECT_KERNEL_PREFIX") EXPECTED_CMDLINE_TOKENS=$(pmos_remote_quote "$expected_tokens") ACK_NONCE=$(pmos_remote_quote "$ack_nonce") sh -s" \
    > "$output" 2>&1 <<'REMOTE_STRICT_ACK' || ssh_status=$?
set -eu

old_boot_id="${EXPECTED_OLD_BOOT_ID:-}"
expected_kernel_prefix="${EXPECTED_KERNEL_PREFIX:-}"
expected_cmdline_tokens="${EXPECTED_CMDLINE_TOKENS:-}"
ack_nonce="${ACK_NONCE:?}"
ack_file=/tmp/hotdog_rescue_watchdog.ok
ack_tmp="$ack_file.$$.tmp"
boot_id="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)"
kernel="$(uname -r 2>/dev/null || true)"
cmdline="$(cat /proc/cmdline 2>/dev/null || true)"

printf 'PMOS_SSH_OK\n'
printf 'PMOS_BOOT_ID=%s\n' "$boot_id"
printf 'PMOS_UNAME_R=%s\n' "$kernel"
printf 'PMOS_CMDLINE=%s\n' "$cmdline"

[ -n "$boot_id" ] || exit 10
[ -n "$kernel" ] || exit 10
[ -n "$cmdline" ] || exit 10
if [ -n "$old_boot_id" ]; then
  [ "$boot_id" != "$old_boot_id" ] || exit 11
fi
if [ -n "$expected_kernel_prefix" ]; then
  case "$kernel" in
    "$expected_kernel_prefix"*) ;;
    *) exit 12 ;;
  esac
fi

old_ifs=$IFS
IFS='
'
for identity_token in $expected_cmdline_tokens; do
  [ -n "$identity_token" ] || continue
  case " $cmdline " in
    *" $identity_token "*) ;;
    *) exit 13 ;;
  esac
done
IFS=$old_ifs

umask 077
printf '%s\n' "$ack_nonce" > "$ack_tmp"
mv -f "$ack_tmp" "$ack_file"
ack_readback="$(cat "$ack_file" 2>/dev/null || true)"
[ "$ack_readback" = "$ack_nonce" ] || exit 14
printf 'PMOS_WATCHDOG_ACK=%s\n' "$ack_readback"
printf 'HOTDOG_ATOMIC_IDENTITY_ACK=ok\n'
REMOTE_STRICT_ACK

  grep -qx 'PMOS_SSH_OK' "$output" || return 1
  PMOS_PROBE_BOOT_ID="$(pmos_probe_field PMOS_BOOT_ID "$output")"
  PMOS_PROBE_KERNEL="$(pmos_probe_field PMOS_UNAME_R "$output")"
  PMOS_PROBE_CMDLINE="$(pmos_probe_field PMOS_CMDLINE "$output")"
  [ -n "$PMOS_PROBE_BOOT_ID" ] || return 1
  [ -n "$PMOS_PROBE_KERNEL" ] || return 1
  [ -n "$PMOS_PROBE_CMDLINE" ] || return 1

  printf '%s\n' "$PMOS_PROBE_BOOT_ID" > "$run_dir/pmos-boot-id-after.txt"
  printf '%s\n' "$PMOS_PROBE_KERNEL" > "$run_dir/pmos-uname-r-after.txt"
  printf '%s\n' "$PMOS_PROBE_CMDLINE" > "$run_dir/pmos-cmdline-after.txt"

  if [ -n "$PMOS_BOOT_ID_BEFORE" ] && [ "$PMOS_PROBE_BOOT_ID" = "$PMOS_BOOT_ID_BEFORE" ]; then
    identity_ok=0
  fi
  if [ -n "$EXPECT_KERNEL_PREFIX" ]; then
    case "$PMOS_PROBE_KERNEL" in
      "$EXPECT_KERNEL_PREFIX"*) ;;
      *) identity_ok=0 ;;
    esac
  fi
  for token in "${EXPECT_CMDLINE_TOKENS[@]}"; do
    cmdline_has_token "$PMOS_PROBE_CMDLINE" "$token" || identity_ok=0
  done
  ack_value="$(pmos_probe_field PMOS_WATCHDOG_ACK "$output")"
  if [ "$ssh_status" -eq 0 ] && [ "$identity_ok" -eq 1 ] &&
    [ "$ack_value" = "$ack_nonce" ] && grep -qx 'HOTDOG_ATOMIC_IDENTITY_ACK=ok' "$output"; then
    PMOS_PROBE_ATOMIC_ACKED=1
  fi
  return 0
}

cmdline_has_token() {
  local cmdline="$1"
  local token="$2"

  case " $cmdline " in
    *" $token "*) return 0 ;;
    *) return 1 ;;
  esac
}

run_source_ssh_writer() {
  local label="$1"
  local image="$2"
  local expected_sha="$3"
  local expected_boot_id="$4"
  local expected_kernel="$5"
  local reboot_after="$6"
  local output="$run_dir/flash-boot-b-from-pmos-ssh-$label.log"
  local token=""
  local -a args=(
    --image "$image"
    --image-sha256 "$expected_sha"
    --serial "$SERIAL"
    --host "$PMOS_HOST"
    --user "$PMOS_USER"
    --password "$PMOS_PASSWORD"
    --expected-source-boot-id "$expected_boot_id"
    --expected-source-kernel "$expected_kernel"
  )

  [ -x "$FLASH_BOOT_B_SSH_HELPER" ] || {
    log "ERROR: SSH boot_b writer is not executable: $FLASH_BOOT_B_SSH_HELPER"
    return 127
  }
  for token in "${EXPECT_SOURCE_CMDLINE_TOKENS[@]}"; do
    args+=(--expected-source-cmdline-token "$token")
  done
  if [ "${PHONE_LOCK_HELD:-0}" -eq 1 ] && [[ "${PHONE_LOCK_FD:-}" =~ ^[0-9]+$ ]]; then
    args+=(--phone-lock-fd "$PHONE_LOCK_FD")
  fi
  if [ "$REQUIRE_DIRTY_SURVIVAL" -eq 1 ]; then
    args+=(
      --require-watcher-contract
      --required-watcher-pid "${RESCUE_WATCHER_PIDS[0]}"
      --required-watcher-starttime "${RESCUE_WATCHER_STARTTIMES[0]}"
      --required-watcher-ready-file "${RESCUE_WATCHER_READY_FILES[0]}"
      --required-watcher-nonce "${RESCUE_WATCHER_NONCES[0]}"
      --required-watcher-script "${RESCUE_WATCHER_SCRIPT_PATHS[0]}"
      --required-watcher-restore-image "$RESTORE_IMAGE"
      --required-watcher-restore-sha256 "$RESTORE_IMAGE_SHA256"
      --required-watcher-challenge-file "${RESCUE_WATCHER_CHALLENGE_FILES[0]}"
      --required-watcher-ack-file "${RESCUE_WATCHER_ACK_FILES[0]}"
      --required-watcher2-pid "${RESCUE_WATCHER_PIDS[1]}"
      --required-watcher2-starttime "${RESCUE_WATCHER_STARTTIMES[1]}"
      --required-watcher2-ready-file "${RESCUE_WATCHER_READY_FILES[1]}"
      --required-watcher2-nonce "${RESCUE_WATCHER_NONCES[1]}"
      --required-watcher2-script "${RESCUE_WATCHER_SCRIPT_PATHS[1]}"
      --required-watcher2-restore-image "$RESTORE_IMAGE"
      --required-watcher2-restore-sha256 "$RESTORE_IMAGE_SHA256"
      --required-watcher2-challenge-file "${RESCUE_WATCHER_CHALLENGE_FILES[1]}"
      --required-watcher2-ack-file "${RESCUE_WATCHER_ACK_FILES[1]}"
    )
  fi
  if [ "$reboot_after" -eq 1 ]; then
    args+=(--reboot)
  fi

  if "$FLASH_BOOT_B_SSH_HELPER" "${args[@]}" > "$output" 2>&1; then
    sed 's/^/[flash-ssh] /' "$output" || true
    return 0
  fi
  sed 's/^/[flash-ssh] /' "$output" >&2 || true
  return 1
}

rollback_via_source_ssh_if_safe() {
  local reason="$1"
  local rollback_boot_id=""
  local rollback_kernel=""
  local rollback_cmdline=""
  local token=""

  [ "$START_FROM_PMOS_SSH" -eq 1 ] || return 1
  if [ "$DUAL_PARTITION_TRANSACTION" -eq 1 ]; then
    KEEP_RESCUE_WATCHER=1
    log "Source-SSH boot-only rollback is forbidden for a dual-partition transaction"
    return 1
  fi
  [ "$BOOT_B_MAY_BE_DIRTY" -eq 1 ] || return 0
  [ -n "$RESTORE_IMAGE" ] || return 1
  [ -n "$EXPECT_SOURCE_KERNEL_PREFIX" ] || {
    log "Rollback via SSH refused: no pinned source kernel prefix"
    return 1
  }
  [ "${#EXPECT_SOURCE_CMDLINE_TOKENS[@]}" -gt 0 ] || {
    log "Rollback via SSH refused: no pinned source cmdline identity"
    return 1
  }

  log "Attempting strict source-SSH rollback: $reason"
  if ! pmos_ssh_probe rollback; then
    log "Source-SSH rollback unavailable: probe failed"
    return 1
  fi
  rollback_boot_id="$PMOS_PROBE_BOOT_ID"
  rollback_kernel="$PMOS_PROBE_KERNEL"
  rollback_cmdline="$PMOS_PROBE_CMDLINE"
  case "$rollback_kernel" in
    "$EXPECT_SOURCE_KERNEL_PREFIX"*) ;;
    *)
      log "Source-SSH rollback refused: kernel '$rollback_kernel' is not '$EXPECT_SOURCE_KERNEL_PREFIX*'"
      return 1
      ;;
  esac
  for token in "${EXPECT_SOURCE_CMDLINE_TOKENS[@]}"; do
    if ! cmdline_has_token "$rollback_cmdline" "$token"; then
      log "Source-SSH rollback refused: cmdline token '$token' is absent"
      return 1
    fi
  done

  if [ "$START_RESCUE_WATCHER" -eq 1 ]; then
    ensure_rescue_watcher_alive "before source-SSH rollback" || return 1
  fi
  if ! verify_restore_image_hash; then
    log "Source-SSH rollback refused: restore image hash changed"
    return 1
  fi
  if run_source_ssh_writer rollback "$RESTORE_IMAGE" "$RESTORE_IMAGE_SHA256" \
    "$rollback_boot_id" "$rollback_kernel" 0; then
    RESTORE_READBACK_VERIFIED=1
    BOOT_B_MAY_BE_DIRTY=0
    KEEP_RESCUE_WATCHER=0
    log "Strict source-SSH rollback readback verified; boot_b is clean"
    return 0
  fi

  KEEP_RESCUE_WATCHER=1
  log "Source-SSH rollback failed; boot_b remains dirty"
  return 1
}

acknowledge_pmos_watchdog() {
  # Legacy generic mode only. Strict success uses one atomic identity+ACK session.
  sshpass -p "$PMOS_PASSWORD" ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile="$run_dir/known_hosts" \
    -o ConnectTimeout=5 \
    -o PreferredAuthentications=password \
    -o PubkeyAuthentication=no \
    "$PMOS_USER@$PMOS_HOST" \
    ': > /tmp/hotdog_rescue_watchdog.ok' \
    > "$run_dir/pmos-watchdog-ack.txt" 2>&1
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

  if [ "$START_RESCUE_WATCHER" -eq 1 ]; then
    ensure_rescue_watcher_alive "before leaving restored fastboot state" ||
      die "Companion rescue watcher is unavailable after fastboot restore" 3
  fi

  case "$RESTORE_AFTER_FASTBOOT" in
    recovery)
      log "Returning to recovery from fastboot"
      if [ "$START_RESCUE_WATCHER" -eq 1 ]; then
        run_guarded_fastboot_transport "restored fastboot recovery reboot" \
          "$run_dir/fastboot-reboot-recovery.txt" reboot recovery ||
          die "Recovery reboot after restore lost its rescue quorum or failed" 3
      else
        fastboot_do reboot recovery > "$run_dir/fastboot-reboot-recovery.txt" 2>&1 || true
      fi
      if wait_for_recovery_adb 120; then
        collect_recovery_crash_artifacts "after-fastboot-return"
      else
        log "Recovery ADB did not appear after recovery reboot"
      fi
      ;;
    system)
      log "Rebooting system after boot_b restore"
      if [ "$START_RESCUE_WATCHER" -eq 1 ]; then
        run_guarded_fastboot_transport "restored fastboot system reboot" \
          "$run_dir/fastboot-reboot-system-after-restore.txt" reboot ||
          die "System reboot after restore lost its rescue quorum or failed" 3
      else
        fastboot_do reboot > "$run_dir/fastboot-reboot-system-after-restore.txt" 2>&1 || true
      fi
      ;;
    bootloader)
      log "Rebooting bootloader after boot_b restore"
      if [ "$START_RESCUE_WATCHER" -eq 1 ]; then
        run_guarded_fastboot_transport "restored fastboot bootloader reboot" \
          "$run_dir/fastboot-reboot-bootloader-after-restore.txt" reboot bootloader ||
          die "Bootloader reboot after restore lost its rescue quorum or failed" 3
      else
        fastboot_do reboot bootloader > "$run_dir/fastboot-reboot-bootloader-after-restore.txt" 2>&1 || true
      fi
      ;;
    none)
      log "Leaving target in fastboot after boot_b restore"
      ;;
    *)
      die "Invalid restore-after mode: $RESTORE_AFTER_FASTBOOT" 2
      ;;
  esac
  if [ "$DUAL_PARTITION_TRANSACTION" -eq 1 ]; then
    local marker_tmp="$RESTORE_COMPLETE_FILE.$$.tmp"
    {
      printf 'contract_version=3\nserial=%s\n' "$SERIAL"
      printf 'restore_dtbo_sha256=%s\n' "$RESTORE_DTBO_EXPECTED_SHA256"
      printf 'restore_boot_sha256=%s\n' "$RESTORE_IMAGE_SHA256"
      printf 'order=dtbo_b,boot_b,set_active_b,reboot\n'
    } > "$marker_tmp"
    mv -f "$marker_tmp" "$RESTORE_COMPLETE_FILE"
    log "Published accepted dual restore marker"
  fi
}

restore_boot_b_if_configured() {
  [ -n "$RESTORE_IMAGE" ] || return 0
  [ -s "$RESTORE_IMAGE" ] || die "Restore image does not exist or is empty: $RESTORE_IMAGE" 2

  if [ "$START_RESCUE_WATCHER" -eq 1 ]; then
    ensure_rescue_watcher_alive "immediately before fastboot restore" ||
      die "Cannot restore boot_b without a live companion watcher" 3
  fi
  if [ "$DUAL_PARTITION_TRANSACTION" -eq 1 ]; then
    verify_restore_dtbo_hash
    validate_fastboot_restore_context "$RESTORE_DTBO_IMAGE" dtbo_b
    ensure_rescue_watcher_alive "final dtbo_b restore write boundary" ||
      die "Companion rescue watcher died before dtbo_b restore" 3
    verify_restore_dtbo_hash
    run_guarded_fastboot_transport "restore dtbo_b flash" \
      "$run_dir/fastboot-restore-dtbo-b.txt" flash dtbo_b "$RESTORE_DTBO_IMAGE" ||
      die "dtbo_b restore flash lost its rescue quorum or failed" 3
  fi
  validate_fastboot_restore_context "$RESTORE_IMAGE" boot_b
  verify_restore_image_hash
  if [ "$START_RESCUE_WATCHER" -eq 1 ]; then
    ensure_rescue_watcher_alive "final fastboot restore write boundary" ||
      die "Companion rescue watcher died before fastboot restore" 3
  fi
  validate_fastboot_restore_context "$RESTORE_IMAGE" boot_b
  verify_restore_image_hash

  log "Restoring boot_b from $RESTORE_IMAGE"
  sha256sum "$RESTORE_IMAGE" | tee "$run_dir/restore-image-sha256.txt"
  if [ "$START_RESCUE_WATCHER" -eq 1 ]; then
    run_guarded_fastboot_transport "restore boot_b flash" \
      "$run_dir/fastboot-restore-boot-b.txt" flash boot_b "$RESTORE_IMAGE" ||
      die "boot_b restore flash lost its rescue quorum or failed" 3
  else
    fastboot_do flash boot_b "$RESTORE_IMAGE" 2>&1 | tee "$run_dir/fastboot-restore-boot-b.txt"
  fi
  if [ "$START_RESCUE_WATCHER" -eq 1 ]; then
    ensure_rescue_watcher_alive "before restored slot activation" ||
      die "Companion rescue watcher died after fastboot restore" 3
  fi
  validate_fastboot_restore_context "$RESTORE_IMAGE" boot_b
  verify_restore_image_hash
  log "Rearming active slot b after boot_b restore"
  if [ "$START_RESCUE_WATCHER" -eq 1 ]; then
    run_guarded_fastboot_transport "restored slot-b activation" \
      "$run_dir/fastboot-set-active-b-after-restore.txt" set_active b ||
      die "Restored slot-b activation lost its rescue quorum or failed" 3
  else
    fastboot_do set_active b 2>&1 | tee "$run_dir/fastboot-set-active-b-after-restore.txt"
  fi
  get_fastboot_var slot-retry-count:b | tee "$run_dir/slot-retry-count-b-after-restore.txt" || true
  get_fastboot_var slot-unbootable:b | tee "$run_dir/slot-unbootable-b-after-restore.txt" || true
  log "Fastboot accepted the restore, but no cryptographic readback is available; boot_b remains conservatively dirty"
}

verify_restore_image_hash() {
  local actual=""

  if [ -z "$RESTORE_IMAGE_SHA256" ]; then
    log "ERROR: internal restore image SHA256 is unset"
    return 2
  fi
  actual="$(sha256sum "$RESTORE_IMAGE" | awk '{ print $1 }')"
  if [ "$actual" != "$RESTORE_IMAGE_SHA256" ]; then
    log "ERROR: restore image changed after validation: expected $RESTORE_IMAGE_SHA256, got $actual"
    return 3
  fi
}

verify_test_image_hash() {
  local actual=""

  [ -n "$IMAGE_EXPECTED_SHA256" ] || die "Internal error: test image SHA256 is unset" 2
  actual="$(sha256sum "$IMAGE" | awk '{ print $1 }')"
  [ "$actual" = "$IMAGE_EXPECTED_SHA256" ] ||
    die "Test image changed after validation: expected $IMAGE_EXPECTED_SHA256, got $actual" 3
}

verify_candidate_dtbo_hash() {
  local actual=""

  actual="$(sha256sum "$CANDIDATE_DTBO_IMAGE" | awk '{ print $1 }')"
  [ "$actual" = "$CANDIDATE_DTBO_EXPECTED_SHA256" ] ||
    die "Candidate dtbo changed after validation: expected $CANDIDATE_DTBO_EXPECTED_SHA256, got $actual" 3
}

verify_restore_dtbo_hash() {
  local actual=""

  actual="$(sha256sum "$RESTORE_DTBO_IMAGE" | awk '{ print $1 }')"
  [ "$actual" = "$RESTORE_DTBO_EXPECTED_SHA256" ] ||
    die "Restore dtbo changed after validation: expected $RESTORE_DTBO_EXPECTED_SHA256, got $actual" 3
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

flash_candidate_from_fastboot() {
  validate_fastboot_identity
  ensure_bootloader_fastboot
  validate_fastboot_restore_context "$IMAGE" boot_b
  if [ "$DUAL_PARTITION_TRANSACTION" -eq 1 ]; then
    validate_fastboot_restore_context "$CANDIDATE_DTBO_IMAGE" dtbo_b
  fi

  start_rescue_watcher || die "Could not prearm companion rescue watcher before fastboot flash" 3
  ensure_rescue_watcher_alive "immediately before candidate transaction" ||
    die "Companion rescue watcher is not alive at the write boundary" 3

  if [ "$DUAL_PARTITION_TRANSACTION" -eq 1 ]; then
    validate_fastboot_restore_context "$CANDIDATE_DTBO_IMAGE" dtbo_b
    verify_candidate_dtbo_hash
    DTBO_B_MAY_BE_DIRTY=1
    BOOT_B_MAY_BE_DIRTY=1
    run_guarded_fastboot_transport "candidate dtbo_b flash" \
      "$run_dir/fastboot-flash-dtbo-b.txt" flash dtbo_b "$CANDIDATE_DTBO_IMAGE" ||
      die "Candidate dtbo_b flash lost its rescue quorum or failed" 3
  else
    BOOT_B_MAY_BE_DIRTY=1
  fi

  validate_fastboot_restore_context "$IMAGE" boot_b
  verify_test_image_hash
  log "Flashing boot_b"
  if [ "$START_RESCUE_WATCHER" -eq 1 ]; then
    run_guarded_fastboot_transport "candidate boot_b flash" \
      "$run_dir/fastboot-flash-boot-b.txt" flash boot_b "$IMAGE" ||
      die "Candidate boot_b flash lost its rescue quorum or failed" 3
  else
    fastboot_do flash boot_b "$IMAGE" 2>&1 | tee "$run_dir/fastboot-flash-boot-b.txt"
  fi

  if [ "$SET_ACTIVE_B" -eq 1 ]; then
    validate_fastboot_restore_context "$IMAGE" boot_b
    verify_test_image_hash
    log "Setting active slot b"
    if [ "$START_RESCUE_WATCHER" -eq 1 ]; then
      run_guarded_fastboot_transport "candidate slot-b activation" \
        "$run_dir/fastboot-set-active-b.txt" set_active b ||
        die "Slot-b activation lost its rescue quorum or failed" 3
    else
      fastboot_do set_active b 2>&1 | tee "$run_dir/fastboot-set-active-b.txt"
    fi
  fi
  log "Rebooting into flashed boot_b"
  if [ "$START_RESCUE_WATCHER" -eq 1 ]; then
    run_guarded_fastboot_transport "candidate fastboot reboot" \
      "$run_dir/fastboot-reboot.txt" reboot ||
      die "Candidate reboot lost its rescue quorum or failed" 3
  else
    fastboot_do reboot 2>&1 | tee "$run_dir/fastboot-reboot.txt"
  fi
}

main() {
  local initial_image_sha=""
  local initial_restore_sha=""

  validate_seconds BOOT_WAIT_SEC "$BOOT_WAIT_SEC"
  validate_seconds POLL_SEC "$POLL_SEC"
  validate_seconds FASTBOOT_CMD_TIMEOUT_SEC "$FASTBOOT_CMD_TIMEOUT_SEC"
  validate_seconds RESCUE_WATCHER_TIMEOUT_SEC "$RESCUE_WATCHER_TIMEOUT_SEC"
  validate_seconds RESCUE_WATCHER_POLL_SEC "$RESCUE_WATCHER_POLL_SEC"
  validate_seconds RESCUE_WATCHER_READY_TIMEOUT_SEC "$RESCUE_WATCHER_READY_TIMEOUT_SEC"
  case "$RESTORE_AFTER_FASTBOOT" in
    recovery|system|bootloader|none) ;;
    *) die "--restore-after must be one of: recovery, system, bootloader, none" 2 ;;
  esac

  [ -n "$IMAGE" ] || die "Missing --image FILE" 2
  [ -s "$IMAGE" ] || die "Image does not exist or is empty: $IMAGE" 2
  if [ -n "$IMAGE_EXPECTED_SHA256" ] && ! [[ "$IMAGE_EXPECTED_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
    die "--image-sha256 must be exactly 64 hexadecimal characters" 2
  fi
  if [ -n "$RESTORE_IMAGE_EXPECTED_SHA256" ] && ! [[ "$RESTORE_IMAGE_EXPECTED_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
    die "--restore-boot-b-sha256 must be exactly 64 hexadecimal characters" 2
  fi

  if [ -n "$EXPECT_KERNEL_PREFIX" ] || [ "${#EXPECT_CMDLINE_TOKENS[@]}" -gt 0 ]; then
    STRICT_SSH_EXPECTATION=1
  fi
  if [ "$START_RESCUE_WATCHER" -eq 1 ] || [ "$STRICT_SSH_EXPECTATION" -eq 1 ]; then
    REQUIRE_DIRTY_SURVIVAL=1
  fi
  if [ "$REQUIRE_DIRTY_SURVIVAL" -eq 1 ] && [ "$START_RESCUE_WATCHER" -ne 1 ]; then
    die "Dirty-survival policy requires --start-rescue-watcher before any phone access" 2
  fi
  if [ "$DUAL_PARTITION_TRANSACTION" -eq 1 ]; then
    [ "$START_RESCUE_WATCHER" -eq 1 ] || die "Dual-partition transaction requires --start-rescue-watcher" 2
    [ "$SET_ACTIVE_B" -eq 1 ] || die "Dual-partition transaction requires slot-b activation" 2
    [ -n "$CANDIDATE_DTBO_IMAGE" ] && [ -n "$CANDIDATE_DTBO_EXPECTED_SHA256" ] &&
      [ -n "$RESTORE_DTBO_IMAGE" ] && [ -n "$RESTORE_DTBO_EXPECTED_SHA256" ] ||
      die "Dual-partition transaction requires candidate and restore DTBO paths and SHA256 values" 2
    for hash in "$CANDIDATE_DTBO_EXPECTED_SHA256" "$RESTORE_DTBO_EXPECTED_SHA256"; do
      [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || die "Dual-partition DTBO SHA256 must be exactly 64 hexadecimal characters" 2
    done
    [ -s "$CANDIDATE_DTBO_IMAGE" ] || die "Candidate dtbo image is missing: $CANDIDATE_DTBO_IMAGE" 2
    [ -s "$RESTORE_DTBO_IMAGE" ] || die "Restore dtbo image is missing: $RESTORE_DTBO_IMAGE" 2
    [ -s "$REBOOT_HELPER" ] || die "Source reboot helper is missing: $REBOOT_HELPER" 2
    [[ "$REBOOT_HELPER_EXPECTED_SHA256" =~ ^[0-9a-f]{64}$ ]] ||
      die "Dual-partition transaction requires --reboot-helper-sha256" 2
    [ "$(sha256sum "$REBOOT_HELPER" | awk '{ print $1 }')" = "$REBOOT_HELPER_EXPECTED_SHA256" ] ||
      die "Source reboot helper SHA256 mismatch" 3
    RESTORE_COMPLETE_FILE="$run_dir/dual-restore-complete"
    rm -f "$RESTORE_COMPLETE_FILE"
    verify_candidate_dtbo_hash
    verify_restore_dtbo_hash
  elif [ -n "$CANDIDATE_DTBO_IMAGE$CANDIDATE_DTBO_EXPECTED_SHA256$RESTORE_DTBO_IMAGE$RESTORE_DTBO_EXPECTED_SHA256" ]; then
    die "DTBO inputs require --dual-partition-transaction" 2
  fi

  command -v adb >/dev/null 2>&1 || die "Missing adb" 127
  command -v fastboot >/dev/null 2>&1 || die "Missing fastboot" 127
  command -v sha256sum >/dev/null 2>&1 || die "Missing sha256sum" 127
  command -v ping >/dev/null 2>&1 || die "Missing ping" 127
  command -v lsusb >/dev/null 2>&1 || die "Missing lsusb" 127
  command -v socat >/dev/null 2>&1 || die "Missing socat" 127
  command -v sshpass >/dev/null 2>&1 || die "Missing sshpass" 127
  command -v ssh >/dev/null 2>&1 || die "Missing ssh" 127
  command -v stat >/dev/null 2>&1 || die "Missing stat" 127
  command -v flock >/dev/null 2>&1 || die "Missing flock" 127
  command -v od >/dev/null 2>&1 || die "Missing od" 127
  command -v readlink >/dev/null 2>&1 || die "Missing readlink" 127
  command -v tr >/dev/null 2>&1 || die "Missing tr" 127
  if [ "$START_RESCUE_WATCHER" -eq 1 ]; then
    command -v setsid >/dev/null 2>&1 || die "Missing setsid" 127
  fi

  initial_image_sha="$(sha256sum "$IMAGE" | awk '{ print $1 }')"
  if [ -z "$IMAGE_EXPECTED_SHA256" ]; then
    IMAGE_EXPECTED_SHA256="$initial_image_sha"
  fi
  [ "$initial_image_sha" = "$IMAGE_EXPECTED_SHA256" ] ||
    die "Image SHA256 mismatch: expected $IMAGE_EXPECTED_SHA256, got $initial_image_sha" 3
  if [ -n "$RESTORE_IMAGE" ]; then
    [ -s "$RESTORE_IMAGE" ] || die "Restore image does not exist or is empty: $RESTORE_IMAGE" 2
    initial_restore_sha="$(sha256sum "$RESTORE_IMAGE" | awk '{ print $1 }')"
    if [ -z "$RESTORE_IMAGE_EXPECTED_SHA256" ]; then
      RESTORE_IMAGE_EXPECTED_SHA256="$initial_restore_sha"
    fi
    [ "$initial_restore_sha" = "$RESTORE_IMAGE_EXPECTED_SHA256" ] ||
      die "Restore image SHA256 mismatch: expected $RESTORE_IMAGE_EXPECTED_SHA256, got $initial_restore_sha" 3
    RESTORE_IMAGE_SHA256="$RESTORE_IMAGE_EXPECTED_SHA256"
  fi
  log "Run directory: $run_dir"
  log "Target serial: ${SERIAL:-auto-detect}"
  log "Image: $IMAGE"
  log "Restore boot_b image: ${RESTORE_IMAGE:-none}"
  log "Start from pmOS SSH: $START_FROM_PMOS_SSH"
  log "Expected kernel prefix: ${EXPECT_KERNEL_PREFIX:-none}"
  log "Expected target cmdline tokens: ${EXPECT_CMDLINE_TOKENS[*]:-none}"
  log "Expected source kernel prefix: ${EXPECT_SOURCE_KERNEL_PREFIX:-none}"
  log "Expected source cmdline tokens: ${EXPECT_SOURCE_CMDLINE_TOKENS[*]:-none}"
  log "Restore image SHA256: ${RESTORE_IMAGE_SHA256:-none}"
  log "Expected test image SHA256: $IMAGE_EXPECTED_SHA256"
  log "Transaction scope: $([ "$DUAL_PARTITION_TRANSACTION" -eq 1 ] && printf 'dtbo_b+boot_b-v3' || printf 'boot_b-only-v2')"
  log "Candidate dtbo SHA256: ${CANDIDATE_DTBO_EXPECTED_SHA256:-none}"
  log "Restore dtbo SHA256: ${RESTORE_DTBO_EXPECTED_SHA256:-none}"
  log "Restore-after mode: $RESTORE_AFTER_FASTBOOT"
  log "Companion rescue watcher: $START_RESCUE_WATCHER"
  log "Require dirty survival: $REQUIRE_DIRTY_SURVIVAL"
  printf '%s  %s\n' "$IMAGE_EXPECTED_SHA256" "$IMAGE" | tee "$run_dir/image-sha256.txt"

  if [ "$START_FROM_PMOS_SSH" -eq 1 ]; then
    log "Confirming healthy pmOS SSH source before flashing boot_b"
    if ! pmos_ssh_probe before; then
      die "pmOS SSH source probe did not return boot_id and uname -r; refusing to flash" 4
    fi
    PMOS_BOOT_ID_BEFORE="$PMOS_PROBE_BOOT_ID"
    PMOS_KERNEL_BEFORE="$PMOS_PROBE_KERNEL"
    PMOS_CMDLINE_BEFORE="$PMOS_PROBE_CMDLINE"
    log "pmOS source boot_id: $PMOS_BOOT_ID_BEFORE"
    log "pmOS source uname -r: $PMOS_KERNEL_BEFORE"
    if [ -n "$EXPECT_SOURCE_KERNEL_PREFIX" ]; then
      case "$PMOS_KERNEL_BEFORE" in
        "$EXPECT_SOURCE_KERNEL_PREFIX"*) ;;
        *) die "pmOS source kernel mismatch: expected '$EXPECT_SOURCE_KERNEL_PREFIX', got '$PMOS_KERNEL_BEFORE'; refusing to flash" 4 ;;
      esac
    fi
    for token in "${EXPECT_SOURCE_CMDLINE_TOKENS[@]}"; do
      cmdline_has_token "$PMOS_CMDLINE_BEFORE" "$token" ||
        die "pmOS source cmdline lacks '$token'; refusing to flash" 4
    done

    if [ "$START_RESCUE_WATCHER" -eq 1 ]; then
      if fastboot_present; then
        die "Target is already visible in fastboot; refusing to prearm rescue watcher from pmOS SSH" 3
      fi
      log "Prearming companion rescue watcher before pmOS SSH flash"
      start_rescue_watcher || die "Could not prearm companion rescue watcher" 3
      ensure_rescue_watcher_alive "before acquiring the D1 transaction lock" ||
        die "Companion rescue watcher failed its pre-write liveness check" 3
    fi

    if [ "$DUAL_PARTITION_TRANSACTION" -eq 1 ]; then
      local -a reboot_args=(
        --mode bootloader --helper "$REBOOT_HELPER" --helper-sha256 "$REBOOT_HELPER_EXPECTED_SHA256"
        --host "$PMOS_HOST" --user "$PMOS_USER" --password "$PMOS_PASSWORD" --serial "$SERIAL"
        --expected-source-boot-id "$PMOS_BOOT_ID_BEFORE"
        --expected-source-kernel "$PMOS_KERNEL_BEFORE"
      )
      for token in "${EXPECT_SOURCE_CMDLINE_TOKENS[@]}"; do
        reboot_args+=(--expected-source-cmdline-token "$token")
      done
      phone_lock_acquire "D3 R5 handoff, dtbo_b and boot_b transaction" 0 ||
        die "Could not acquire phone operation lock before D3 source handoff" 3
      reboot_args+=(--phone-lock-fd "$PHONE_LOCK_FD")
      run_guarded_transport "strict source R5 bootloader handoff" \
        "$run_dir/source-r5-reboot-bootloader.txt" \
        "$HOTDOG_ROOT/scripts/reboot-pmos-to-bootloader.sh" "${reboot_args[@]}" ||
        die "Strict source R5 bootloader handoff lost its rescue quorum or failed" 3
      wait_for_fastboot 120
      flash_candidate_from_fastboot
    else
      phone_lock_acquire "D1 boot_b write, observation and rollback transaction" 0 ||
        die "Could not acquire phone operation lock before pmOS SSH flash" 3
    if [ "$START_RESCUE_WATCHER" -eq 1 ]; then
      ensure_rescue_watcher_alive "immediately before D1 SSH writer" ||
        die "Companion rescue watcher is not alive at the D1 write boundary" 3
    fi
    verify_test_image_hash
    if [ "$START_RESCUE_WATCHER" -eq 1 ]; then
      ensure_rescue_watcher_alive "final D1 SSH writer boundary" ||
        die "Companion rescue watcher died before D1 SSH writer" 3
    fi
    BOOT_B_MAY_BE_DIRTY=1
    log "Starting from pmOS SSH; flashing boot_b via SSH helper and rebooting"
    if ! run_source_ssh_writer candidate "$IMAGE" "$IMAGE_EXPECTED_SHA256" \
      "$PMOS_BOOT_ID_BEFORE" "$PMOS_KERNEL_BEFORE" 1; then
      rollback_via_source_ssh_if_safe "D1 writer or reboot verification failed" || true
      die "pmOS SSH flash/reboot helper failed; rollback status recorded above" 4
    fi
      if [ "$START_RESCUE_WATCHER" -eq 1 ] &&
        ! ensure_rescue_watcher_alive "after D1 SSH writer"; then
        rollback_via_source_ssh_if_safe "rescue watcher died immediately after D1 write" || true
        die "Companion rescue watcher could not be rearmed after D1 write" 3
      fi
    fi
  else
    phone_lock_acquire "test boot_b image" 0

    local state=""
    local fastboot_count=""
    state="$(adb_state)"
    if [ "$state" = "recovery" ]; then
      log "Starting from recovery ADB; rebooting to bootloader"
      adb_do reboot bootloader
      wait_for_fastboot 90
    elif fastboot_present; then
      if [ -z "$SERIAL" ]; then
        fastboot_count="$(awk 'NF >= 1 { count++ } END { print count + 0 }' "$run_dir/fastboot-devices-last.txt")"
        [ "$fastboot_count" = "1" ] || die "Multiple fastboot devices found; rerun with --serial SERIAL" 2
        SERIAL="$(awk 'NF >= 1 { print $1; exit }' "$run_dir/fastboot-devices-last.txt")"
      fi
      export ANDROID_SERIAL="$SERIAL"
      log "Starting from fastboot"
    else
      die "Phone is not visible in recovery ADB or fastboot" 3
    fi

    flash_candidate_from_fastboot
  fi

  local deadline=$((SECONDS + BOOT_WAIT_SEC))
  local last_status=0
  local pmos_ping_seen=0
  local qualcomm_900e_seen=0
  local result="timeout"
  while [ "$SECONDS" -lt "$deadline" ]; do
    if [ "$START_RESCUE_WATCHER" -eq 1 ] &&
      ! ensure_rescue_watcher_alive "boot result observation"; then
      result="rescue-watcher-unavailable"
      rollback_via_source_ssh_if_safe "rescue watcher unavailable during observation" || true
      break
    fi

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
        if [ "$STRICT_SSH_EXPECTATION" -eq 0 ]; then
          break
        fi
        log "ADB is diagnostic only while strict SSH identity is required"
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
        if [ "$STRICT_SSH_EXPECTATION" -eq 0 ]; then
          break
        fi
        log "pmOS telnet is diagnostic only while strict SSH identity is required"
      fi
    fi

    local ssh_probe_seen=0
    if [ "$STRICT_SSH_EXPECTATION" -eq 1 ]; then
      pmos_ssh_probe_and_ack_strict && ssh_probe_seen=1
    else
      pmos_ssh_probe && ssh_probe_seen=1
    fi
    if [ "$ssh_probe_seen" -eq 1 ]; then
      local pmos_boot_id_after="$PMOS_PROBE_BOOT_ID"
      local pmos_kernel_after="$PMOS_PROBE_KERNEL"
      local pmos_cmdline_after="$PMOS_PROBE_CMDLINE"
      result="pmos-ssh"
      log "pmOS SSH probe OK"
      log "pmOS SSH boot_id after boot: $pmos_boot_id_after"
      log "pmOS SSH uname -r after boot: $pmos_kernel_after"
      printf '%s\n' "$pmos_cmdline_after" > "$run_dir/pmos-cmdline-after-verified.txt"
      if [ "$START_FROM_PMOS_SSH" -eq 1 ]; then
        if [ "$pmos_boot_id_after" = "$PMOS_BOOT_ID_BEFORE" ]; then
          log "WARNING: pmOS SSH boot_id did not change after requested reboot"
          if [ -n "$EXPECT_KERNEL_PREFIX" ]; then
            result="pmos-ssh-unchanged-boot-id"
            log "ERROR: refusing expected-kernel success because boot_id did not change"
          fi
        else
          log "pmOS boot_id changed after reboot: $pmos_boot_id_after"
        fi
      fi
      if [ -n "$EXPECT_KERNEL_PREFIX" ]; then
        case "$pmos_kernel_after" in
          "$EXPECT_KERNEL_PREFIX"*)
            log "pmOS SSH kernel matches expected prefix: $EXPECT_KERNEL_PREFIX"
            ;;
          *)
            result="pmos-ssh-kernel-mismatch"
            log "ERROR: expected kernel prefix '$EXPECT_KERNEL_PREFIX', got '$pmos_kernel_after'"
            ;;
        esac
      fi
      for token in "${EXPECT_CMDLINE_TOKENS[@]}"; do
        if cmdline_has_token "$pmos_cmdline_after" "$token"; then
          log "pmOS SSH cmdline contains expected token: $token"
        else
          result="pmos-ssh-cmdline-mismatch"
          log "ERROR: expected cmdline token '$token' is absent"
        fi
      done
      if [ "$result" = "pmos-ssh" ]; then
        if [ "$STRICT_SSH_EXPECTATION" -eq 1 ] && [ "$PMOS_PROBE_ATOMIC_ACKED" -eq 1 ]; then
          STRICT_MAINLINE_SUCCESS_ACKED=1
          log "pmOS rescue watchdog atomically acknowledged in the strict SSH identity session"
        elif [ "$STRICT_SSH_EXPECTATION" -eq 1 ]; then
          result="pmos-ssh-watchdog-ack-failed"
          log "ERROR: strict SSH identity response lacked its atomic watchdog ACK proof"
        elif acknowledge_pmos_watchdog; then
          log "pmOS rescue watchdog acknowledged for legacy generic SSH result"
        else
          result="pmos-ssh-watchdog-ack-failed"
          log "ERROR: could not acknowledge pmOS rescue watchdog"
        fi
      fi
      if [ "$result" != "pmos-ssh" ]; then
        rollback_via_source_ssh_if_safe "post-boot SSH identity was not the strict mainline target" || true
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
    elif [ "$START_RESCUE_WATCHER" -eq 1 ]; then
      if ensure_rescue_watcher_alive "main observation timeout"; then
        KEEP_RESCUE_WATCHER=1
        log "No USB recovery path at timeout; companion rescue watcher will keep waiting"
      else
        log "ERROR: no USB recovery path and rescue watcher rearm failed at timeout"
      fi
    fi
  fi

  adb devices -l > "$run_dir/adb-final.txt" 2>&1 || true
  hotdog_fastboot_devices > "$run_dir/fastboot-final.txt" 2>&1 || true
  log "Result: $result"
  log "Done: $run_dir"

  if [ "$STRICT_SSH_EXPECTATION" -eq 1 ] && [ "$result" != "pmos-ssh" ]; then
    log "ERROR: expected kernel/cmdline identity was not verified by a fresh pmOS SSH probe (result: $result)"
    if rescue_watcher_must_survive && [ "$START_RESCUE_WATCHER" -eq 1 ]; then
      if ensure_rescue_watcher_alive "strict non-success exit"; then
        KEEP_RESCUE_WATCHER=1
        log "Leaving companion rescue watcher running until a recovery path appears"
      else
        log "CRITICAL: strict non-success with dirty boot_b and no live rescue watcher"
      fi
    fi
    return 5
  fi

  if rescue_watcher_must_survive; then
    log "ERROR: boot_b may still contain the test image and no strict readback restore was obtained"
    return 6
  fi

  if [ "$BOOT_B_MAY_BE_DIRTY" -eq 1 ] && [ "$REQUIRE_DIRTY_SURVIVAL" -eq 0 ]; then
    log "Legacy generic result contract: candidate remains in boot_b; no clean-state claim is made"
  fi

  case "$result" in
    pmos-ssh-kernel-mismatch|pmos-ssh-cmdline-mismatch|pmos-ssh-watchdog-ack-failed|pmos-ssh-unchanged-boot-id)
      return 5
      ;;
  esac
}

main "$@"
