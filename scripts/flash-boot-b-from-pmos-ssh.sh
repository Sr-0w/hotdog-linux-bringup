#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=/dev/null
source "$(dirname "$0")/env.sh"
# shellcheck source=/dev/null
source "$(dirname "$0")/phone-lock.sh"

PMOS_HOST="${PMOS_HOST:-$HOTDOG_PMOS_HOST}"
PMOS_USER="${PMOS_USER:-$HOTDOG_PMOS_USER}"
PMOS_PASSWORD="${PMOS_PASSWORD:-$HOTDOG_PMOS_PASSWORD}"
SERIAL="${ANDROID_SERIAL:-$HOTDOG_TARGET_SERIAL}"
IMAGE=""
IMAGE_EXPECTED_SHA256=""
REMOTE_DIR=""
PARTITION_LABEL="boot_b"
PARTITION_PATH=""
REBOOT=0
KEEP_REMOTE=0
LOCK_WAIT_SEC="${LOCK_WAIT_SEC:-0}"
INHERITED_LOCK_FD=""
REQUIRE_WATCHER_CONTRACT=0
declare -a REQUIRED_WATCHER_PIDS=("" "")
declare -a REQUIRED_WATCHER_STARTTIMES=("" "")
declare -a REQUIRED_WATCHER_READY_FILES=("" "")
declare -a REQUIRED_WATCHER_NONCES=("" "")
declare -a REQUIRED_WATCHER_SCRIPTS=("" "")
declare -a REQUIRED_WATCHER_RESTORE_IMAGES=("" "")
declare -a REQUIRED_WATCHER_RESTORE_SHA256S=("" "")
declare -a REQUIRED_WATCHER_CHALLENGE_FILES=("" "")
declare -a REQUIRED_WATCHER_ACK_FILES=("" "")
WATCHER_CONTRACT_ACK_TIMEOUT_SEC="${WATCHER_CONTRACT_ACK_TIMEOUT_SEC:-20}"
EXPECTED_SOURCE_BOOT_ID=""
EXPECTED_SOURCE_KERNEL=""
EXPECTED_SOURCE_CMDLINE_TOKENS=()
ACTIVE_TRANSPORT_PID=""

