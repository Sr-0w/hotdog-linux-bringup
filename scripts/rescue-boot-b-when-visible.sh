#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=/dev/null
source "$(dirname "$0")/env.sh"
# shellcheck source=/dev/null
source "$(dirname "$0")/phone-lock.sh"

SERIAL="${ANDROID_SERIAL:-$HOTDOG_TARGET_SERIAL}"
RESTORE_IMAGE="${RESTORE_IMAGE:-$HOTDOG_STABLE_PMOS_BOOT_B}"
RESTORE_IMAGE_EXPECTED_SHA256="${RESTORE_IMAGE_EXPECTED_SHA256:-}"
RESTORE_DTBO_IMAGE="${RESTORE_DTBO_IMAGE:-}"
RESTORE_DTBO_SHA256="${RESTORE_DTBO_SHA256:-}"
BOOT_B_ONLY=0
DUAL_PARTITION=0
DTBO_OPTION_SEEN=0
TIMEOUT_SEC="${TIMEOUT_SEC:-21600}"
POLL_SEC="${POLL_SEC:-5}"
EXPECTED_FASTBOOT_PRODUCTS="${EXPECTED_FASTBOOT_PRODUCTS:-msmnile hotdog}"
AFTER_RESTORE="${AFTER_RESTORE:-recovery}"
READY_FILE=""
FASTBOOT_CMD_TIMEOUT_SEC="${FASTBOOT_CMD_TIMEOUT_SEC:-15}"
CONTRACT_NONCE=""
CONTRACT_CHALLENGE_FILE=""
CONTRACT_ACK_FILE=""
CONTRACT_ACTIVE=0
CONTRACT_VERSION=0
RESTORE_COMPLETE_FILE=""
WATCHER_SCRIPT_PATH=""
WATCHER_STARTTIME=""

usage() {
  cat <<'USAGE'
Usage: rescue-boot-b-when-visible.sh [options]

Persistent rescue watcher for the current hotdog bring-up state. It waits until
the target phone appears in fastboot or recovery ADB, restores a known boot_b
image, performs the configured handoff, and remains armed because fastboot has
no strict cryptographic readback path.

Options:
  --serial SERIAL        Target serial. Defaults to ANDROID_SERIAL.
  --restore-boot-b FILE  Known-good boot_b image to flash.
  --restore-boot-b-sha256 SHA256
                         Expected restore image hash. If omitted, the startup
                         hash is pinned for the lifetime of this watcher.
  --restore-dtbo-b FILE  Known-good dtbo_b image for explicit dual mode.
  --restore-dtbo-b-sha256 SHA256
                         Required exact hash whenever --restore-dtbo-b is used.
  --boot-b-only          Explicitly clear and forbid every dtbo restore input.
  --dual-partition       Explicitly enable the attested dtbo_b + boot_b mode.
                         Requires both restore DTBO arguments and a versioned
                         watcher contract.
  --restore-complete-file FILE
                         Shared dual-watcher marker published only after the
                         ordered restore and handoff are accepted.
  --after-restore MODE   recovery, system, bootloader, or none. Default: recovery.
  --timeout SEC          Seconds to wait. Default: 21600.
  --poll SEC             Poll interval. Default: 5.
  --ready-file FILE      Write readiness metadata here after local checks pass.
  --contract-nonce HEX   Enable the versioned watcher contract with this nonce.
  --contract-challenge-file FILE
                         Read fresh liveness challenges from FILE.
  --contract-ack-file FILE
                         Atomically publish challenge acknowledgements to FILE.
  -h, --help             Show this help.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --serial)
      [ "$#" -ge 2 ] || { echo "Missing value for --serial" >&2; exit 2; }
      SERIAL="$2"
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
    --restore-dtbo-b)
      [ "$#" -ge 2 ] || { echo "Missing value for --restore-dtbo-b" >&2; exit 2; }
      RESTORE_DTBO_IMAGE="$2"
      DTBO_OPTION_SEEN=1
      shift
      ;;
    --restore-dtbo-b-sha256)
      [ "$#" -ge 2 ] || { echo "Missing value for --restore-dtbo-b-sha256" >&2; exit 2; }
      RESTORE_DTBO_SHA256="${2,,}"
      DTBO_OPTION_SEEN=1
      shift
      ;;
    --boot-b-only)
      BOOT_B_ONLY=1
      ;;
    --dual-partition)
      DUAL_PARTITION=1
      ;;
    --restore-complete-file)
      [ "$#" -ge 2 ] || { echo "Missing value for --restore-complete-file" >&2; exit 2; }
      RESTORE_COMPLETE_FILE="$2"
      shift
      ;;
    --after-restore)
      [ "$#" -ge 2 ] || { echo "Missing value for --after-restore" >&2; exit 2; }
      AFTER_RESTORE="$2"
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
    --ready-file)
      [ "$#" -ge 2 ] || { echo "Missing value for --ready-file" >&2; exit 2; }
      READY_FILE="$2"
      shift
      ;;
    --contract-nonce)
      [ "$#" -ge 2 ] || { echo "Missing value for --contract-nonce" >&2; exit 2; }
      CONTRACT_NONCE="${2,,}"
      shift
      ;;
    --contract-challenge-file)
      [ "$#" -ge 2 ] || { echo "Missing value for --contract-challenge-file" >&2; exit 2; }
      CONTRACT_CHALLENGE_FILE="$2"
      shift
      ;;
    --contract-ack-file)
      [ "$#" -ge 2 ] || { echo "Missing value for --contract-ack-file" >&2; exit 2; }
      CONTRACT_ACK_FILE="$2"
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

