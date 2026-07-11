#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/env.sh"
source "$(dirname "$0")/phone-lock.sh"

SERIAL="${ANDROID_SERIAL:-$HOTDOG_TARGET_SERIAL}"
RESTORE_IMAGE="${RESTORE_IMAGE:-$HOTDOG_STABLE_PMOS_BOOT_B}"
RESTORE_DTBO_IMAGE="${RESTORE_DTBO_IMAGE:-}"
TIMEOUT_SEC="${TIMEOUT_SEC:-21600}"
POLL_SEC="${POLL_SEC:-5}"
EXPECTED_FASTBOOT_PRODUCTS="${EXPECTED_FASTBOOT_PRODUCTS:-msmnile hotdog}"
AFTER_RESTORE="${AFTER_RESTORE:-recovery}"

usage() {
  cat <<'USAGE'
Usage: rescue-boot-b-when-visible.sh [options]

One-shot rescue watcher for the current hotdog bring-up state. It waits until
the target phone appears in fastboot or recovery ADB, restores a known boot_b
image, reboots to recovery, and exits.

Options:
  --serial SERIAL        Target serial. Defaults to ANDROID_SERIAL.
  --restore-boot-b FILE  Known-good boot_b image to flash.
  --restore-dtbo-b FILE  Optional known-good dtbo_b image to flash before boot_b.
  --after-restore MODE   recovery, system, bootloader, or none. Default: recovery.
  --timeout SEC          Seconds to wait. Default: 21600.
  --poll SEC             Poll interval. Default: 5.
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
    --restore-dtbo-b)
      [ "$#" -ge 2 ] || { echo "Missing value for --restore-dtbo-b" >&2; exit 2; }
      RESTORE_DTBO_IMAGE="$2"
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

cleanup() {
  local status=$?
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

get_fastboot_var() {
  local var="$1"
  local safe_name="${var//[:\/]/_}"
  local file="$run_dir/getvar-${safe_name}.txt"

  fastboot_do getvar "$var" > "$file" 2>&1 || true
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
  local expected=""
  local product_ok=1

  product="$(normalize_value "$(get_fastboot_var product)")"
  for expected in $EXPECTED_FASTBOOT_PRODUCTS; do
    expected="$(normalize_value "$expected")"
    [ -n "$expected" ] || continue
    if [ "$product" = "$expected" ]; then
      product_ok=0
      break
    fi
  done
  [ "$product_ok" -eq 0 ] || die "Fastboot product mismatch: expected [$EXPECTED_FASTBOOT_PRODUCTS], got ${product:-missing}" 2
  log "Fastboot identity OK: serial=$SERIAL product=$product"
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
  validate_fastboot_identity
  get_fastboot_var current-slot | tee "$run_dir/current-slot-before.txt" || true
  get_fastboot_var slot-retry-count:b | tee "$run_dir/slot-retry-count-b-before.txt" || true
  get_fastboot_var slot-unbootable:b | tee "$run_dir/slot-unbootable-b-before.txt" || true

  log "Restoring boot_b"
  sha256sum "$RESTORE_IMAGE" | tee "$run_dir/restore-image-sha256.txt"
  if [ -n "$RESTORE_DTBO_IMAGE" ]; then
    log "Restoring dtbo_b"
    sha256sum "$RESTORE_DTBO_IMAGE" | tee "$run_dir/restore-dtbo-image-sha256.txt"
    fastboot_do flash dtbo_b "$RESTORE_DTBO_IMAGE" 2>&1 | tee "$run_dir/fastboot-flash-dtbo-b-restore.txt"
  fi
  fastboot_do flash boot_b "$RESTORE_IMAGE" 2>&1 | tee "$run_dir/fastboot-flash-boot-b-restore.txt"
  fastboot_do --set-active=b 2>&1 | tee "$run_dir/fastboot-set-active-b.txt"
  get_fastboot_var slot-retry-count:b | tee "$run_dir/slot-retry-count-b-after.txt" || true
  get_fastboot_var slot-unbootable:b | tee "$run_dir/slot-unbootable-b-after.txt" || true

  case "$AFTER_RESTORE" in
    recovery)
      log "Rebooting to recovery"
      fastboot_do reboot recovery 2>&1 | tee "$run_dir/fastboot-reboot-recovery.txt" || true
      if wait_recovery_adb; then
        collect_recovery_crash_artifacts "after-restore"
      else
        log "Recovery ADB did not appear after restore"
      fi
      ;;
    system)
      log "Rebooting system"
      fastboot_do reboot 2>&1 | tee "$run_dir/fastboot-reboot-system.txt" || true
      ;;
    bootloader)
      log "Rebooting bootloader"
      fastboot_do reboot bootloader 2>&1 | tee "$run_dir/fastboot-reboot-bootloader.txt" || true
      ;;
    none)
      log "Leaving target in fastboot after restore"
      ;;
    *)
      die "Invalid --after-restore mode: $AFTER_RESTORE" 2
      ;;
  esac
  log "Rescue complete"
}