usage() {
  cat <<'USAGE'
Usage: flash-boot-b-from-pmos-ssh.sh --image boot.img [options]

Copy a boot image to the already-booted postmarketOS userland over SSH, write
it to boot_b from the phone itself, and verify the block prefix hash.

By default this script does not reboot. It writes only boot_b unless explicitly
given another partition path and the code is edited.

Options:
  --image FILE       Boot image to flash to boot_b.
  --image-sha256 SHA Require this exact local, transferred and remote SHA256.
  --host HOST        postmarketOS SSH host. Default: 172.16.42.1.
  --user USER        SSH user. Default: user.
  --password PASS    SSH password. Defaults to PMOS_PASSWORD.
  --serial SERIAL    Require androidboot.serialno to match this serial.
  --expected-source-boot-id ID
                      Require this exact source boot_id immediately before dd.
  --expected-source-kernel RELEASE
                      Require this exact source uname -r immediately before dd.
  --expected-source-cmdline-token TOKEN
                      Require this source /proc/cmdline token; repeat as needed.
  --remote-dir DIR   Remote temp directory. Default: /tmp/hotdog-flash-<stamp>.
  --partition-path P Explicit block node, normally auto-detected from boot_b.
  --reboot           Dispatch a supervised sysrq reboot after readback verify;
                     require a nonce proof plus an accepted SSH status/ping drop.
  --keep-remote      Do not remove the copied image/script on success.
  --lock-wait SEC    Seconds to wait for the local phone-operation lock.
  --phone-lock-fd FD Adopt an already-held inherited transaction lock.
  --require-watcher-contract
                      Require the complete versioned watcher contract.
  --required-watcher-pid PID
  --required-watcher-starttime TICKS
  --required-watcher-ready-file FILE
  --required-watcher-nonce HEX
  --required-watcher-script FILE
  --required-watcher-restore-image FILE
  --required-watcher-restore-sha256 SHA256
  --required-watcher-challenge-file FILE
  --required-watcher-ack-file FILE
  --required-watcher2-pid PID
  --required-watcher2-starttime TICKS
  --required-watcher2-ready-file FILE
  --required-watcher2-nonce HEX
  --required-watcher2-script FILE
  --required-watcher2-restore-image FILE
  --required-watcher2-restore-sha256 SHA256
  --required-watcher2-challenge-file FILE
  --required-watcher2-ack-file FILE
                      Require two independent boot_b-only rescue contracts.
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
    --image-sha256)
      [ "$#" -ge 2 ] || { echo "Missing value for --image-sha256" >&2; exit 2; }
      IMAGE_EXPECTED_SHA256="${2,,}"
      shift
      ;;
    --host)
      [ "$#" -ge 2 ] || { echo "Missing value for --host" >&2; exit 2; }
      PMOS_HOST="$2"
      shift
      ;;
    --user)
      [ "$#" -ge 2 ] || { echo "Missing value for --user" >&2; exit 2; }
      PMOS_USER="$2"
      shift
      ;;
    --password)
      [ "$#" -ge 2 ] || { echo "Missing value for --password" >&2; exit 2; }
      PMOS_PASSWORD="$2"
      shift
      ;;
    --serial)
      [ "$#" -ge 2 ] || { echo "Missing value for --serial" >&2; exit 2; }
      SERIAL="$2"
      shift
      ;;
    --expected-source-boot-id)
      [ "$#" -ge 2 ] || { echo "Missing value for --expected-source-boot-id" >&2; exit 2; }
      EXPECTED_SOURCE_BOOT_ID="$2"
      shift
      ;;
    --expected-source-kernel)
      [ "$#" -ge 2 ] || { echo "Missing value for --expected-source-kernel" >&2; exit 2; }
      EXPECTED_SOURCE_KERNEL="$2"
      shift
      ;;
    --expected-source-cmdline-token)
      [ "$#" -ge 2 ] || { echo "Missing value for --expected-source-cmdline-token" >&2; exit 2; }
      [ -n "$2" ] || { echo "--expected-source-cmdline-token must not be empty" >&2; exit 2; }
      [[ "$2" != *[[:space:]]* ]] || { echo "--expected-source-cmdline-token must be one token" >&2; exit 2; }
      EXPECTED_SOURCE_CMDLINE_TOKENS+=("$2")
      shift
      ;;
    --remote-dir)
      [ "$#" -ge 2 ] || { echo "Missing value for --remote-dir" >&2; exit 2; }
      REMOTE_DIR="$2"
      shift
      ;;
    --partition-path)
      [ "$#" -ge 2 ] || { echo "Missing value for --partition-path" >&2; exit 2; }
      PARTITION_PATH="$2"
      shift
      ;;
    --reboot)
      REBOOT=1
      ;;
    --keep-remote)
      KEEP_REMOTE=1
      ;;
    --lock-wait)
      [ "$#" -ge 2 ] || { echo "Missing value for --lock-wait" >&2; exit 2; }
      LOCK_WAIT_SEC="$2"
      shift
      ;;
    --phone-lock-fd)
      [ "$#" -ge 2 ] || { echo "Missing value for --phone-lock-fd" >&2; exit 2; }
      INHERITED_LOCK_FD="$2"
      shift
      ;;
    --required-watcher-pid)
      [ "$#" -ge 2 ] || { echo "Missing value for --required-watcher-pid" >&2; exit 2; }
      REQUIRED_WATCHER_PIDS[0]="$2"
      shift
      ;;
    --require-watcher-contract)
      REQUIRE_WATCHER_CONTRACT=1
      ;;
    --required-watcher-starttime)
      [ "$#" -ge 2 ] || { echo "Missing value for --required-watcher-starttime" >&2; exit 2; }
      REQUIRED_WATCHER_STARTTIMES[0]="$2"
      shift
      ;;
    --required-watcher-ready-file)
      [ "$#" -ge 2 ] || { echo "Missing value for --required-watcher-ready-file" >&2; exit 2; }
      REQUIRED_WATCHER_READY_FILES[0]="$2"
      shift
      ;;
    --required-watcher-nonce)
      [ "$#" -ge 2 ] || { echo "Missing value for --required-watcher-nonce" >&2; exit 2; }
      REQUIRED_WATCHER_NONCES[0]="${2,,}"
      shift
      ;;
    --required-watcher-script)
      [ "$#" -ge 2 ] || { echo "Missing value for --required-watcher-script" >&2; exit 2; }
      REQUIRED_WATCHER_SCRIPTS[0]="$2"
      shift
      ;;
    --required-watcher-restore-image)
      [ "$#" -ge 2 ] || { echo "Missing value for --required-watcher-restore-image" >&2; exit 2; }
      REQUIRED_WATCHER_RESTORE_IMAGES[0]="$2"
      shift
      ;;
    --required-watcher-restore-sha256)
      [ "$#" -ge 2 ] || { echo "Missing value for --required-watcher-restore-sha256" >&2; exit 2; }
      REQUIRED_WATCHER_RESTORE_SHA256S[0]="${2,,}"
      shift
      ;;
    --required-watcher-challenge-file)
      [ "$#" -ge 2 ] || { echo "Missing value for --required-watcher-challenge-file" >&2; exit 2; }
      REQUIRED_WATCHER_CHALLENGE_FILES[0]="$2"
      shift
      ;;
    --required-watcher-ack-file)
      [ "$#" -ge 2 ] || { echo "Missing value for --required-watcher-ack-file" >&2; exit 2; }
      REQUIRED_WATCHER_ACK_FILES[0]="$2"
      shift
      ;;
    --required-watcher2-pid)
      [ "$#" -ge 2 ] || { echo "Missing value for --required-watcher2-pid" >&2; exit 2; }
      REQUIRED_WATCHER_PIDS[1]="$2"
      shift
      ;;
    --required-watcher2-starttime)
      [ "$#" -ge 2 ] || { echo "Missing value for --required-watcher2-starttime" >&2; exit 2; }
      REQUIRED_WATCHER_STARTTIMES[1]="$2"
      shift
      ;;
    --required-watcher2-ready-file)
      [ "$#" -ge 2 ] || { echo "Missing value for --required-watcher2-ready-file" >&2; exit 2; }
      REQUIRED_WATCHER_READY_FILES[1]="$2"
      shift
      ;;
    --required-watcher2-nonce)
      [ "$#" -ge 2 ] || { echo "Missing value for --required-watcher2-nonce" >&2; exit 2; }
      REQUIRED_WATCHER_NONCES[1]="${2,,}"
      shift
      ;;
    --required-watcher2-script)
      [ "$#" -ge 2 ] || { echo "Missing value for --required-watcher2-script" >&2; exit 2; }
      REQUIRED_WATCHER_SCRIPTS[1]="$2"
      shift
      ;;
    --required-watcher2-restore-image)
      [ "$#" -ge 2 ] || { echo "Missing value for --required-watcher2-restore-image" >&2; exit 2; }
      REQUIRED_WATCHER_RESTORE_IMAGES[1]="$2"
      shift
      ;;
    --required-watcher2-restore-sha256)
      [ "$#" -ge 2 ] || { echo "Missing value for --required-watcher2-restore-sha256" >&2; exit 2; }
      REQUIRED_WATCHER_RESTORE_SHA256S[1]="${2,,}"
      shift
      ;;
    --required-watcher2-challenge-file)
      [ "$#" -ge 2 ] || { echo "Missing value for --required-watcher2-challenge-file" >&2; exit 2; }
      REQUIRED_WATCHER_CHALLENGE_FILES[1]="$2"
      shift
      ;;
    --required-watcher2-ack-file)
      [ "$#" -ge 2 ] || { echo "Missing value for --required-watcher2-ack-file" >&2; exit 2; }
      REQUIRED_WATCHER_ACK_FILES[1]="$2"
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
run_dir="$HOTDOG_LOG_ROOT/flash-boot-b-from-pmos-ssh-$stamp"
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
  if [[ "${ACTIVE_TRANSPORT_PID:-}" =~ ^[0-9]+$ ]]; then
    log "Terminating active SSH transport group during cleanup: $ACTIVE_TRANSPORT_PID"
    terminate_transport_group "$ACTIVE_TRANSPORT_PID"
  fi
  phone_lock_release || true
}
trap cleanup EXIT