if [ "$BOOT_B_ONLY" -eq 1 ]; then
  RESTORE_DTBO_IMAGE=""
  RESTORE_DTBO_SHA256=""
fi

export ANDROID_SERIAL="$SERIAL"

stamp="$(date +%F-%H%M%S)"
run_dir="$HOTDOG_LOG_ROOT/rescue-boot-b-when-visible-$stamp"
mkdir -p "$run_dir"
if [ "${HOTDOG_RESCUE_LOG_TEE:-1}" = "1" ]; then
  exec > >(tee "$run_dir/run.log") 2>&1
else
  exec >> "$run_dir/run.log" 2>&1
fi

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

die() {
  log "ERROR: $1"
  exit "${2:-1}"
}

# shellcheck disable=SC2329 # Invoked by the EXIT trap below.
cleanup() {
  local status=$?
  if [ -n "$READY_FILE" ]; then
    rm -f "$READY_FILE"
  fi
  if [ "$CONTRACT_ACTIVE" -eq 1 ]; then
    rm -f "$CONTRACT_CHALLENGE_FILE" "$CONTRACT_ACK_FILE"
  fi
  log "Exiting with status $status"
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

publish_ready() {
  local tmp=""

  [ -n "$READY_FILE" ] || return 0
  tmp="$READY_FILE.$$.tmp"
  umask 077
  if [ "$CONTRACT_ACTIVE" -eq 1 ]; then
    if [ "$CONTRACT_VERSION" -eq 2 ]; then
      {
        printf 'contract_version=2\n'
        printf 'pid=%s\n' "$$"
        printf 'starttime=%s\n' "$WATCHER_STARTTIME"
        printf 'serial=%s\n' "$SERIAL"
        printf 'restore_image=%s\n' "$RESTORE_IMAGE"
        printf 'restore_sha256=%s\n' "$RESTORE_IMAGE_EXPECTED_SHA256"
        printf 'boot_b_only=1\n'
        printf 'restore_dtbo_image=none\n'
        printf 'restore_dtbo_sha256=none\n'
        printf 'nonce=%s\n' "$CONTRACT_NONCE"
        printf 'watcher_script=%s\n' "$WATCHER_SCRIPT_PATH"
        printf 'challenge_file=%s\n' "$CONTRACT_CHALLENGE_FILE"
        printf 'ack_file=%s\n' "$CONTRACT_ACK_FILE"
      } > "$tmp" || die "Could not write rescue watcher readiness file: $READY_FILE" 3
    else
      {
        printf 'contract_version=3\n'
        printf 'pid=%s\n' "$$"
        printf 'starttime=%s\n' "$WATCHER_STARTTIME"
        printf 'serial=%s\n' "$SERIAL"
        printf 'restore_image=%s\n' "$RESTORE_IMAGE"
        printf 'restore_sha256=%s\n' "$RESTORE_IMAGE_EXPECTED_SHA256"
        printf 'boot_b_only=0\n'
        printf 'dual_partition=1\n'
        printf 'restore_dtbo_image=%s\n' "$RESTORE_DTBO_IMAGE"
        printf 'restore_dtbo_sha256=%s\n' "$RESTORE_DTBO_SHA256"
        printf 'restore_complete_file=%s\n' "$RESTORE_COMPLETE_FILE"
        printf 'nonce=%s\n' "$CONTRACT_NONCE"
        printf 'watcher_script=%s\n' "$WATCHER_SCRIPT_PATH"
        printf 'challenge_file=%s\n' "$CONTRACT_CHALLENGE_FILE"
        printf 'ack_file=%s\n' "$CONTRACT_ACK_FILE"
      } > "$tmp" || die "Could not write rescue watcher readiness file: $READY_FILE" 3
    fi
  else
    {
      printf 'pid=%s\n' "$$"
      printf 'serial=%s\n' "$SERIAL"
      printf 'restore_image=%s\n' "$RESTORE_IMAGE"
      printf 'restore_sha256=%s\n' "$RESTORE_IMAGE_EXPECTED_SHA256"
    } > "$tmp" || die "Could not write rescue watcher readiness file: $READY_FILE" 3
  fi
  mv -f "$tmp" "$READY_FILE" || die "Could not publish rescue watcher readiness file: $READY_FILE" 3
  log "Readiness published: $READY_FILE"
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

publish_contract_ack() {
  local actual=""
  local expected_prefix=""
  local challenge=""
  local tmp=""

  [ "$CONTRACT_ACTIVE" -eq 1 ] || return 0
  [ -r "$CONTRACT_CHALLENGE_FILE" ] || return 0
  actual="$(< "$CONTRACT_CHALLENGE_FILE")" || return 0
  expected_prefix="contract_version=$CONTRACT_VERSION"$'\n'"nonce=$CONTRACT_NONCE"$'\n'
  case "$actual" in
    "$expected_prefix"challenge=*) ;;
    *) return 0 ;;
  esac
  [ "$(printf '%s\n' "$actual" | wc -l)" -eq 3 ] || return 0
  challenge="${actual##*$'\n'challenge=}"
  [[ "$challenge" =~ ^[0-9a-f]{64}$ ]] || return 0

  tmp="$CONTRACT_ACK_FILE.$$.tmp"
  umask 077
  {
    printf 'contract_version=%s\n' "$CONTRACT_VERSION"
    printf 'pid=%s\n' "$$"
    printf 'starttime=%s\n' "$WATCHER_STARTTIME"
    printf 'nonce=%s\n' "$CONTRACT_NONCE"
    printf 'challenge=%s\n' "$challenge"
  } > "$tmp" || { rm -f "$tmp"; return 0; }
  mv -f "$tmp" "$CONTRACT_ACK_FILE" || { rm -f "$tmp"; return 0; }
}
trap 'publish_contract_ack || true' USR1

