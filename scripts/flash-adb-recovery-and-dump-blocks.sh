#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/env.sh"

RECOVERY_IMAGE="${RECOVERY_IMAGE:-$HOTDOG_ROOT/images/lineage/hotdog-20260703/recovery-adb-unsecure.img}"
ADB_HOST_PUBLIC_KEY="${ADB_HOST_PUBLIC_KEY:-$HOME/.android/adbkey.pub}"
RECOVERY_HOST_PUBLIC_KEY="${RECOVERY_HOST_PUBLIC_KEY:-$HOTDOG_ROOT/images/lineage/hotdog-20260703/patch-magiskboot-strong/host-adbkey.pub}"
FASTBOOT_TIMEOUT_SEC="${FASTBOOT_TIMEOUT_SEC:-900}"
ADB_TIMEOUT_SEC="${ADB_TIMEOUT_SEC:-420}"
ADB_ROOT_TIMEOUT_SEC="${ADB_ROOT_TIMEOUT_SEC:-120}"
POLL_SEC="${POLL_SEC:-2}"
EXPECTED_FASTBOOT_PRODUCTS="${EXPECTED_FASTBOOT_PRODUCTS:-msmnile hotdog}"
REQUIRE_FASTBOOT_UNLOCKED="${REQUIRE_FASTBOOT_UNLOCKED:-1}"
device_serial="${ANDROID_SERIAL:-}"

PARTITIONS=(
  boot_a
  boot_b
  dtbo_a
  dtbo_b
  vbmeta_a
  vbmeta_b
  recovery_a
  recovery_b
)

usage() {
  cat <<'USAGE'
Usage: flash-adb-recovery-and-dump-blocks.sh [options]

Flash the patched Lineage recovery to the current fastboot slot, reboot to
recovery, require an authorized root adb shell, and dump stock block images.

Options:
  --image PATH              Recovery image to flash.
  --serial SERIAL           Fastboot/ADB serial to use. Same as ANDROID_SERIAL.
  --fastboot-timeout SEC    Seconds to wait for fastboot. Default: 900.
  --adb-timeout SEC         Seconds to wait for adb recovery/device. Default: 420.
  --root-timeout SEC        Seconds to wait for root adb shell. Default: 120.
  --expected-product NAME   Add/replace required fastboot product list.
                            Default: "msmnile hotdog".
  --allow-locked            Do not fail early if fastboot reports locked.
  -h, --help                Show this help.

Environment overrides use the same names:
  RECOVERY_IMAGE, ANDROID_SERIAL, FASTBOOT_TIMEOUT_SEC, ADB_TIMEOUT_SEC,
  ADB_ROOT_TIMEOUT_SEC, POLL_SEC, EXPECTED_FASTBOOT_PRODUCTS,
  REQUIRE_FASTBOOT_UNLOCKED.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --image)
      [ "$#" -ge 2 ] || { echo "Missing value for --image" >&2; exit 2; }
      RECOVERY_IMAGE="$2"
      shift
      ;;
    --serial)
      [ "$#" -ge 2 ] || { echo "Missing value for --serial" >&2; exit 2; }
      device_serial="$2"
      export ANDROID_SERIAL="$device_serial"
      shift
      ;;
    --fastboot-timeout)
      [ "$#" -ge 2 ] || { echo "Missing value for --fastboot-timeout" >&2; exit 2; }
      FASTBOOT_TIMEOUT_SEC="$2"
      shift
      ;;
    --adb-timeout)
      [ "$#" -ge 2 ] || { echo "Missing value for --adb-timeout" >&2; exit 2; }
      ADB_TIMEOUT_SEC="$2"
      shift
      ;;
    --root-timeout)
      [ "$#" -ge 2 ] || { echo "Missing value for --root-timeout" >&2; exit 2; }
      ADB_ROOT_TIMEOUT_SEC="$2"
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
out="$HOTDOG_DUMP_ROOT/stock-before-flash/${stamp}-recovery-root-blocks"
mkdir -p "$out/block-images"
exec > >(tee "$out/run.log") 2>&1

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

die() {
  local message="$1"
  local rc="${2:-1}"
  log "ERROR: $message"
  exit "$rc"
}

on_err() {
  local rc=$?
  local line="$1"
  local command="$2"
  log "ERROR: command failed near line $line: $command (exit $rc)"
  exit "$rc"
}
trap 'on_err "$LINENO" "$BASH_COMMAND"' ERR

