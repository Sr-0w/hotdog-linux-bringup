#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
export PYTHONDONTWRITEBYTECODE=1

source "$(dirname "$0")/env.sh"
source "$(dirname "$0")/phone-lock.sh"

EDL_BIN="${EDL_BIN:-$HOTDOG_BIN_ROOT/edl}"
EDL_LOADER="${EDL_LOADER:-$HOTDOG_ROOT/src/qualcomm/edl/Loaders/oneplus/000a50e100514985_2acf3a85fde334e2_fhprg_op7t.bin}"
TIMEOUT_SEC="${TIMEOUT_SEC:-28800}"
POLL_SEC="${POLL_SEC:-2}"
LOCK_DIR="$HOTDOG_LOG_ROOT/watch-edl-dump-critical.lock"

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

LUNS=(0 1 2 3 4 5 6 7)

usage() {
  cat <<'USAGE'
Usage: watch-edl-dump-critical.sh [options]

Wait for Qualcomm EDL 05c6:9008, then run read-only bkerler/edl commands to
collect GPT information and critical boot/recovery partition images.

Options:
  --loader PATH   Firehose loader. Default: local OnePlus OP7T loader.
  --timeout SEC   Seconds to wait. Default: 28800.
  --poll SEC      Poll interval. Default: 2.
  -h, --help      Show this help.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --loader)
      [ "$#" -ge 2 ] || { echo "Missing value for --loader" >&2; exit 2; }
      EDL_LOADER="$2"
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

validate_seconds() {
  local name="$1"
  local value="$2"
  if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -lt 1 ]; then
    echo "$name must be a positive integer, got: $value" >&2
    exit 2
  fi
}

stamp="$(date +%F-%H%M%S)"
out="$HOTDOG_DUMP_ROOT/stock-before-flash/${stamp}-edl-critical-blocks"

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

cleanup() {
  phone_lock_release
  rm -rf "$LOCK_DIR"
}

on_err() {
  local rc=$?
  log "ERROR: command failed near line $1: $2 (exit $rc)"
  exit "$rc"
}

validate_seconds TIMEOUT_SEC "$TIMEOUT_SEC"
validate_seconds POLL_SEC "$POLL_SEC"

mkdir -p "$HOTDOG_LOG_ROOT"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  if [ -f "$LOCK_DIR/pid" ] && ! kill -0 "$(cat "$LOCK_DIR/pid")" 2>/dev/null; then
    rm -rf "$LOCK_DIR"
    mkdir "$LOCK_DIR"
  else
    echo "Another watch-edl-dump-critical instance appears to be running: $LOCK_DIR" >&2
    exit 2
  fi
fi
trap cleanup EXIT
trap 'on_err "$LINENO" "$BASH_COMMAND"' ERR
printf '%s\n' "$$" > "$LOCK_DIR/pid"

mkdir -p "$out/gpt" "$out/block-images"
exec > >(tee "$out/run.log") 2>&1

run_edl() {
  local logfile="$1"
  shift
  log "Running: $EDL_BIN --vid=0x05c6 --pid=0x9008 --loader=$EDL_LOADER --memory=ufs $*"
  printf '$' > "$logfile.cmd"
  printf ' %q' "$EDL_BIN" --vid=0x05c6 --pid=0x9008 --loader="$EDL_LOADER" --memory=ufs "$@" >> "$logfile.cmd"
  printf '\n' >> "$logfile.cmd"
  set +e
  "$EDL_BIN" --vid=0x05c6 --pid=0x9008 --loader="$EDL_LOADER" --memory=ufs "$@" 2>&1 | tee "$logfile"
  local rc=${PIPESTATUS[0]}
  set -e
  return "$rc"
}