adb_state() {
  adb devices > "$run_dir/adb-devices-last.txt" 2>&1 || true
  awk -v serial="$SERIAL" '$1 == serial { print $2; found=1 } END { if (!found) print "" }' "$run_dir/adb-devices-last.txt"
}

fastboot_present() {
  hotdog_fastboot_devices > "$run_dir/fastboot-devices-last.txt" 2>&1 || true
  awk -v serial="$SERIAL" 'NF >= 1 && $1 == serial { found=1 } END { exit found ? 0 : 1 }' "$run_dir/fastboot-devices-last.txt"
}

fastboot_do() {
  fastboot -s "$SERIAL" "$@"
}

adb_do() {
  adb -s "$SERIAL" "$@"
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

  timeout "$FASTBOOT_CMD_TIMEOUT_SEC" fastboot -s "$SERIAL" getvar "$var" > "$file" 2>&1 || true
  awk -v var="$var" '
    index($0, var ":") {
      sub(".*" var ":[[:space:]]*", "", $0)
      gsub(/\r/, "", $0)
      print $0
      exit
    }
  ' "$file"
}

validate_fastboot_identity() {
  local product=""
  local serialno=""
  local selected_serial=""
  local unlocked=""
  local expected=""
  local product_ok=1

  serialno="$(normalize_serial_value "$(get_fastboot_var serialno)")"
  selected_serial="$(normalize_serial_value "$SERIAL")"
  product="$(normalize_value "$(get_fastboot_var product)")"
  unlocked="$(normalize_value "$(get_fastboot_var unlocked)")"
  [ -n "$serialno" ] || { log "REFUSING restore: fastboot serialno is missing"; return 1; }
  [ "$serialno" = "$selected_serial" ] || {
    log "REFUSING restore: selected serial $SERIAL but getvar serialno reports $serialno"
    return 1
  }
  for expected in $EXPECTED_FASTBOOT_PRODUCTS; do
    expected="$(normalize_value "$expected")"
    [ -n "$expected" ] || continue
    if [ "$product" = "$expected" ]; then
      product_ok=0
      break
    fi
  done
  [ "$product_ok" -eq 0 ] || {
    log "REFUSING restore: expected product [$EXPECTED_FASTBOOT_PRODUCTS], got ${product:-missing}"
    return 1
  }
  case "$unlocked" in
    yes|true|1|unlocked) ;;
    *) log "REFUSING restore: fastboot unlocked state is ${unlocked:-missing}"; return 1 ;;
  esac
  log "Fastboot identity OK: serial=$SERIAL product=$product unlocked=$unlocked"
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
  local partition_label="${1:-boot_b}"
  local restore_file="${2:-$RESTORE_IMAGE}"
  local slot_base=""
  local current_slot=""
  local has_slot=""
  local is_userspace=""
  local partition_size_raw=""
  local partition_size=""
  local restore_size=""

  case "$partition_label" in
    boot_b|dtbo_b) slot_base="${partition_label%_b}" ;;
    *) log "REFUSING restore: unsupported partition label $partition_label"; return 1 ;;
  esac
  [ -s "$restore_file" ] || {
    log "REFUSING restore: missing image for $partition_label: $restore_file"
    return 1
  }

  validate_fastboot_identity || return
  is_userspace="$(normalize_value "$(get_fastboot_var is-userspace)")"
  case "$is_userspace" in
    no|false|0) ;;
    *) log "REFUSING restore: bootloader context not proven (is-userspace=${is_userspace:-missing})"; return 1 ;;
  esac
  current_slot="$(normalize_value "$(get_fastboot_var current-slot)")"
  case "$current_slot" in
    a|b) ;;
    *) log "REFUSING restore: current-slot is ${current_slot:-missing}"; return 1 ;;
  esac
  has_slot="$(normalize_value "$(get_fastboot_var "has-slot:$slot_base")")"
  case "$has_slot" in
    yes|true|1) ;;
    *) log "REFUSING restore: has-slot:$slot_base is ${has_slot:-missing}"; return 1 ;;
  esac
  partition_size_raw="$(get_fastboot_var "partition-size:$partition_label")"
  partition_size="$(parse_fastboot_size "$partition_size_raw")" || {
    log "REFUSING restore: invalid partition-size:$partition_label ${partition_size_raw:-missing}"
    return 1
  }
  restore_size="$(stat -c '%s' "$restore_file")"
  [ "$partition_size" -ge "$restore_size" ] || {
    log "REFUSING restore: $partition_label size $partition_size is below restore size $restore_size"
    return 1
  }
  log "Fastboot restore context OK: slot=$current_slot partition=$partition_label size=$partition_size"
}