validate_seconds() {
  local name="$1"
  local value="$2"
  if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -lt 1 ]; then
    die "$name must be a positive integer, got: $value" 2
  fi
}

require_command() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "Missing required command: $cmd" 127
}

file_sha256_or_missing() {
  local path="$1"

  if [ -s "$path" ]; then
    sha256sum "$path" | awk '{ print $1 }'
  else
    printf 'missing\n'
  fi
}

validate_recovery_adb_key() {
  local host_sha=""
  local recovery_sha=""

  [ -s "$ADB_HOST_PUBLIC_KEY" ] || die "ADB host public key is missing or empty: $ADB_HOST_PUBLIC_KEY" 2
  [ -s "$RECOVERY_HOST_PUBLIC_KEY" ] || die "Recovery-injected ADB public key is missing or empty: $RECOVERY_HOST_PUBLIC_KEY" 2

  host_sha="$(file_sha256_or_missing "$ADB_HOST_PUBLIC_KEY")"
  recovery_sha="$(file_sha256_or_missing "$RECOVERY_HOST_PUBLIC_KEY")"
  if ! cmp -s "$ADB_HOST_PUBLIC_KEY" "$RECOVERY_HOST_PUBLIC_KEY"; then
    die "Host ADB public key does not match the key injected into patched recovery (host=$host_sha recovery=$recovery_sha). Refusing to flash a recovery that would likely stay unauthorized." 2
  fi

  log "ADB host public key matches recovery-injected key: $host_sha"
}

fastboot_do() {
  if [ -n "$device_serial" ]; then
    fastboot -s "$device_serial" "$@"
  else
    fastboot "$@"
  fi
}

adb_do() {
  if [ -n "$device_serial" ]; then
    adb -s "$device_serial" "$@"
  else
    adb "$@"
  fi
}

run_logged() {
  local logfile="$1"
  shift
  log "Running: $*"
  set +e
  "$@" 2>&1 | tee "$logfile"
  local rc=${PIPESTATUS[0]}
  set -e
  [ "$rc" -eq 0 ] || die "Command failed ($rc): $*" "$rc"
}

write_manifest() {
  {
    printf 'timestamp=%s\n' "$stamp"
    printf 'dump_dir=%s\n' "$out"
    printf 'recovery_image=%s\n' "$RECOVERY_IMAGE"
    printf 'recovery_image_sha256=%s\n' "$(file_sha256_or_missing "$RECOVERY_IMAGE")"
    printf 'adb_host_public_key=%s\n' "$ADB_HOST_PUBLIC_KEY"
    printf 'adb_host_public_key_sha256=%s\n' "$(file_sha256_or_missing "$ADB_HOST_PUBLIC_KEY")"
    printf 'recovery_host_public_key=%s\n' "$RECOVERY_HOST_PUBLIC_KEY"
    printf 'recovery_host_public_key_sha256=%s\n' "$(file_sha256_or_missing "$RECOVERY_HOST_PUBLIC_KEY")"
    printf 'device_serial=%s\n' "${device_serial:-}"
    printf 'fastboot_serialno=%s\n' "${fastboot_serialno:-}"
    printf 'fastboot_product=%s\n' "${fastboot_product:-}"
    printf 'fastboot_unlocked=%s\n' "${fastboot_unlocked:-}"
    printf 'expected_fastboot_products=%s\n' "$EXPECTED_FASTBOOT_PRODUCTS"
    printf 'current_slot=%s\n' "${current_slot:-}"
    printf 'flashed_partition=%s\n' "${flashed_partition:-}"
    printf 'partitions=%s\n' "${PARTITIONS[*]}"
  } > "$out/MANIFEST.txt"
}

fastboot_serial_present() {
  local want="$1"
  local serial
  shift
  for serial in "$@"; do
    [ "$serial" = "$want" ] && return 0
  done
  return 1
}

