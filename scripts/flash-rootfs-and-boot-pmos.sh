#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/env.sh"
source "$(dirname "$0")/stock-dump-lib.sh"

REQUIRE_DUMP=1
FLASH_KERNEL=0
BOOT_TEMPORARY=1
PMOS_IMAGE_DIR="${PMOS_IMAGE_DIR:-$HOTDOG_ROOT/images/pmos/2026-07-08-070531-console-uncompressed-ramoops}"
FASTBOOT_TIMEOUT_SEC="${FASTBOOT_TIMEOUT_SEC:-900}"
POLL_SEC="${POLL_SEC:-2}"
EXPECTED_FASTBOOT_PRODUCTS="${EXPECTED_FASTBOOT_PRODUCTS:-msmnile hotdog}"
REQUIRE_FASTBOOT_UNLOCKED="${REQUIRE_FASTBOOT_UNLOCKED:-1}"
device_serial="${ANDROID_SERIAL:-}"

usage() {
  cat <<'USAGE'
Usage: flash-rootfs-and-boot-pmos.sh [options]

Flash the generated postmarketOS rootfs, then fastboot boot the generated
boot.img by default. Refuses to run until a complete stock block dump exists.

Options:
  --serial SERIAL        Restrict fastboot/ADB commands to SERIAL.
  --allow-without-dump   Do not require a previous recovery-root dump.
  --pmos-image-dir DIR   Exported pmOS image directory to verify before flash.
  --expected-product NAME Required fastboot product list. Default: "msmnile hotdog".
  --allow-locked         Do not fail early if fastboot reports locked.
  --flash-kernel         Flash kernel persistently instead of temporary boot.
  --no-boot              Flash rootfs only.
  --timeout SEC          Seconds to wait for fastboot. Default: 900.
  -h, --help             Show this help.
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
    --allow-without-dump)
      REQUIRE_DUMP=0
      ;;
    --pmos-image-dir)
      [ "$#" -ge 2 ] || { echo "Missing value for --pmos-image-dir" >&2; exit 2; }
      PMOS_IMAGE_DIR="$2"
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
    --flash-kernel)
      FLASH_KERNEL=1
      BOOT_TEMPORARY=0
      ;;
    --no-boot)
      BOOT_TEMPORARY=0
      FLASH_KERNEL=0
      ;;
    --timeout)
      [ "$#" -ge 2 ] || { echo "Missing value for --timeout" >&2; exit 2; }
      FASTBOOT_TIMEOUT_SEC="$2"
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
run_dir="$HOTDOG_LOG_ROOT/flash-rootfs-and-boot-pmos-$stamp"
mkdir -p "$run_dir"
exec > >(tee "$run_dir/run.log") 2>&1

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

wait_for_fastboot() {
  local deadline=$((SECONDS + FASTBOOT_TIMEOUT_SEC))
  local last_status=0
  local count=0

  log "Waiting for fastboot, timeout ${FASTBOOT_TIMEOUT_SEC}s"
  while [ "$SECONDS" -lt "$deadline" ]; do
    fastboot devices -l > "$run_dir/fastboot-devices-last.txt" 2>&1 || true
    if [ -n "$device_serial" ]; then
      if awk -v serial="$device_serial" 'NF >= 2 && $1 == serial { found=1 } END { exit found ? 0 : 1 }' "$run_dir/fastboot-devices-last.txt"; then
        log "Fastboot target detected: $device_serial"
        return 0
      fi
    else
      count="$(awk 'NF >= 2 { count++ } END { print count + 0 }' "$run_dir/fastboot-devices-last.txt")"
      case "$count" in
        0)
          ;;
        1)
          device_serial="$(awk 'NF >= 2 { print $1; exit }' "$run_dir/fastboot-devices-last.txt")"
          export ANDROID_SERIAL="$device_serial"
          log "Fastboot device detected: $device_serial"
          return 0
          ;;
        *)
          sed 's/^/[fastboot] /' "$run_dir/fastboot-devices-last.txt"
          die "Multiple fastboot devices found; rerun with --serial SERIAL" 2
          ;;
      esac
    fi

    if [ $((SECONDS - last_status)) -ge 30 ]; then
      log "Still waiting for fastboot"
      last_status=$SECONDS
    fi
    sleep "$POLL_SEC"
  done

  die "Timed out waiting for fastboot. See $run_dir/fastboot-devices-last.txt" 2
}