validate_seconds() {
  local name="$1"
  local value="$2"
  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    die "$name must be a non-negative integer, got: $value" 2
  fi
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "Missing command: $cmd" 127
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

  printf 'contract_version=2\n'
  printf 'pid=%s\n' "${REQUIRED_WATCHER_PIDS[$index]}"
  printf 'starttime=%s\n' "${REQUIRED_WATCHER_STARTTIMES[$index]}"
  printf 'serial=%s\n' "$SERIAL"
  printf 'restore_image=%s\n' "${REQUIRED_WATCHER_RESTORE_IMAGES[$index]}"
  printf 'restore_sha256=%s\n' "${REQUIRED_WATCHER_RESTORE_SHA256S[$index]}"
  printf 'boot_b_only=1\n'
  printf 'restore_dtbo_image=none\n'
  printf 'restore_dtbo_sha256=none\n'
  printf 'nonce=%s\n' "${REQUIRED_WATCHER_NONCES[$index]}"
  printf 'watcher_script=%s\n' "${REQUIRED_WATCHER_SCRIPTS[$index]}"
  printf 'challenge_file=%s\n' "${REQUIRED_WATCHER_CHALLENGE_FILES[$index]}"
  printf 'ack_file=%s\n' "${REQUIRED_WATCHER_ACK_FILES[$index]}"
}

validate_watcher_contract_configuration() {
  local index=0
  local other=0
  local value=""
  local -a files=()

  if [ "$REQUIRE_WATCHER_CONTRACT" -eq 0 ]; then
    for index in 0 1; do
      for value in \
        "${REQUIRED_WATCHER_PIDS[$index]}" "${REQUIRED_WATCHER_STARTTIMES[$index]}" \
        "${REQUIRED_WATCHER_READY_FILES[$index]}" "${REQUIRED_WATCHER_NONCES[$index]}" \
        "${REQUIRED_WATCHER_SCRIPTS[$index]}" "${REQUIRED_WATCHER_RESTORE_IMAGES[$index]}" \
        "${REQUIRED_WATCHER_RESTORE_SHA256S[$index]}" "${REQUIRED_WATCHER_CHALLENGE_FILES[$index]}" \
        "${REQUIRED_WATCHER_ACK_FILES[$index]}"
      do
        [ -z "$value" ] || die "Watcher contract fields require --require-watcher-contract" 2
      done
    done
    return 0
  fi

  for index in 0 1; do
    [[ "${REQUIRED_WATCHER_PIDS[$index]}" =~ ^[0-9]+$ ]] || die "Watcher $((index + 1)) contract has an invalid PID" 2
    [[ "${REQUIRED_WATCHER_STARTTIMES[$index]}" =~ ^[0-9]+$ ]] || die "Watcher $((index + 1)) contract has an invalid starttime" 2
    [[ "${REQUIRED_WATCHER_NONCES[$index]}" =~ ^[0-9a-f]{64}$ ]] || die "Watcher $((index + 1)) contract has an invalid nonce" 2
    [[ "${REQUIRED_WATCHER_RESTORE_SHA256S[$index]}" =~ ^[0-9a-f]{64}$ ]] || die "Watcher $((index + 1)) contract has an invalid restore SHA256" 2
    [ -n "${REQUIRED_WATCHER_READY_FILES[$index]}" ] || die "Watcher $((index + 1)) contract is missing readiness file" 2
    [ -n "${REQUIRED_WATCHER_SCRIPTS[$index]}" ] || die "Watcher $((index + 1)) contract is missing script identity" 2
    [ -n "${REQUIRED_WATCHER_RESTORE_IMAGES[$index]}" ] || die "Watcher $((index + 1)) contract is missing restore image" 2
    [ -n "${REQUIRED_WATCHER_CHALLENGE_FILES[$index]}" ] || die "Watcher $((index + 1)) contract is missing challenge file" 2
    [ -n "${REQUIRED_WATCHER_ACK_FILES[$index]}" ] || die "Watcher $((index + 1)) contract is missing ACK file" 2
    files+=("${REQUIRED_WATCHER_READY_FILES[$index]}" "${REQUIRED_WATCHER_CHALLENGE_FILES[$index]}" "${REQUIRED_WATCHER_ACK_FILES[$index]}")
  done
  [ "${REQUIRED_WATCHER_PIDS[0]}" != "${REQUIRED_WATCHER_PIDS[1]}" ] || die "Watcher contracts must use distinct PIDs" 2
  [ "${REQUIRED_WATCHER_NONCES[0]}" != "${REQUIRED_WATCHER_NONCES[1]}" ] || die "Watcher contracts must use distinct nonces" 2
  [ "${REQUIRED_WATCHER_RESTORE_IMAGES[0]}" = "${REQUIRED_WATCHER_RESTORE_IMAGES[1]}" ] || die "Watcher contracts disagree on restore image" 2
  [ "${REQUIRED_WATCHER_RESTORE_SHA256S[0]}" = "${REQUIRED_WATCHER_RESTORE_SHA256S[1]}" ] || die "Watcher contracts disagree on restore SHA256" 2
  for index in "${!files[@]}"; do
    for other in "${!files[@]}"; do
      [ "$index" -ge "$other" ] && continue
      [ "${files[$index]}" != "${files[$other]}" ] || die "Watcher contract files must all be distinct" 2
    done
  done
}