main() {
  validate_seconds TIMEOUT_SEC "$TIMEOUT_SEC"
  validate_seconds POLL_SEC "$POLL_SEC"
  [ -n "$SERIAL" ] || die "Set ANDROID_SERIAL or HOTDOG_TARGET_SERIAL" 2
  case "$AFTER_RESTORE" in
    recovery|system|bootloader|none) ;;
    *) die "--after-restore must be one of: recovery, system, bootloader, none" 2 ;;
  esac
  [ -s "$RESTORE_IMAGE" ] || die "Missing restore image: $RESTORE_IMAGE" 2
  if [ -n "$RESTORE_DTBO_IMAGE" ]; then
    [ -s "$RESTORE_DTBO_IMAGE" ] || die "Missing restore dtbo image: $RESTORE_DTBO_IMAGE" 2
  fi
  command -v adb >/dev/null 2>&1 || die "Missing adb" 127
  command -v fastboot >/dev/null 2>&1 || die "Missing fastboot" 127
  command -v sha256sum >/dev/null 2>&1 || die "Missing sha256sum" 127

  log "Run directory: $run_dir"
  log "Target serial: $SERIAL"
  log "Restore image: $RESTORE_IMAGE"
  log "Restore dtbo image: ${RESTORE_DTBO_IMAGE:-none}"
  log "After restore: $AFTER_RESTORE"
  log "Timeout: ${TIMEOUT_SEC}s"

  local deadline=$((SECONDS + TIMEOUT_SEC))
  local last_status=0
  local state=""
  while [ "$SECONDS" -lt "$deadline" ]; do
    if fastboot_present; then
      log "Target visible in fastboot"
      if ! phone_lock_acquire "rescue restore boot_b" 0; then
        log "Phone operation lock is busy; leaving target untouched and retrying"
        sleep "$POLL_SEC"
        continue
      fi
      restore_from_fastboot
      exit 0
    fi

    state="$(adb_state)"
    if [ "$state" = "recovery" ]; then
      log "Target visible in recovery ADB; rebooting to bootloader for boot_b restore"
      if ! phone_lock_acquire "rescue recovery-to-fastboot boot_b restore" 0; then
        log "Phone operation lock is busy; leaving recovery untouched and retrying"
        sleep "$POLL_SEC"
        continue
      fi
      collect_recovery_crash_artifacts "direct-recovery-before-restore"
      adb_do reboot bootloader
      phone_lock_release
      local fastboot_deadline=$((SECONDS + 90))
      local fastboot_seen_but_lock_busy=0
      while [ "$SECONDS" -lt "$fastboot_deadline" ]; do
        if fastboot_present; then
          if ! phone_lock_acquire "rescue restore boot_b" 0; then
            log "Phone operation lock is busy after recovery handoff; retrying outer wait loop"
            fastboot_seen_but_lock_busy=1
            break
          fi
          restore_from_fastboot
          exit 0
        fi
        sleep 2
      done
      if [ "$fastboot_seen_but_lock_busy" -eq 1 ]; then
        sleep "$POLL_SEC"
        continue
      fi
      die "Recovery rebooted but fastboot did not appear" 3
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