fastboot_do() {
  if [ -n "$device_serial" ]; then
    fastboot -s "$device_serial" "$@"
  else
    fastboot "$@"
  fi
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

normalize_fastboot_value() {
  local value="$1"
  value="${value,,}"
  value="${value//[[:space:]]/}"
  value="${value#_}"
  printf '%s\n' "$value"
}

validate_fastboot_identity() {
  local product=""
  local serialno=""
  local unlocked=""
  local expected_product
  local product_ok=1

  serialno="$(normalize_fastboot_value "$(get_fastboot_var serialno)")"
  product="$(normalize_fastboot_value "$(get_fastboot_var product)")"
  unlocked="$(normalize_fastboot_value "$(get_fastboot_var unlocked)")"

  [ -n "$device_serial" ] || die "Internal error: device_serial is empty after wait_for_fastboot" 2

  case "$serialno" in
    "$device_serial"|"")
      ;;
    *)
      die "Fastboot serial mismatch: selected $device_serial but getvar serialno reports $serialno" 2
      ;;
  esac

  if [ -n "$EXPECTED_FASTBOOT_PRODUCTS" ]; then
    for expected_product in $EXPECTED_FASTBOOT_PRODUCTS; do
      expected_product="$(normalize_fastboot_value "$expected_product")"
      [ -n "$expected_product" ] || continue
      if [ "$product" = "$expected_product" ]; then
        product_ok=0
        break
      fi
    done
    if [ "$product_ok" -ne 0 ]; then
      die "Fastboot product mismatch: expected one of [$EXPECTED_FASTBOOT_PRODUCTS], got ${product:-missing}. See $run_dir/getvar-product.txt" 2
    fi
  fi

  case "$unlocked" in
    yes|true|1|unlocked)
      log "Fastboot identity OK: serial=$device_serial product=$product unlocked=$unlocked"
      ;;
    *)
      if [ "$REQUIRE_FASTBOOT_UNLOCKED" -eq 1 ]; then
        die "Fastboot unlocked state is not explicitly yes/true/1 (got ${unlocked:-missing}). Refusing pmOS flash/boot. See $run_dir/getvar-unlocked.txt" 2
      fi
      log "Fastboot identity OK: serial=$device_serial product=$product; continuing despite unlocked state '${unlocked:-missing}' because --allow-locked was requested"
      ;;
  esac
}

ensure_fastboot_mode() {
  local requirement="$1"
  local is_userspace=""

  is_userspace="$(get_fastboot_var is-userspace)"
  is_userspace="${is_userspace,,}"
  is_userspace="${is_userspace//[[:space:]]/}"

  case "$is_userspace" in
    yes|true|1)
      if [ "$requirement" = "allow-userspace" ]; then
        log "Userspace fastboot/fastbootd detected; allowing it for this pmbootstrap flasher action"
        return 0
      fi
      log "Userspace fastboot/fastbootd detected; rebooting to bootloader before boot/kernel action"
      fastboot_do reboot bootloader > "$run_dir/fastboot-reboot-bootloader-from-fastbootd.txt" 2>&1 || die "Failed to reboot from fastbootd to bootloader. See $run_dir/fastboot-reboot-bootloader-from-fastbootd.txt" 2
      sleep 5
      wait_for_fastboot
      is_userspace="$(get_fastboot_var is-userspace)"
      is_userspace="${is_userspace,,}"
      is_userspace="${is_userspace//[[:space:]]/}"
      case "$is_userspace" in
        yes|true|1)
          die "Device is still in userspace fastboot after reboot bootloader. Refusing boot/kernel action from fastbootd. See $run_dir/getvar-is-userspace.txt" 2
          ;;
      esac
      log "Bootloader fastboot confirmed after fastbootd handoff"
      ;;
    no|false|0)
      log "Bootloader fastboot confirmed"
      ;;
    *)
      log "Fastboot getvar is-userspace did not report yes/no; continuing cautiously. See $run_dir/getvar-is-userspace.txt"
      ;;
  esac
}