wait_recovery_adb() {
  local deadline=$((SECONDS + 120))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if [ "$(adb_state)" = "recovery" ]; then
      log "Recovery ADB visible"
      adb devices -l > "$run_dir/adb-recovery-final.txt" 2>&1 || true
      return 0
    fi
    sleep 2
  done
  return 1
}

restore_from_fastboot() {
  if dual_restore_complete; then
    log "Peer watcher already published the accepted dual restore; holding without reflashing"
    return 0
  fi
  validate_fastboot_restore_context boot_b "$RESTORE_IMAGE" || return 1
  get_fastboot_var current-slot | tee "$run_dir/current-slot-before.txt" || true
  get_fastboot_var slot-retry-count:b | tee "$run_dir/slot-retry-count-b-before.txt" || true
  get_fastboot_var slot-unbootable:b | tee "$run_dir/slot-unbootable-b-before.txt" || true

  if [ "$DUAL_PARTITION" -eq 1 ]; then
    verify_restore_dtbo_hash || return 1
    validate_fastboot_restore_context dtbo_b "$RESTORE_DTBO_IMAGE" || return 1
    verify_restore_dtbo_hash || return 1
    log "Restoring dtbo_b"
    printf '%s  %s\n' "$RESTORE_DTBO_SHA256" "$RESTORE_DTBO_IMAGE" |
      tee "$run_dir/restore-dtbo-image-sha256.txt"
    verify_restore_dtbo_hash || return 1
    if ! fastboot_do flash dtbo_b "$RESTORE_DTBO_IMAGE" 2>&1 | tee "$run_dir/fastboot-flash-dtbo-b-restore.txt"; then
      log "Restore attempt failed while flashing dtbo_b; watcher remains armed"
      return 1
    fi
  fi
  verify_restore_image_hash || return 1
  log "Restoring boot_b"
  sha256sum "$RESTORE_IMAGE" | tee "$run_dir/restore-image-sha256.txt"
  verify_restore_image_hash || return 1
  validate_fastboot_restore_context boot_b "$RESTORE_IMAGE" || return 1
  if ! fastboot_do flash boot_b "$RESTORE_IMAGE" 2>&1 | tee "$run_dir/fastboot-flash-boot-b-restore.txt"; then
    log "Restore attempt failed while flashing boot_b; watcher remains armed"
    return 1
  fi
  verify_restore_image_hash || return 1
  validate_fastboot_restore_context boot_b "$RESTORE_IMAGE" || return 1
  if ! fastboot_do --set-active=b 2>&1 | tee "$run_dir/fastboot-set-active-b.txt"; then
    log "boot_b write was accepted but set-active failed; watcher remains armed"
    return 1
  fi
  get_fastboot_var slot-retry-count:b | tee "$run_dir/slot-retry-count-b-after.txt" || true
  get_fastboot_var slot-unbootable:b | tee "$run_dir/slot-unbootable-b-after.txt" || true

  case "$AFTER_RESTORE" in
    recovery)
      log "Rebooting to recovery"
      if ! fastboot_do reboot recovery 2>&1 | tee "$run_dir/fastboot-reboot-recovery.txt"; then
        [ "$DUAL_PARTITION" -eq 0 ] || return 1
      fi
      if wait_recovery_adb; then
        collect_recovery_crash_artifacts "after-restore"
      else
        log "Recovery ADB did not appear after restore"
      fi
      ;;
    system)
      log "Rebooting system"
      if ! fastboot_do reboot 2>&1 | tee "$run_dir/fastboot-reboot-system.txt"; then
        [ "$DUAL_PARTITION" -eq 0 ] || return 1
      fi
      ;;
    bootloader)
      log "Rebooting bootloader"
      if ! fastboot_do reboot bootloader 2>&1 | tee "$run_dir/fastboot-reboot-bootloader.txt"; then
        [ "$DUAL_PARTITION" -eq 0 ] || return 1
      fi
      ;;
    none)
      log "Leaving target in fastboot after restore"
      ;;
    *)
      die "Invalid --after-restore mode: $AFTER_RESTORE" 2
      ;;
  esac
  if [ "$DUAL_PARTITION" -eq 1 ]; then
    publish_dual_restore_complete || {
      log "Could not publish the accepted dual restore marker; watcher remains armed"
      return 1
    }
    log "Accepted dual restore marker published: $RESTORE_COMPLETE_FILE"
  fi
  log "Fastboot accepted the restore, but no strict readback is available; watcher remains armed"
}