watcher_contract_static_valid() {
  local index="$1"
  local actual=""
  local expected=""
  local actual_starttime=""
  local pid="${REQUIRED_WATCHER_PIDS[$index]}"
  local ready_file="${REQUIRED_WATCHER_READY_FILES[$index]}"

  [ "$REQUIRE_WATCHER_CONTRACT" -eq 1 ] || return 0
  [ -r "$ready_file" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  actual_starttime="$(process_starttime "$pid")" || return 1
  [ "$actual_starttime" = "${REQUIRED_WATCHER_STARTTIMES[$index]}" ] || return 1
  process_cmdline_has_token "$pid" "${REQUIRED_WATCHER_SCRIPTS[$index]}" || return 1
  process_cmdline_has_token "$pid" --contract-nonce || return 1
  process_cmdline_has_token "$pid" "${REQUIRED_WATCHER_NONCES[$index]}" || return 1
  process_cmdline_has_token "$pid" --serial || return 1
  process_cmdline_has_token "$pid" "$SERIAL" || return 1
  process_cmdline_has_token "$pid" --restore-boot-b || return 1
  process_cmdline_has_token "$pid" "${REQUIRED_WATCHER_RESTORE_IMAGES[$index]}" || return 1
  process_cmdline_has_token "$pid" --restore-boot-b-sha256 || return 1
  process_cmdline_has_token "$pid" "${REQUIRED_WATCHER_RESTORE_SHA256S[$index]}" || return 1
  process_cmdline_has_token "$pid" --boot-b-only || return 1
  ! process_cmdline_has_token "$pid" --restore-dtbo-b || return 1
  process_cmdline_has_token "$pid" --ready-file || return 1
  process_cmdline_has_token "$pid" "$ready_file" || return 1
  process_cmdline_has_token "$pid" --contract-challenge-file || return 1
  process_cmdline_has_token "$pid" "${REQUIRED_WATCHER_CHALLENGE_FILES[$index]}" || return 1
  process_cmdline_has_token "$pid" --contract-ack-file || return 1
  process_cmdline_has_token "$pid" "${REQUIRED_WATCHER_ACK_FILES[$index]}" || return 1
  actual="$(< "$ready_file")"
  expected="$(watcher_ready_expected "$index")"
  [ "$actual" = "$expected" ]
}

challenge_required_watcher() {
  local index="$1"
  local challenge=""
  local challenge_tmp=""
  local expected_ack=""
  local actual_ack=""
  local deadline=0
  local pid="${REQUIRED_WATCHER_PIDS[$index]}"
  local starttime="${REQUIRED_WATCHER_STARTTIMES[$index]}"
  local nonce="${REQUIRED_WATCHER_NONCES[$index]}"
  local challenge_file="${REQUIRED_WATCHER_CHALLENGE_FILES[$index]}"
  local ack_file="${REQUIRED_WATCHER_ACK_FILES[$index]}"

  [ "$REQUIRE_WATCHER_CONTRACT" -eq 1 ] || return 0
  watcher_contract_static_valid "$index" || return 1
  challenge="$(random_hex_256)"
  [[ "$challenge" =~ ^[0-9a-f]{64}$ ]] || return 1
  challenge_tmp="$challenge_file.$$.tmp"
  rm -f "$ack_file"
  umask 077
  {
    printf 'contract_version=2\n'
    printf 'nonce=%s\n' "$nonce"
    printf 'challenge=%s\n' "$challenge"
  } > "$challenge_tmp" || return 1
  mv -f "$challenge_tmp" "$challenge_file" || return 1
  kill -USR1 "$pid" 2>/dev/null || return 1

  expected_ack="$(printf 'contract_version=2\npid=%s\nstarttime=%s\nnonce=%s\nchallenge=%s\n' \
    "$pid" "$starttime" "$nonce" "$challenge")"
  deadline=$((SECONDS + WATCHER_CONTRACT_ACK_TIMEOUT_SEC))
  while [ "$SECONDS" -lt "$deadline" ]; do
    watcher_contract_static_valid "$index" || return 1
    if [ -r "$ack_file" ]; then
      actual_ack="$(< "$ack_file")"
      if [ "$actual_ack" = "$expected_ack" ]; then
        watcher_contract_static_valid "$index"
        return
      fi
    fi
    sleep 0.01
  done
  return 1
}

required_watcher_pair_static_valid() {
  watcher_contract_static_valid 0 && watcher_contract_static_valid 1
}

required_watcher_any_static_valid() {
  watcher_contract_static_valid 0 || watcher_contract_static_valid 1
}

challenge_required_watcher_pair() {
  challenge_required_watcher 0 || return
  challenge_required_watcher 1 || return
  required_watcher_pair_static_valid
}

verify_required_watcher() {
  [ "$REQUIRE_WATCHER_CONTRACT" -eq 1 ] || return 0
  challenge_required_watcher_pair ||
    die "Required two-watcher rescue quorum validation/ACK failed" 3
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

  if [ "$REQUIRE_WATCHER_CONTRACT" -eq 0 ]; then
    "$@" > "$output" 2>&1
    return
  fi
  verify_required_watcher
  setsid --wait "$@" > "$output" 2>&1 &
  transport_pid="$!"
  ACTIVE_TRANSPORT_PID="$transport_pid"
  while transport_process_running "$transport_pid"; do
    if ! required_watcher_pair_static_valid; then
      log "ERROR: rescue quorum degraded during $label; terminating transport group $transport_pid"
      if required_watcher_any_static_valid; then
        log "Independent rescue capacity remains active while parent rearms the pair"
      else
        log "CRITICAL: both rescue watcher contracts disappeared during $label"
      fi
      terminate_transport_group "$transport_pid"
      die "Rescue quorum lost during $label" 3
    fi
    sleep 0.01
  done
  if wait "$transport_pid"; then
    status=0
  else
    status=$?
  fi
  ACTIVE_TRANSPORT_PID=""
  verify_required_watcher
  return "$status"
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

guarded_ssh_base() {
  local label="$1"
  local output="$2"
  shift 2

  run_guarded_transport "$label" "$output" \
    sshpass -p "$PMOS_PASSWORD" ssh \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile="$run_dir/known_hosts" \
      -o ConnectTimeout=8 \
      -o PreferredAuthentications=password \
      -o PubkeyAuthentication=no \
      "$PMOS_USER@$PMOS_HOST" "$@"
}

remote_run() {
  ssh_base "$@"
}

remote_sudo_sh() {
  local script="$1"
  remote_run "sudo -n sh -c $(remote_quote "$script")"
}

guarded_remote_sudo_sh() {
  local label="$1"
  local output="$2"
  local script="$3"

  guarded_ssh_base "$label" "$output" "sudo -n sh -c $(remote_quote "$script")"
}

remote_assert_peer_identity() {
  local source_tokens=""

  if [ "${#EXPECTED_SOURCE_CMDLINE_TOKENS[@]}" -gt 0 ]; then
    printf -v source_tokens '%s\n' "${EXPECTED_SOURCE_CMDLINE_TOKENS[@]}"
    source_tokens="${source_tokens%$'\n'}"
  fi

  log "Verifying pmOS SSH peer serial, project and source boot identity"
  remote_run \
    "EXPECTED_SERIAL=$(remote_quote "$SERIAL") EXPECTED_SOURCE_BOOT_ID=$(remote_quote "$EXPECTED_SOURCE_BOOT_ID") EXPECTED_SOURCE_KERNEL=$(remote_quote "$EXPECTED_SOURCE_KERNEL") EXPECTED_SOURCE_TOKENS=$(remote_quote "$source_tokens") sh -s" \
    <<'REMOTE_IDENTITY'
set -eu

expected_serial="${EXPECTED_SERIAL:?}"
expected_source_boot_id="${EXPECTED_SOURCE_BOOT_ID:-}"
expected_source_kernel="${EXPECTED_SOURCE_KERNEL:-}"
expected_source_tokens="${EXPECTED_SOURCE_TOKENS:-}"
cmdline="$(cat /proc/cmdline 2>/dev/null || true)"
boot_id="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)"
kernel="$(uname -r 2>/dev/null || true)"

case " $cmdline " in
  *" androidboot.serialno=$expected_serial "*) ;;
  *)
    printf '%s\n' "ERROR: androidboot.serialno does not match expected serial $expected_serial" >&2
    exit 1
    ;;
esac

for identity_token in \
  androidboot.project_codename=hotdog \
  androidboot.prjname=19801 \
  androidboot.platform_name=SM8150 \
  androidboot.oplus.brand=OnePlus
do
  case " $cmdline " in
    *" $identity_token "*) ;;
    *)
      printf 'ERROR: %s is missing from /proc/cmdline\n' "$identity_token" >&2
      exit 1
      ;;
  esac