wait_for_fastboot() {
  local deadline=$((SECONDS + FASTBOOT_TIMEOUT_SEC))
  local last_log=0
  local serials=()

  log "Waiting for fastboot device, timeout ${FASTBOOT_TIMEOUT_SEC}s"
  while [ "$SECONDS" -lt "$deadline" ]; do
    fastboot devices > "$out/fastboot-devices-last.txt" 2>&1 || true
    mapfile -t serials < <(awk 'NF >= 2 && $2 == "fastboot" { print $1 }' "$out/fastboot-devices-last.txt")

    if [ -n "$device_serial" ]; then
      if fastboot_serial_present "$device_serial" "${serials[@]}"; then
        log "Fastboot device found: $device_serial"
        return 0
      fi
    else
      case "${#serials[@]}" in
        0)
          ;;
        1)
          device_serial="${serials[0]}"
          export ANDROID_SERIAL="$device_serial"
          log "Fastboot device found: $device_serial"
          return 0
          ;;
        *)
          printf '%s\n' "${serials[@]}" > "$out/fastboot-multiple-devices.txt"
          die "Multiple fastboot devices found. Rerun with --serial SERIAL or ANDROID_SERIAL. See $out/fastboot-multiple-devices.txt" 2
          ;;
      esac
    fi

    if [ $((SECONDS - last_log)) -ge 15 ]; then
      log "Still waiting for fastboot..."
      last_log=$SECONDS
    fi
    sleep "$POLL_SEC"
  done

  die "Timed out waiting for fastboot. Last device list: $out/fastboot-devices-last.txt" 2
}

get_fastboot_var() {
  local var="$1"
  local safe_name="${var//[:\/]/_}"
  local file="$out/getvar-${safe_name}.txt"

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

normalize_fastboot_value() {
  local value="$1"
  value="${value,,}"
  value="${value//[[:space:]]/}"
  value="${value#_}"
  printf '%s\n' "$value"
}

validate_fastboot_identity() {
  local product_raw=""
  local serialno_raw=""
  local unlocked_raw=""
  local expected_product
  local product_ok=1

  serialno_raw="$(get_fastboot_var serialno)"
  product_raw="$(get_fastboot_var product)"
  unlocked_raw="$(get_fastboot_var unlocked)"

  fastboot_serialno="$(normalize_fastboot_value "$serialno_raw")"
  fastboot_product="$(normalize_fastboot_value "$product_raw")"
  fastboot_unlocked="$(normalize_fastboot_value "$unlocked_raw")"

  [ -n "$device_serial" ] || die "Internal error: device_serial is empty after wait_for_fastboot" 2
  case "$fastboot_serialno" in
    "$device_serial"|"")
      ;;
    *)
      die "Fastboot serial mismatch: selected $device_serial but getvar serialno reports $fastboot_serialno" 2
      ;;
  esac

  if [ -n "$EXPECTED_FASTBOOT_PRODUCTS" ]; then
    for expected_product in $EXPECTED_FASTBOOT_PRODUCTS; do
      expected_product="$(normalize_fastboot_value "$expected_product")"
      [ -n "$expected_product" ] || continue
      if [ "$fastboot_product" = "$expected_product" ]; then
        product_ok=0
        break
      fi
    done
    if [ "$product_ok" -ne 0 ]; then
      die "Fastboot product mismatch: expected one of [$EXPECTED_FASTBOOT_PRODUCTS], got ${fastboot_product:-missing}. See $out/getvar-product.txt" 2
    fi
  fi

  case "$fastboot_unlocked" in
    yes|true|1|unlocked)
      log "Fastboot identity OK: serial=$device_serial product=$fastboot_product unlocked=$fastboot_unlocked"
      ;;
    *)
      if [ "$REQUIRE_FASTBOOT_UNLOCKED" -eq 1 ]; then
        die "Fastboot unlocked state is not explicitly yes/true/1 (got ${fastboot_unlocked:-missing}). Refusing recovery flash. See $out/getvar-unlocked.txt" 2
      fi
      log "Fastboot identity OK: serial=$device_serial product=$fastboot_product; continuing despite unlocked state '${fastboot_unlocked:-missing}' because --allow-locked was requested"
      ;;
  esac
}

ensure_bootloader_fastboot() {
  local is_userspace=""

  is_userspace="$(get_fastboot_var is-userspace)"
  is_userspace="${is_userspace,,}"
  is_userspace="${is_userspace//[[:space:]]/}"

  case "$is_userspace" in
    yes|true|1)
      log "Userspace fastboot/fastbootd detected; rebooting to bootloader before flashing recovery"
      run_logged "$out/fastboot-reboot-bootloader-from-fastbootd.txt" fastboot_do reboot bootloader
      sleep 5
      wait_for_fastboot
      is_userspace="$(get_fastboot_var is-userspace)"
      is_userspace="${is_userspace,,}"
      is_userspace="${is_userspace//[[:space:]]/}"
      case "$is_userspace" in
        yes|true|1)
          die "Device is still in userspace fastboot after reboot bootloader. Refusing to flash recovery from fastbootd. See $out/getvar-is-userspace.txt" 2
          ;;
      esac
      log "Bootloader fastboot confirmed after fastbootd handoff"
      ;;
    no|false|0)
      log "Bootloader fastboot confirmed"
      ;;
    *)
      log "Fastboot getvar is-userspace did not report yes/no; continuing cautiously. See $out/getvar-is-userspace.txt"
      ;;
  esac
}