verify_restore_image_hash() {
  local actual=""

  actual="$(sha256sum "$RESTORE_IMAGE" | awk '{ print $1 }')"
  if [ "$actual" != "$RESTORE_IMAGE_EXPECTED_SHA256" ]; then
    log "REFUSING restore: image hash mismatch, expected $RESTORE_IMAGE_EXPECTED_SHA256, got $actual"
    return 1
  fi
}

verify_restore_dtbo_hash() {
  local actual=""

  [ -n "$RESTORE_DTBO_IMAGE" ] || return 0
  actual="$(sha256sum "$RESTORE_DTBO_IMAGE" | awk '{ print $1 }')"
  if [ "$actual" != "$RESTORE_DTBO_SHA256" ]; then
    log "REFUSING restore: dtbo image hash mismatch, expected $RESTORE_DTBO_SHA256, got $actual"
    return 1
  fi
}

dual_restore_complete() {
  local actual=""
  local expected=""

  [ "$DUAL_PARTITION" -eq 1 ] && [ -r "$RESTORE_COMPLETE_FILE" ] || return 1
  actual="$(< "$RESTORE_COMPLETE_FILE")"
  expected="$(dual_restore_marker_expected)"
  [ "$actual" = "$expected" ]
}

dual_restore_marker_expected() {
  printf 'contract_version=3\n'
  printf 'serial=%s\n' "$SERIAL"
  printf 'restore_dtbo_sha256=%s\n' "$RESTORE_DTBO_SHA256"
  printf 'restore_boot_sha256=%s\n' "$RESTORE_IMAGE_EXPECTED_SHA256"
  printf 'order=dtbo_b,boot_b,set_active_b,reboot\n'
}