done

if [ -n "$expected_source_boot_id" ] && [ "$boot_id" != "$expected_source_boot_id" ]; then
  printf 'ERROR: source boot_id changed: expected %s, got %s\n' "$expected_source_boot_id" "${boot_id:-missing}" >&2
  exit 1
fi
if [ -n "$expected_source_kernel" ] && [ "$kernel" != "$expected_source_kernel" ]; then
  printf 'ERROR: source kernel changed: expected %s, got %s\n' "$expected_source_kernel" "${kernel:-missing}" >&2
  exit 1
fi

old_ifs=$IFS
IFS='
'
for identity_token in $expected_source_tokens; do
  [ -n "$identity_token" ] || continue
  case " $cmdline " in
    *" $identity_token "*) ;;
    *)
      printf 'ERROR: source token %s is missing from /proc/cmdline\n' "$identity_token" >&2
      exit 1
      ;;
  esac
done
IFS=$old_ifs

printf 'peer-identity-ok serial=%s codename=hotdog project=19801 platform=SM8150 brand=OnePlus boot_id=%s kernel=%s\n' \
  "$expected_serial" "$boot_id" "$kernel"
REMOTE_IDENTITY
}

remote_force_reboot() {
  local dispatch_nonce=""
  local dispatch_marker=""
  local ready_marker=""
  local reboot_inner=""
  local reboot_cmd=""
  local reboot_status=0
  local saw_ping_drop=0

  dispatch_nonce="$(random_hex_256)"
  [[ "$dispatch_nonce" =~ ^[0-9a-f]{64}$ ]] || {
    log "ERROR: could not generate reboot dispatch nonce"
    return 1
  }
  dispatch_marker="HOTDOG_REBOOT_DISPATCH=$dispatch_nonce"
  ready_marker="HOTDOG_REBOOT_READY=$dispatch_nonce"
  reboot_inner="printf '%s\\n' $(remote_quote "$ready_marker"); sync; printf '%s\\n' $(remote_quote "$dispatch_marker"); echo b > /proc/sysrq-trigger"
  reboot_cmd="sudo -n sh -c $(remote_quote "$reboot_inner")"

  log "Sending supervised kernel sysrq reboot"
  if command -v timeout >/dev/null 2>&1; then
    run_guarded_transport "remote reboot dispatch" "$run_dir/reboot-sysrq.txt" \
      timeout 10 sshpass -p "$PMOS_PASSWORD" ssh \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile="$run_dir/known_hosts" \
        -o ConnectTimeout=8 \
        -o PreferredAuthentications=password \
        -o PubkeyAuthentication=no \
        "$PMOS_USER@$PMOS_HOST" "$reboot_cmd" || reboot_status=$?
  else
    guarded_ssh_base "remote reboot dispatch" "$run_dir/reboot-sysrq.txt" "$reboot_cmd" || reboot_status=$?
  fi
  [ -s "$run_dir/reboot-sysrq.txt" ] && sed 's/^/[reboot-ssh] /' "$run_dir/reboot-sysrq.txt" || true
  case "$reboot_status" in
    0|124|255)
      log "Reboot SSH transport status: $reboot_status"
      ;;
    *)
      log "ERROR: reboot SSH transport failed with status $reboot_status"
      return 1
      ;;
  esac
  if ! grep -Fxq "$dispatch_marker" "$run_dir/reboot-sysrq.txt"; then
    log "ERROR: reboot dispatch proof is missing; refusing to infer dispatch from ping"
    return 1
  fi
  log "Reboot dispatch proof verified: $dispatch_marker"

  command -v ping >/dev/null 2>&1 || {
    log "ERROR: ping is required to verify the requested reboot"
    return 1
  }
  for _ in {1..20}; do
    if ! ping -c 1 -W 1 "$PMOS_HOST" > "$run_dir/reboot-ping-last.txt" 2>&1; then
      saw_ping_drop=1
      break
    fi
    sleep 1
  done
  if [ "$saw_ping_drop" -eq 1 ]; then
    log "USB ping dropped after proven reboot dispatch"
    return 0
  fi

  log "ERROR: source stayed pingable after reboot command"
  return 1
}