detect_current_slot() {
  local slot
  slot="$(get_fastboot_var current-slot)"
  slot="${slot,,}"
  slot="${slot//[[:space:]]/}"
  slot="${slot#_}"

  case "$slot" in
    a|b)
      current_slot="$slot"
      flashed_partition="recovery_$current_slot"
      log "Current fastboot slot: $current_slot"
      ;;
    *)
      die "Could not detect current slot from fastboot getvar current-slot. See $out/getvar-current-slot.txt" 2
      ;;
  esac
}

adb_state() {
  adb devices > "$out/adb-devices-last.txt" 2>&1 || true
  awk -v serial="$device_serial" '
    NF >= 2 && $1 !~ /^\*/ && $1 != "List" {
      if (serial == "" || $1 == serial) {
        print $2
        exit
      }
    }
  ' "$out/adb-devices-last.txt"
}

wait_for_adb_recovery_or_device() {
  local deadline=$((SECONDS + ADB_TIMEOUT_SEC))
  local last_log=0
  local state=""

  log "Waiting for adb recovery/device, timeout ${ADB_TIMEOUT_SEC}s"
  adb start-server > "$out/adb-start-server.txt" 2>&1 || true

  while [ "$SECONDS" -lt "$deadline" ]; do
    state="$(adb_state)"
    case "$state" in
      recovery|device)
        log "ADB state is $state for serial $device_serial"
        return 0
        ;;
      unauthorized)
        if [ $((SECONDS - last_log)) -ge 15 ]; then
          log "ADB state is unauthorized; continuing until timeout in case recovery restarts"
          last_log=$SECONDS
        fi
        ;;
      "")
        if [ $((SECONDS - last_log)) -ge 15 ]; then
          log "No matching adb device yet"
          last_log=$SECONDS
        fi
        ;;
      *)
        if [ $((SECONDS - last_log)) -ge 15 ]; then
          log "ADB state is $state; waiting for recovery/device"
          last_log=$SECONDS
        fi
        ;;
    esac
    sleep "$POLL_SEC"
  done

  state="$(adb_state)"
  if [ "$state" = "unauthorized" ]; then
    die "ADB stayed unauthorized. The patched recovery did not authorize this host key, or the phone did not boot that recovery. See $out/adb-devices-last.txt" 3
  fi

  die "Timed out waiting for adb recovery/device. Last adb list: $out/adb-devices-last.txt" 3
}

probe_adb_root() {
  local output

  if output="$(adb_do shell 'id -u 2>/dev/null || id' 2>&1 | tr -d '\r')"; then
    printf '%s\n' "$output" > "$out/adb-id-last.txt"
    if printf '%s\n' "$output" | awk '$0 == "0" || index($0, "uid=0") { found=1 } END { exit found ? 0 : 1 }'; then
      return 0
    fi
  else
    printf '%s\n' "$output" > "$out/adb-id-last.txt"
  fi

  return 1
}

wait_for_adb_root() {
  local deadline=$((SECONDS + ADB_ROOT_TIMEOUT_SEC))
  local last_log=0
  local root_requested=0
  local state=""

  log "Waiting for root adb shell, timeout ${ADB_ROOT_TIMEOUT_SEC}s"
  while [ "$SECONDS" -lt "$deadline" ]; do
    if probe_adb_root; then
      log "ADB shell is root"
      return 0
    fi

    state="$(adb_state)"
    if [ "$state" = "unauthorized" ]; then
      die "ADB became unauthorized while checking root. See $out/adb-devices-last.txt and $out/adb-id-last.txt" 3
    fi

    if [ "$root_requested" -eq 0 ]; then
      log "Requesting adb root if adbd supports it"
      adb_do root > "$out/adb-root.txt" 2>&1 || true
      root_requested=1
      sleep 3
      continue
    fi

    if [ $((SECONDS - last_log)) -ge 15 ]; then
      log "Still waiting for root adb shell; current adb state: ${state:-none}"
      last_log=$SECONDS
    fi
    sleep "$POLL_SEC"
  done

  die "ADB shell is available but not root. Last id output: $out/adb-id-last.txt" 4
}