publish_dual_restore_complete() {
  local tmp=""

  [ "$DUAL_PARTITION" -eq 1 ] || return 0
  tmp="$RESTORE_COMPLETE_FILE.$$.tmp"
  umask 077
  dual_restore_marker_expected > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$RESTORE_COMPLETE_FILE"
}

main() {
  local deadline=0
  local fastboot_deadline=0
  local fastboot_restore_accepted=0
  local fastboot_seen_but_lock_busy=0
  local last_status=0
  local state=""

  validate_seconds TIMEOUT_SEC "$TIMEOUT_SEC"
  validate_seconds POLL_SEC "$POLL_SEC"
  validate_seconds FASTBOOT_CMD_TIMEOUT_SEC "$FASTBOOT_CMD_TIMEOUT_SEC"
  [ -n "$SERIAL" ] || die "Set ANDROID_SERIAL or HOTDOG_TARGET_SERIAL" 2
  [ "$BOOT_B_ONLY" -eq 0 ] || [ "$DUAL_PARTITION" -eq 0 ] ||
    die "--boot-b-only and --dual-partition are mutually exclusive" 2
  case "$AFTER_RESTORE" in
    recovery|system|bootloader|none) ;;
    *) die "--after-restore must be one of: recovery, system, bootloader, none" 2 ;;
  esac
  [ -s "$RESTORE_IMAGE" ] || die "Missing restore image: $RESTORE_IMAGE" 2
  if [ -n "$CONTRACT_NONCE" ] || [ -n "$CONTRACT_CHALLENGE_FILE" ] || [ -n "$CONTRACT_ACK_FILE" ]; then
    [[ "$CONTRACT_NONCE" =~ ^[0-9a-f]{64}$ ]] || die "--contract-nonce must be exactly 64 hexadecimal characters" 2
    [ -n "$READY_FILE" ] || die "Watcher contract requires --ready-file" 2
    [ -n "$CONTRACT_CHALLENGE_FILE" ] || die "Watcher contract requires --contract-challenge-file" 2
    [ -n "$CONTRACT_ACK_FILE" ] || die "Watcher contract requires --contract-ack-file" 2
    [ "$READY_FILE" != "$CONTRACT_CHALLENGE_FILE" ] || die "Watcher contract files must be distinct" 2
    [ "$READY_FILE" != "$CONTRACT_ACK_FILE" ] || die "Watcher contract files must be distinct" 2
    [ "$CONTRACT_CHALLENGE_FILE" != "$CONTRACT_ACK_FILE" ] || die "Watcher contract files must be distinct" 2
    if [ "$BOOT_B_ONLY" -eq 1 ]; then
      CONTRACT_VERSION=2
      [ -z "$RESTORE_COMPLETE_FILE" ] || die "boot_b-only contract refuses --restore-complete-file" 2
    elif [ "$DUAL_PARTITION" -eq 1 ]; then
      CONTRACT_VERSION=3
      [ -n "$RESTORE_COMPLETE_FILE" ] || die "dual contract requires --restore-complete-file" 2
      [ "$READY_FILE" != "$RESTORE_COMPLETE_FILE" ] || die "Watcher contract files must be distinct" 2
      [ "$CONTRACT_CHALLENGE_FILE" != "$RESTORE_COMPLETE_FILE" ] || die "Watcher contract files must be distinct" 2
      [ "$CONTRACT_ACK_FILE" != "$RESTORE_COMPLETE_FILE" ] || die "Watcher contract files must be distinct" 2
    else
      die "Versioned watcher contracts require --boot-b-only or --dual-partition" 2
    fi
    command -v readlink >/dev/null 2>&1 || die "Missing readlink" 127
    WATCHER_SCRIPT_PATH="$(readlink -f "$0")"
    WATCHER_STARTTIME="$(process_starttime "$$")" || die "Could not read watcher process starttime" 3
    CONTRACT_ACTIVE=1
  fi
  if [ -z "$RESTORE_IMAGE_EXPECTED_SHA256" ]; then
    RESTORE_IMAGE_EXPECTED_SHA256="$(sha256sum "$RESTORE_IMAGE" | awk '{ print $1 }')"
  elif ! [[ "$RESTORE_IMAGE_EXPECTED_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
    die "--restore-boot-b-sha256 must be exactly 64 hexadecimal characters" 2
  fi
  verify_restore_image_hash
  if [ "$DUAL_PARTITION" -eq 1 ]; then
    [ -n "$RESTORE_DTBO_IMAGE" ] || die "--restore-dtbo-b-sha256 requires --restore-dtbo-b" 2
    [ -n "$RESTORE_DTBO_SHA256" ] || die "--restore-dtbo-b requires --restore-dtbo-b-sha256" 2
    [ -s "$RESTORE_DTBO_IMAGE" ] || die "Missing restore dtbo image: $RESTORE_DTBO_IMAGE" 2
    [[ "$RESTORE_DTBO_SHA256" =~ ^[0-9a-f]{64}$ ]] ||
      die "--restore-dtbo-b-sha256 must be exactly 64 hexadecimal characters" 2
    verify_restore_dtbo_hash || die "Restore dtbo image failed its startup hash validation" 3
  elif [ "$DTBO_OPTION_SEEN" -eq 1 ] || [ -n "$RESTORE_DTBO_IMAGE" ] || [ -n "$RESTORE_DTBO_SHA256" ]; then
    die "dtbo restore inputs require explicit --dual-partition" 2
  fi
  [ "$DUAL_PARTITION" -eq 0 ] || [ "$CONTRACT_ACTIVE" -eq 1 ] ||
    die "dual-partition mode requires a versioned watcher contract" 2
  command -v adb >/dev/null 2>&1 || die "Missing adb" 127
  command -v fastboot >/dev/null 2>&1 || die "Missing fastboot" 127
  command -v sha256sum >/dev/null 2>&1 || die "Missing sha256sum" 127
  command -v stat >/dev/null 2>&1 || die "Missing stat" 127
  command -v timeout >/dev/null 2>&1 || die "Missing timeout" 127
  command -v flock >/dev/null 2>&1 || die "Missing flock" 127

  log "Run directory: $run_dir"
  log "Target serial: $SERIAL"
  log "Restore image: $RESTORE_IMAGE"
  log "Restore image SHA256: $RESTORE_IMAGE_EXPECTED_SHA256"
  if [ "$BOOT_B_ONLY" -eq 1 ]; then
    log "Restore scope: boot_b-only-v2"
  elif [ "$DUAL_PARTITION" -eq 1 ]; then
    log "Restore scope: dual-partition-v3"
  else
    log "Restore scope: legacy boot_b-only"
  fi
  log "Restore dtbo image: ${RESTORE_DTBO_IMAGE:-none}"
  log "Restore dtbo image SHA256: ${RESTORE_DTBO_SHA256:-none}"
  log "After restore: $AFTER_RESTORE"
  log "Timeout: ${TIMEOUT_SEC}s"
  log "Watcher contract: $CONTRACT_ACTIVE"
  publish_ready

  deadline=$((SECONDS + TIMEOUT_SEC))
  while [ "$SECONDS" -lt "$deadline" ]; do
    publish_contract_ack || true
    if dual_restore_complete; then
      fastboot_restore_accepted=1
      sleep "$POLL_SEC"
      continue
    fi
    if fastboot_present; then
      if [ "$fastboot_restore_accepted" -eq 1 ]; then
        sleep "$POLL_SEC"
        continue
      fi
      log "Target visible in fastboot"
      if ! phone_lock_acquire "rescue restore boot_b" 0; then
        log "Phone operation lock is busy; leaving target untouched and retrying"
        sleep "$POLL_SEC"
        continue
      fi
      if restore_from_fastboot; then
        fastboot_restore_accepted=1
      else
        log "Fastboot restore was not completed safely; retrying while watcher remains alive"
      fi
      phone_lock_release
      sleep "$POLL_SEC"
      continue
    fi
    state="$(adb_state)"
    if [ "$fastboot_restore_accepted" -eq 1 ] && [ "$state" = "recovery" ]; then
      if [ $((SECONDS - last_status)) -ge 60 ]; then
        log "Accepted restore is visible in recovery; holding without reflashing"
        last_status=$SECONDS
      fi
      sleep "$POLL_SEC"
      continue
    fi
    fastboot_restore_accepted=0

    if [ "$state" = "recovery" ]; then
      log "Target visible in recovery ADB; rebooting to bootloader for boot_b restore"
      if ! phone_lock_acquire "rescue recovery-to-fastboot boot_b restore" 0; then
        log "Phone operation lock is busy; leaving recovery untouched and retrying"
        sleep "$POLL_SEC"
        continue
      fi
      collect_recovery_crash_artifacts "direct-recovery-before-restore"
      if ! adb_do reboot bootloader; then
        log "Recovery-to-bootloader request failed; watcher remains armed"
        phone_lock_release
        sleep "$POLL_SEC"
        continue
      fi
      phone_lock_release
      fastboot_deadline=$((SECONDS + 90))
      fastboot_seen_but_lock_busy=0
      while [ "$SECONDS" -lt "$fastboot_deadline" ]; do
        if fastboot_present; then
          if ! phone_lock_acquire "rescue restore boot_b" 0; then
            log "Phone operation lock is busy after recovery handoff; retrying outer wait loop"
            fastboot_seen_but_lock_busy=1
            break
          fi
          if restore_from_fastboot; then
            fastboot_restore_accepted=1
          else
            log "Restore after recovery handoff failed safely; continuing to watch"
          fi
          phone_lock_release
          break
        fi
        sleep 2
      done
      if [ "$fastboot_seen_but_lock_busy" -eq 1 ]; then
        sleep "$POLL_SEC"
        continue
      fi
      if [ "$fastboot_restore_accepted" -eq 0 ]; then
        log "Recovery rebooted but no verified fastboot restore completed; watcher remains armed"
      fi
      continue
    fi

    if [ $((SECONDS - last_status)) -ge 60 ]; then
      log "Still waiting for $SERIAL in fastboot or recovery ADB"
      last_status=$SECONDS
    fi
    sleep "$POLL_SEC"
  done

  die "Timed out waiting for target visibility" 3
}

main "$@"