main() {
  local image_abs=""
  local image_sha=""
  local image_size=""
  local image_sha_before_copy=""
  local image_size_before_copy=""
  local remote_image=""
  local remote_script=""
  local source_tokens=""

  validate_seconds LOCK_WAIT_SEC "$LOCK_WAIT_SEC"
  validate_seconds WATCHER_CONTRACT_ACK_TIMEOUT_SEC "$WATCHER_CONTRACT_ACK_TIMEOUT_SEC"
  [ -n "$IMAGE" ] || die "Missing --image" 2
  [ -s "$IMAGE" ] || die "Missing or empty image: $IMAGE" 2
  [ "$PARTITION_LABEL" = "boot_b" ] || die "Refusing to flash anything except boot_b" 2
  [ -n "$PMOS_PASSWORD" ] || die "Set PMOS_PASSWORD or use --password" 2
  [ -n "$SERIAL" ] || die "Set ANDROID_SERIAL, HOTDOG_TARGET_SERIAL, or use --serial" 2
  if [ -n "$IMAGE_EXPECTED_SHA256" ] && ! [[ "$IMAGE_EXPECTED_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
    die "--image-sha256 must be exactly 64 hexadecimal characters" 2
  fi
  if { [ -n "$EXPECTED_SOURCE_BOOT_ID" ] && [ -z "$EXPECTED_SOURCE_KERNEL" ]; } ||
    { [ -z "$EXPECTED_SOURCE_BOOT_ID" ] && [ -n "$EXPECTED_SOURCE_KERNEL" ]; }; then
    die "--expected-source-boot-id and --expected-source-kernel must be used together" 2
  fi
  validate_watcher_contract_configuration

  require_cmd ssh
  require_cmd sshpass
  require_cmd sha256sum
  require_cmd stat
  require_cmd awk
  require_cmd grep
  require_cmd readlink
  require_cmd flock
  if [ "$REQUIRE_WATCHER_CONTRACT" -eq 1 ]; then
    require_cmd od
    require_cmd setsid
    require_cmd tr
  fi

  image_abs="$(readlink -f "$IMAGE")"
  image_sha="$(sha256sum "$image_abs" | awk '{ print $1 }')"
  image_size="$(stat -c '%s' "$image_abs")"
  if [ -z "$IMAGE_EXPECTED_SHA256" ]; then
    IMAGE_EXPECTED_SHA256="$image_sha"
  fi
  [ "$image_sha" = "$IMAGE_EXPECTED_SHA256" ] ||
    die "Local image SHA256 mismatch: expected $IMAGE_EXPECTED_SHA256, got $image_sha" 4

  if [ -z "$REMOTE_DIR" ]; then
    REMOTE_DIR="/tmp/hotdog-flash-boot-b-$stamp"
  fi
  case "$REMOTE_DIR" in
    /tmp/hotdog-flash-*) ;;
    *) die "--remote-dir must be below /tmp/hotdog-flash-* for this safety wrapper" 2 ;;
  esac

  remote_image="$REMOTE_DIR/boot.img"
  remote_script="$REMOTE_DIR/write-boot-b.sh"

  log "Run directory: $run_dir"
  log "Image: $image_abs"
  log "Expected image sha256: $IMAGE_EXPECTED_SHA256"
  log "Image size: $image_size bytes"
  log "Expected serial: $SERIAL"
  log "Target: $PMOS_USER@$PMOS_HOST:$PARTITION_LABEL"
  log "Reboot after verify: $REBOOT"

  if [ -n "$INHERITED_LOCK_FD" ]; then
    phone_lock_adopt_fd "$INHERITED_LOCK_FD" ||
      die "Could not adopt inherited phone-operation lock" 3
  else
    phone_lock_acquire "flash boot_b from pmOS SSH" "$LOCK_WAIT_SEC" ||
      die "Could not acquire local phone-operation lock" 3
  fi
  verify_required_watcher

  log "Probing SSH and noninteractive root"
  remote_run 'printf "ssh-ok "; uname -n; sudo -n id; test -x /etc/local.d/hotdog-devnodes.start || true'
  remote_assert_peer_identity || die "pmOS SSH peer identity check failed; refusing to write boot_b" 4

  log "Creating remote work directory: $REMOTE_DIR"
  remote_run "mkdir -p $(remote_quote "$REMOTE_DIR")"

  image_sha_before_copy="$(sha256sum "$image_abs" | awk '{ print $1 }')"
  image_size_before_copy="$(stat -c '%s' "$image_abs")"
  [ "$image_sha_before_copy" = "$IMAGE_EXPECTED_SHA256" ] ||
    die "Local image changed before transfer: expected $IMAGE_EXPECTED_SHA256, got $image_sha_before_copy" 4
  [ "$image_size_before_copy" = "$image_size" ] ||
    die "Local image size changed before transfer: expected $image_size, got $image_size_before_copy" 4

  log "Copying boot image over SSH"
  verify_required_watcher
  ssh_base "cat > $(remote_quote "$remote_image")" < "$image_abs"

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

img="${REMOTE_IMAGE:?}"
expected_sha="${EXPECTED_SHA:?}"
expected_size="${EXPECTED_SIZE:?}"
expected_serial="${EXPECTED_SERIAL:?}"
expected_source_boot_id="${EXPECTED_SOURCE_BOOT_ID:-}"
expected_source_kernel="${EXPECTED_SOURCE_KERNEL:-}"
expected_source_tokens="${EXPECTED_SOURCE_TOKENS:-}"
partition_label="${PARTITION_LABEL:-boot_b}"
partition_path="${PARTITION_PATH:-}"

assert_peer_identity() {
  local boot_id=""
  local cmdline=""
  local identity_token=""
  local kernel=""
  local old_ifs=""

  cmdline="$(cat /proc/cmdline 2>/dev/null || true)"
  boot_id="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)"
  kernel="$(uname -r 2>/dev/null || true)"
  case " $cmdline " in
    *" androidboot.serialno=$expected_serial "*) ;;
    *) die "androidboot.serialno does not match expected serial $expected_serial" 7 ;;
  esac
  for identity_token in \
    androidboot.project_codename=hotdog \
    androidboot.prjname=19801 \
    androidboot.platform_name=SM8150 \
    androidboot.oplus.brand=OnePlus
  do
    case " $cmdline " in
      *" $identity_token "*) ;;
      *) die "$identity_token is missing from /proc/cmdline" 7 ;;
    esac
  done

  if [ -n "$expected_source_boot_id" ]; then
    [ "$boot_id" = "$expected_source_boot_id" ] ||
      die "source boot_id changed: expected $expected_source_boot_id, got ${boot_id:-missing}" 7
  fi
  if [ -n "$expected_source_kernel" ]; then
    [ "$kernel" = "$expected_source_kernel" ] ||
      die "source kernel changed: expected $expected_source_kernel, got ${kernel:-missing}" 7
  fi

  old_ifs=$IFS
  IFS='