wait_for_edl() {
  local deadline=$((SECONDS + TIMEOUT_SEC))
  local last_status=0

  log "Waiting for Qualcomm EDL 05c6:9008, timeout ${TIMEOUT_SEC}s"
  while [ "$SECONDS" -lt "$deadline" ]; do
    lsusb > "$out/lsusb-last.txt" 2>&1 || true
    local count
    count="$(grep -ci '05c6:9008' "$out/lsusb-last.txt" || true)"
    if [ "$count" -eq 1 ]; then
      log "Qualcomm EDL detected"
      grep -i '05c6:9008' "$out/lsusb-last.txt" | sed 's/^/[usb] /'
      return 0
    fi
    if [ "$count" -gt 1 ]; then
      log "ERROR: more than one 05c6:9008 device detected; refusing to auto-run"
      grep -i '05c6:9008' "$out/lsusb-last.txt" | sed 's/^/[usb] /'
      exit 2
    fi

    if [ $((SECONDS - last_status)) -ge 30 ]; then
      log "Still waiting for EDL; current Qualcomm/ADB/Fastboot-ish USB devices:"
      grep -Ei '05c6|18d1|2a70' "$out/lsusb-last.txt" | sed 's/^/[usb] /' || true
      last_status=$SECONDS
    fi
    sleep "$POLL_SEC"
  done

  log "Timed out waiting for EDL"
  exit 2
}

write_manifest() {
  {
    printf 'timestamp=%s\n' "$stamp"
    printf 'dump_dir=%s\n' "$out"
    printf 'edl_bin=%s\n' "$EDL_BIN"
    printf 'edl_loader=%s\n' "$EDL_LOADER"
    printf 'mode=read-only\n'
    printf 'partitions=%s\n' "${PARTITIONS[*]}"
  } > "$out/MANIFEST.txt"
}

dump_partition() {
  local part="$1"
  local image="$out/block-images/$part.img"
  local log_file="$out/edl-read-$part.txt"
  local lun=""

  if run_edl "$log_file" r "$part" "$image"; then
    if [ -s "$image" ]; then
      sha256sum "$image" | tee -a "$out/SHA256SUMS"
      log "Dumped $part"
      return 0
    fi
    log "EDL command for $part returned success but image is empty"
  else
    log "Could not dump $part; see $log_file"
  fi

  rm -f "$image"
  for lun in "${LUNS[@]}"; do
    image="$out/block-images/$part.lun$lun.img"
    log_file="$out/edl-read-$part-lun$lun.txt"
    if run_edl "$log_file" --lun="$lun" r "$part" "$image"; then
      if [ -s "$image" ]; then
        sha256sum "$image" | tee -a "$out/SHA256SUMS"
        log "Dumped $part from explicit LUN $lun"
        return 0
      fi
      log "EDL LUN $lun command for $part returned success but image is empty"
    else
      log "Could not dump $part from explicit LUN $lun; see $log_file"
    fi
    rm -f "$image"
  done

  : > "$out/block-images/$part.failed"
  return 1
}

main() {
  command -v lsusb >/dev/null 2>&1 || { echo "Missing lsusb" >&2; exit 127; }
  [ -x "$EDL_BIN" ] || { echo "Missing executable EDL_BIN: $EDL_BIN" >&2; exit 127; }
  [ -r "$EDL_LOADER" ] || { echo "Missing readable EDL_LOADER: $EDL_LOADER" >&2; exit 2; }

  log "Dump directory: $out"
  log "EDL binary: $EDL_BIN"
  log "EDL loader: $EDL_LOADER"
  log "Mode: read-only"
  write_manifest
  sha256sum "$EDL_LOADER" | tee "$out/loader.sha256"

  wait_for_edl
  phone_lock_acquire "watch-edl-dump-critical read-only dump" "$TIMEOUT_SEC" || exit 2

  run_edl "$out/edl-getstorageinfo.txt" getstorageinfo || true
  run_edl "$out/edl-printgpt.txt" printgpt || true
  for lun in "${LUNS[@]}"; do
    run_edl "$out/edl-printgpt-lun$lun.txt" --lun="$lun" printgpt || true
  done
  run_edl "$out/edl-read-gpt.txt" r gpt "$out/gpt/gpt.bin" || true

  : > "$out/SHA256SUMS"
  : > "$out/failed-partitions.txt"
  for part in "${PARTITIONS[@]}"; do
    dump_partition "$part" || printf '%s\n' "$part" >> "$out/failed-partitions.txt"
  done

  write_manifest
  log "Done: $out"
  phone_lock_release
}

main "$@"
