#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/env.sh"
source "$(dirname "$0")/phone-lock.sh"

PMOS_HOST="${PMOS_HOST:-$HOTDOG_PMOS_HOST}"
PMOS_USER="${PMOS_USER:-$HOTDOG_PMOS_USER}"
PMOS_PASSWORD="${PMOS_PASSWORD:-$HOTDOG_PMOS_PASSWORD}"
IMAGE=""
REMOTE_DIR=""
PARTITION_LABEL="boot_b"
PARTITION_PATH=""
REBOOT=0
KEEP_REMOTE=0
LOCK_WAIT_SEC="${LOCK_WAIT_SEC:-0}"

usage() {
  cat <<'USAGE'
Usage: flash-boot-b-from-pmos-ssh.sh --image boot.img [options]

Copy a boot image to the already-booted postmarketOS userland over SSH, write
it to boot_b from the phone itself, and verify the block prefix hash.

By default this script does not reboot. It writes only boot_b unless explicitly
given another partition path and the code is edited.

Options:
  --image FILE       Boot image to flash to boot_b.
  --host HOST        postmarketOS SSH host. Default: 172.16.42.1.
  --user USER        SSH user. Default: user.
  --password PASS    SSH password. Defaults to PMOS_PASSWORD.
  --remote-dir DIR   Remote temp directory. Default: /tmp/hotdog-flash-<stamp>.
  --partition-path P Explicit block node, normally auto-detected from boot_b.
  --reboot           Reboot the phone with "sudo -n reboot -f" after verify.
  --keep-remote      Do not remove the copied image/script on success.
  --lock-wait SEC    Seconds to wait for the local phone-operation lock.
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

remote_run() {
  ssh_base "$@"
}

remote_sudo_sh() {
  local script="$1"
  remote_run "sudo -n sh -c $(remote_quote "$script")"
}

remote_force_reboot() {
  local reboot_cmd='sudo -n sh -c '"'"'sync; echo b > /proc/sysrq-trigger'"'"''
  local saw_ping_drop=0

  log "Sending kernel sysrq reboot"
  if command -v timeout >/dev/null 2>&1; then
    timeout 10 sshpass -p "$PMOS_PASSWORD" ssh \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile="$run_dir/known_hosts" \
      -o ConnectTimeout=8 \
      -o PreferredAuthentications=password \
      -o PubkeyAuthentication=no \
      "$PMOS_USER@$PMOS_HOST" "$reboot_cmd" \
      > "$run_dir/reboot-sysrq.txt" 2>&1 || true
  else
    remote_run "$reboot_cmd" > "$run_dir/reboot-sysrq.txt" 2>&1 || true
  fi

  if command -v ping >/dev/null 2>&1; then
    for _ in {1..20}; do
      if ! ping -c 1 -W 1 "$PMOS_HOST" > "$run_dir/reboot-ping-last.txt" 2>&1; then
        saw_ping_drop=1
        break
      fi
      sleep 1
    done
    if [ "$saw_ping_drop" -eq 1 ]; then
      log "USB ping dropped after reboot command"
    else
      log "WARNING: did not observe USB ping drop after reboot command"
    fi
  fi
}

main() {
  validate_seconds LOCK_WAIT_SEC "$LOCK_WAIT_SEC"
  [ -n "$IMAGE" ] || die "Missing --image" 2
  [ -s "$IMAGE" ] || die "Missing or empty image: $IMAGE" 2
  [ "$PARTITION_LABEL" = "boot_b" ] || die "Refusing to flash anything except boot_b" 2
  [ -n "$PMOS_PASSWORD" ] || die "Set PMOS_PASSWORD or use --password" 2

  require_cmd ssh
  require_cmd sshpass
  require_cmd sha256sum
  require_cmd stat
  require_cmd awk

  local image_abs=""
  image_abs="$(readlink -f "$IMAGE")"
  local image_sha=""
  local image_size=""
  image_sha="$(sha256sum "$image_abs" | awk '{ print $1 }')"
  image_size="$(stat -c '%s' "$image_abs")"

  if [ -z "$REMOTE_DIR" ]; then
    REMOTE_DIR="/tmp/hotdog-flash-boot-b-$stamp"
  fi
  case "$REMOTE_DIR" in
    /tmp/hotdog-flash-*) ;;
    *) die "--remote-dir must be below /tmp/hotdog-flash-* for this safety wrapper" 2 ;;
  esac

  local remote_image="$REMOTE_DIR/boot.img"
  local remote_script="$REMOTE_DIR/write-boot-b.sh"

  log "Run directory: $run_dir"
  log "Image: $image_abs"
  log "Image sha256: $image_sha"
  log "Image size: $image_size bytes"
  log "Target: $PMOS_USER@$PMOS_HOST:$PARTITION_LABEL"
  log "Reboot after verify: $REBOOT"

  phone_lock_acquire "flash boot_b from pmOS SSH" "$LOCK_WAIT_SEC" ||
    die "Could not acquire local phone-operation lock" 3

  log "Probing SSH and noninteractive root"
  remote_run 'printf "ssh-ok "; uname -n; sudo -n id; test -x /etc/local.d/hotdog-devnodes.start || true'

  log "Creating remote work directory: $REMOTE_DIR"
  remote_run "mkdir -p $(remote_quote "$REMOTE_DIR")"

  log "Copying boot image over SSH"
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
partition_label="${PARTITION_LABEL:-boot_b}"
partition_path="${PARTITION_PATH:-}"

[ "$partition_label" = "boot_b" ] || die "Refusing to flash anything except boot_b" 2
[ -s "$img" ] || die "Missing remote image: $img" 2

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
case "$part_real" in
  /dev/sde38|/dev/block/*|/dev/disk/*)
    ;;
  *)
    log "Resolved boot_b block path: $part_real"
    ;;
esac

log "Writing $img to $part"
dd if="$img" of="$part" bs=4M conv=fsync
sync

blocks=$(( (expected_size + 1048575) / 1048576 ))
log "Verifying first $expected_size bytes from $part"
readback_sha="$(dd if="$part" bs=1048576 count="$blocks" 2>/dev/null | head -c "$expected_size" | sha256sum | awk '{ print $1 }')"
[ "$readback_sha" = "$expected_sha" ] || die "Readback sha256 mismatch: $readback_sha != $expected_sha" 6

log "boot_b verify OK: $readback_sha"
REMOTE_SCRIPT
  remote_run "chmod 700 $(remote_quote "$remote_script")"

  local remote_env=""
  remote_env="REMOTE_IMAGE=$(remote_quote "$remote_image")"
  remote_env="$remote_env EXPECTED_SHA=$(remote_quote "$image_sha")"
  remote_env="$remote_env EXPECTED_SIZE=$(remote_quote "$image_size")"
  remote_env="$remote_env PARTITION_LABEL=$(remote_quote "$PARTITION_LABEL")"
  remote_env="$remote_env PARTITION_PATH=$(remote_quote "$PARTITION_PATH")"

  log "Flashing and verifying boot_b from pmOS"
  remote_sudo_sh "$remote_env sh $(remote_quote "$remote_script")"

  if [ "$KEEP_REMOTE" -eq 0 ]; then
    log "Cleaning remote work directory"
    remote_run "rm -rf $(remote_quote "$REMOTE_DIR")" || true
  else
    log "Keeping remote work directory: $REMOTE_DIR"
  fi

  if [ "$REBOOT" -eq 1 ]; then
    log "Rebooting phone now"
    remote_force_reboot
  else
    log "No reboot requested; phone should remain reachable over pmOS SSH"
  fi

  log "Done: $run_dir"
}

main "$@"