'
  for identity_token in $expected_source_tokens; do
    [ -n "$identity_token" ] || continue
    case " $cmdline " in
      *" $identity_token "*) ;;
      *) die "source token $identity_token is missing from /proc/cmdline" 7 ;;
    esac
  done
  IFS=$old_ifs
}

validate_boot_b_block_device() {
  local block_name=""
  local sys_block=""
  local partname=""
  local sectors=""
  local bytes=""

  block_name="${part_real##*/}"
  sys_block="/sys/class/block/$block_name"
  [ -r "$sys_block/uevent" ] || die "missing sysfs uevent for resolved block device: $part_real" 5
  partname="$(awk -F= '$1 == "PARTNAME" { print $2; exit }' "$sys_block/uevent")"
  [ "$partname" = "boot_b" ] || die "resolved block device is not PARTNAME=boot_b: $part_real (PARTNAME=${partname:-missing})" 5
  [ -r "$sys_block/size" ] || die "missing sysfs size for resolved block device: $part_real" 5
  sectors="$(cat "$sys_block/size")"
  case "$sectors" in
    ''|*[!0-9]*) die "invalid sysfs sector count for $part_real: $sectors" 5 ;;
  esac
  bytes=$((sectors * 512))
  [ "$bytes" -ge "$expected_size" ] || die "boot_b is too small: $bytes bytes < image $expected_size bytes" 5
  log "Validated PARTNAME=boot_b and capacity=${bytes} bytes for $part_real"
}