collect_recovery_context() {
  log "Collecting recovery context"
  adb_do shell getprop > "$out/recovery-getprop.txt" 2>&1 || true
  adb_do shell uname -a > "$out/recovery-uname.txt" 2>&1 || true
  adb_do shell mount > "$out/recovery-mounts.txt" 2>&1 || true
  adb_do shell ls -l /dev/block/by-name > "$out/recovery-by-name.txt" 2>&1 || true
  adb_do shell ls -l /dev/block/bootdevice/by-name > "$out/recovery-bootdevice-by-name.txt" 2>&1 || true
}

resolve_partition_path() {
  local part="$1"
  local path=""
  local remote_script

  remote_script="
part='$part'
for base in /dev/block/by-name /dev/block/bootdevice/by-name /dev/block/platform/*/by-name; do
  p=\"\$base/\$part\"
  if [ -e \"\$p\" ]; then
    readlink -f \"\$p\" 2>/dev/null || printf '%s\n' \"\$p\"
    exit 0
  fi
done
exit 1
"

  path="$(adb_do shell "$remote_script" 2>"$out/resolve-${part}.err" | tr -d '\r' | awk 'NF { print; exit }')" || return 1
  [ -n "$path" ] || return 1

  case "$path" in
    *[!A-Za-z0-9_./:-]*)
      die "Resolved unsafe path for $part: $path" 5
      ;;
  esac

  printf '%s\n' "$path"
}

dump_partition() {
  local part="$1"
  local remote_path=""
  local image="$out/block-images/$part.img"
  local tmp="$image.tmp"
  local bytes=""

  remote_path="$(resolve_partition_path "$part")" || die "Could not resolve block path for $part" 5
  log "Dumping $part from $remote_path"

  rm -f "$tmp"
  set +e
  adb_do exec-out sh -c "dd if=$remote_path bs=1048576 2>/dev/null" > "$tmp"
  local rc=$?
  set -e

  if [ "$rc" -ne 0 ]; then
    rm -f "$tmp"
    die "Failed to dump $part from $remote_path (adb exec-out dd exit $rc)" 5
  fi

  if [ ! -s "$tmp" ]; then
    rm -f "$tmp"
    die "Dump for $part is empty; refusing to keep it" 5
  fi

  mv -f "$tmp" "$image"
  bytes="$(wc -c < "$image")"
  bytes="${bytes//[[:space:]]/}"
  log "Dumped $part ($bytes bytes)"
  ( cd "$out" && sha256sum "block-images/$part.img" ) | tee -a "$out/SHA256SUMS"
}

main() {
  validate_seconds FASTBOOT_TIMEOUT_SEC "$FASTBOOT_TIMEOUT_SEC"
  validate_seconds ADB_TIMEOUT_SEC "$ADB_TIMEOUT_SEC"
  validate_seconds ADB_ROOT_TIMEOUT_SEC "$ADB_ROOT_TIMEOUT_SEC"
  validate_seconds POLL_SEC "$POLL_SEC"

  require_command adb
  require_command awk
  require_command fastboot
  require_command cmp
  require_command sha256sum
  require_command tee
  require_command wc

  [ -r "$RECOVERY_IMAGE" ] || die "Recovery image is not readable: $RECOVERY_IMAGE" 2
  validate_recovery_adb_key

  log "Dump directory: $out"
  log "Recovery image: $RECOVERY_IMAGE"
  log "Target serial: ${device_serial:-auto-detect}"
  log "Partitions to dump: ${PARTITIONS[*]}"
  sha256sum "$RECOVERY_IMAGE" | tee "$out/recovery-image.sha256"
  write_manifest

  wait_for_fastboot
  fastboot_do devices | tee "$out/fastboot-devices-selected.txt"
  ensure_bootloader_fastboot
  fastboot_do devices | tee "$out/fastboot-devices-selected-after-bootloader-check.txt"
  fastboot_do getvar all > "$out/fastboot-getvar-all.txt" 2>&1 || true
  validate_fastboot_identity

  detect_current_slot
  write_manifest

  run_logged "$out/fastboot-flash-${flashed_partition}.txt" fastboot_do flash "$flashed_partition" "$RECOVERY_IMAGE"
  run_logged "$out/fastboot-reboot-recovery.txt" fastboot_do reboot recovery

  wait_for_adb_recovery_or_device
  wait_for_adb_root
  collect_recovery_context

  : > "$out/SHA256SUMS"
  for part in "${PARTITIONS[@]}"; do
    dump_partition "$part"
  done

  write_manifest
  log "Done: $out"
}

main "$@"