run_pmbootstrap_flasher() {
  local action="$1"
  shift || true
  log "Running pmbootstrap flasher $action $*"
  "$HOTDOG_ROOT/scripts/pmbootstrap-hotdog.sh" flasher "$action" "$@"
}

validate_pmos_artifacts() {
  local file=""

  [ -d "$PMOS_IMAGE_DIR" ] || die "Missing pmOS image directory: $PMOS_IMAGE_DIR" 4
  for file in boot.img oneplus-hotdog.img dtbs/sm8150-oneplus-hotdog.dtb SHA256SUMS; do
    [ -s "$PMOS_IMAGE_DIR/$file" ] || die "Missing pmOS artifact: $PMOS_IMAGE_DIR/$file" 4
  done

  log "Verifying exported pmOS artifacts: $PMOS_IMAGE_DIR"
  ( cd "$PMOS_IMAGE_DIR" && sha256sum -c SHA256SUMS ) | tee "$run_dir/pmos-image-sha256-check.txt"
  cp -f "$PMOS_IMAGE_DIR/SHA256SUMS" "$run_dir/pmos-image-SHA256SUMS"
  [ ! -s "$PMOS_IMAGE_DIR/MANIFEST.md" ] || cp -f "$PMOS_IMAGE_DIR/MANIFEST.md" "$run_dir/pmos-image-MANIFEST.md"
}

main() {
  validate_seconds FASTBOOT_TIMEOUT_SEC "$FASTBOOT_TIMEOUT_SEC"
  validate_seconds POLL_SEC "$POLL_SEC"

  command -v fastboot >/dev/null 2>&1 || die "Missing fastboot" 127
  command -v adb >/dev/null 2>&1 || die "Missing adb" 127
  command -v sha256sum >/dev/null 2>&1 || die "Missing sha256sum" 127

  log "Run directory: $run_dir"
  log "Target serial: ${device_serial:-auto-detect}"
  log "Require complete stock dump: $REQUIRE_DUMP"
  log "Boot temporary: $BOOT_TEMPORARY"
  log "Flash kernel persistently: $FLASH_KERNEL"
  log "pmOS image dir: $PMOS_IMAGE_DIR"
  log "Expected fastboot products: ${EXPECTED_FASTBOOT_PRODUCTS:-any}"

  local dump_dir=""
  dump_dir="$(stock_dump_latest_complete || true)"
  if [ "$REQUIRE_DUMP" -eq 1 ]; then
    [ -n "$dump_dir" ] || die "No complete stock block dump found under $HOTDOG_DUMP_ROOT/stock-before-flash" 3
    log "Using previous stock dump proof: $dump_dir"
  else
    log "Proceeding without dump proof by request"
  fi

  validate_pmos_artifacts
  "$HOTDOG_ROOT/scripts/check-dtb-status.sh"

  wait_for_fastboot
  validate_fastboot_identity
  ensure_fastboot_mode allow-userspace
  validate_fastboot_identity
  run_pmbootstrap_flasher flash_rootfs

  if [ "$FLASH_KERNEL" -eq 1 ]; then
    wait_for_fastboot
    ensure_fastboot_mode require-bootloader
    validate_fastboot_identity
    run_pmbootstrap_flasher flash_kernel
  elif [ "$BOOT_TEMPORARY" -eq 1 ]; then
    wait_for_fastboot
    ensure_fastboot_mode require-bootloader
    validate_fastboot_identity
    run_pmbootstrap_flasher boot
  else
    log "Rootfs flashed; not booting by request"
  fi

  log "Done"
}

main "$@"