[ "$partition_label" = "boot_b" ] || die "Refusing to flash anything except boot_b" 2
[ -s "$img" ] || die "Missing remote image: $img" 2

# Revalidate identity in the privileged writer immediately before block access.
assert_peer_identity

actual_sha="$(sha256sum "$img" | awk '{ print $1 }')"
[ "$actual_sha" = "$expected_sha" ] || die "Remote image sha256 mismatch: $actual_sha != $expected_sha" 4
actual_size="$(wc -c < "$img" | tr -d '[:space:]')"
[ "$actual_size" = "$expected_size" ] || die "Remote image size mismatch: $actual_size != $expected_size" 4

if [ -x /etc/local.d/hotdog-devnodes.start ]; then
  log "Refreshing hotdog device nodes"
  /etc/local.d/hotdog-devnodes.start || true
fi

part=""
if [ -n "$partition_path" ]; then
  part="$partition_path"
else
  for candidate in \
    "/dev/disk/by-partlabel/$partition_label" \
    "/dev/block/by-name/$partition_label" \
    "/dev/$partition_label"
  do
    if [ -e "$candidate" ]; then
      part="$candidate"
      break
    fi
  done
fi

[ -n "$part" ] || die "Could not find $partition_label block node" 5
[ -b "$part" ] || die "Target is not a block device: $part" 5

part_real="$(readlink -f "$part" 2>/dev/null || printf '%s\n' "$part")"
[ -b "$part_real" ] || die "Resolved target is not a block device: $part_real" 5
validate_boot_b_block_device

# Nothing between this final peer check and dd may write to the target block device.
assert_peer_identity
actual_sha="$(sha256sum "$img" | awk '{ print $1 }')"
[ "$actual_sha" = "$expected_sha" ] || die "Remote image changed before dd: $actual_sha != $expected_sha" 4
actual_size="$(wc -c < "$img" | tr -d '[:space:]')"
[ "$actual_size" = "$expected_size" ] || die "Remote image size changed before dd: $actual_size != $expected_size" 4
part_link_now="$(readlink -f "$part" 2>/dev/null || printf '%s\n' "$part")"
[ "$part_link_now" = "$part_real" ] || die "boot_b symlink retargeted before dd: $part -> $part_link_now (expected $part_real)" 5
log "Writing $img to resolved block device $part_real"
dd if="$img" of="$part_real" bs=4M conv=fsync
sync

blocks=$(( (expected_size + 1048575) / 1048576 ))
log "Verifying first $expected_size bytes from resolved block device $part_real"
readback_sha="$(dd if="$part_real" bs=1048576 count="$blocks" 2>/dev/null | head -c "$expected_size" | sha256sum | awk '{ print $1 }')"
[ "$readback_sha" = "$expected_sha" ] || die "Readback sha256 mismatch: $readback_sha != $expected_sha" 6

log "boot_b verify OK: $readback_sha"
REMOTE_SCRIPT
  remote_run "chmod 700 $(remote_quote "$remote_script")"

  local remote_env=""
  if [ "${#EXPECTED_SOURCE_CMDLINE_TOKENS[@]}" -gt 0 ]; then
    printf -v source_tokens '%s\n' "${EXPECTED_SOURCE_CMDLINE_TOKENS[@]}"
    source_tokens="${source_tokens%$'\n'}"
  fi
  remote_env="REMOTE_IMAGE=$(remote_quote "$remote_image")"
  remote_env="$remote_env EXPECTED_SHA=$(remote_quote "$IMAGE_EXPECTED_SHA256")"
  remote_env="$remote_env EXPECTED_SIZE=$(remote_quote "$image_size")"
  remote_env="$remote_env EXPECTED_SERIAL=$(remote_quote "$SERIAL")"
  remote_env="$remote_env EXPECTED_SOURCE_BOOT_ID=$(remote_quote "$EXPECTED_SOURCE_BOOT_ID")"
  remote_env="$remote_env EXPECTED_SOURCE_KERNEL=$(remote_quote "$EXPECTED_SOURCE_KERNEL")"
  remote_env="$remote_env EXPECTED_SOURCE_TOKENS=$(remote_quote "$source_tokens")"
  remote_env="$remote_env PARTITION_LABEL=$(remote_quote "$PARTITION_LABEL")"
  remote_env="$remote_env PARTITION_PATH=$(remote_quote "$PARTITION_PATH")"

  log "Flashing and verifying boot_b from pmOS"
  guarded_remote_sudo_sh "remote boot_b writer/readback" "$run_dir/remote-writer-readback.txt" \
    "$remote_env sh $(remote_quote "$remote_script")"
  [ -s "$run_dir/remote-writer-readback.txt" ] &&
    sed 's/^/[remote-writer] /' "$run_dir/remote-writer-readback.txt" || true

  if [ "$KEEP_REMOTE" -eq 0 ]; then
    log "Cleaning remote work directory"
    remote_run "rm -rf $(remote_quote "$REMOTE_DIR")" || true
  else
    log "Keeping remote work directory: $REMOTE_DIR"
  fi

  if [ "$REBOOT" -eq 1 ]; then
    log "Rebooting phone now"
    verify_required_watcher
    remote_force_reboot
  else
    log "No reboot requested; phone should remain reachable over pmOS SSH"
  fi

  log "Done: $run_dir"
}

main "$@"
