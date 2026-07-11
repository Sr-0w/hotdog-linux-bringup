#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/env.sh"
source "$(dirname "$0")/phone-lock.sh"

PMOS_HOST="${PMOS_HOST:-$HOTDOG_PMOS_HOST}"
PMOS_USER="${PMOS_USER:-$HOTDOG_PMOS_USER}"
PMOS_PASSWORD="${PMOS_PASSWORD:-$HOTDOG_PMOS_PASSWORD}"
SERIAL="${ANDROID_SERIAL:-$HOTDOG_TARGET_SERIAL}"

KEXEC_BINARY="$HOTDOG_ROOT/tools/aarch64/kexec-tools-2.0.32-r2/usr/sbin/kexec"
KERNEL="$HOTDOG_ROOT/build/experiments/2026-07-09-224000-mainline617-pstore-ramoops-kernel/Image"
DTB="$HOTDOG_ROOT/images/pmos-experiments/2026-07-09-014500-mainline617-external-appenddtb-header0-watchdog60/components/sm8150-oneplus-hotdog.dtb"
INITRAMFS="$HOTDOG_ROOT/images/pmos-experiments/2026-07-11-130500-lineage414-r5-kexec-fbwait-nopaint-acm-rootwatchdog/components/initramfs-watchdog.gz"
RESTORE_IMAGE="$HOTDOG_ROOT/images/pmos-experiments/2026-07-11-130500-lineage414-r5-kexec-fbwait-nopaint-acm-rootwatchdog/boot-noefi-pmosdtb-watchdog-300s.img"
REMOTE_DIR="${REMOTE_DIR:-/tmp/hotdog-kexec-mainline617}"
MODE="stage"
ALLOW_UNPINNED=0
APPEND_CMDLINE=""
BOOT_WAIT_SEC="${BOOT_WAIT_SEC:-420}"
LOCK_WAIT_SEC="${LOCK_WAIT_SEC:-0}"
DISABLE_BRIDGE_WATCHDOG=1
BRIDGE_WATCHDOG_DISABLE_PATH="${BRIDGE_WATCHDOG_DISABLE_PATH:-/sys/devices/platform/soc/17c10000.qcom,wdt/disable}"
CAPTURE_MAINLINE_ACM=0
ACM_COLLECTOR="$HOTDOG_ROOT/scripts/collect-mainline-acm-window.sh"
ACM_COLLECTOR_PID=""

DEFAULT_KEXEC_SHA="0e0524a41579c38a741ce53a2d44b77743135b2ada988d10e2ec3943f54f43f5"
DEFAULT_KERNEL_SHA="48ac790a9f15dbf3e976557d1baee6a72b847fefed17fed9e700424d91e3fa83"
DEFAULT_DTB_SHA="44052506301f7fcad9725c77a98323ec283adf1159b7bee941e7ed2ac3447b49"
DEFAULT_INITRAMFS_SHA="0fa76f009642df43bebb63a17dcafd2a07847ceca21a5073ace4a7886e185c1a"

KEXEC_CMDLINE="PMOS_NO_OUTPUT_REDIRECT clk_ignore_unused pmos_boot_uuid=9ecffd22-eacf-4b9f-9b0f-3f7ca738a731 pmos_root_uuid=de13a416-8942-4d87-9947-dce62fba9465 pmos_rootfsopts=defaults rootwait initcall_debug no_console_suspend keep_bootcon console=tty0 printk.devkmsg=on loglevel=8 ignore_loglevel vt.global_cursor_default=1 fbcon=map:0 fbcon=font:VGA8x16 fbcon=vc:1-1 printk.time=1 printk.always_kmsg_dump=1 ramoops.mem_address=0xa9800000 ramoops.mem_size=0x400000 ramoops.record_size=0x40000 ramoops.console_size=0x40000 ramoops.ftrace_size=0x40000 ramoops.pmsg_size=0x200000 ramoops.ecc=0 panic=10 oops=panic hotdog_rescue_watchdog_sec=300"

usage() {
  cat <<'USAGE'
Usage: test-mainline-via-kexec.sh [mode] [options]

Stage, load, or execute a mainline arm64 Image from the validated downstream
postmarketOS bridge kernel. No partition is written by this script.

Modes (default: --stage-only):
  --stage-only       Upload and verify all files; do not call kexec -l.
  --load-only        Stage and load the mainline kernel; do not execute it.
  --execute          Stage, load, arm a rescue watcher, then execute kexec.
  --unload           Stage kexec-tools and unload any previously loaded kernel.

Options:
  --kernel FILE      arm64 Image to load.
  --dtb FILE         Mainline hotdog DTB passed separately to kexec.
  --initramfs FILE   Initramfs passed to kexec.
  --kexec FILE       aarch64 kexec-tools binary.
  --cmdline TEXT     Kernel command line.
  --append-cmdline TEXT
                      Append parameters to the default or overridden command line.
  --restore FILE     Known-good boot_b image used by the rescue watcher.
  --host HOST        postmarketOS SSH host. Default: 172.16.42.1.
  --user USER        SSH user. Default: user.
  --password PASS    SSH password. Defaults to PMOS_PASSWORD.
  --serial SERIAL    Android/fastboot serial for the rescue watcher.
  --remote-dir DIR   Remote staging path below /tmp/hotdog-kexec-*.
  --boot-wait SEC    Wait for a new SSH boot after --execute. Default: 420.
  --lock-wait SEC    Wait for the local phone-operation lock. Default: 0.
  --keep-bridge-watchdog
                      Do not disable the downstream Qualcomm watchdog before kexec.
  --capture-mainline-acm
                      Start a passive host USB ACM+dmesg collector before kexec.
  --allow-unpinned   Allow overridden artifacts not matching pinned defaults.
  -h, --help         Show this help.

The bridge preflight requires CONFIG_KEXEC=y and CONFIG_DEVMEM=y in the
running kernel. --execute is the only mode that transfers control to mainline.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --stage-only) MODE="stage" ;;
    --load-only) MODE="load" ;;
    --execute) MODE="execute" ;;
    --unload) MODE="unload" ;;
    --kernel) KERNEL="$2"; shift ;;
    --dtb) DTB="$2"; shift ;;
    --initramfs) INITRAMFS="$2"; shift ;;
    --kexec) KEXEC_BINARY="$2"; shift ;;
    --cmdline) KEXEC_CMDLINE="$2"; shift ;;
    --append-cmdline) APPEND_CMDLINE="$2"; shift ;;
    --restore) RESTORE_IMAGE="$2"; shift ;;
    --host) PMOS_HOST="$2"; shift ;;
    --user) PMOS_USER="$2"; shift ;;
    --password) PMOS_PASSWORD="$2"; shift ;;
    --serial) SERIAL="$2"; shift ;;
    --remote-dir) REMOTE_DIR="$2"; shift ;;
    --boot-wait) BOOT_WAIT_SEC="$2"; shift ;;
    --lock-wait) LOCK_WAIT_SEC="$2"; shift ;;
    --keep-bridge-watchdog) DISABLE_BRIDGE_WATCHDOG=0 ;;
    --capture-mainline-acm) CAPTURE_MAINLINE_ACM=1 ;;
    --allow-unpinned) ALLOW_UNPINNED=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [ -n "$APPEND_CMDLINE" ]; then
  KEXEC_CMDLINE="$KEXEC_CMDLINE $APPEND_CMDLINE"
fi

stamp="$(date +%F-%H%M%S)"
run_dir="$HOTDOG_LOG_ROOT/test-mainline-via-kexec-$stamp"
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
  if [ -n "$ACM_COLLECTOR_PID" ] && kill -0 "$ACM_COLLECTOR_PID" 2>/dev/null; then
    kill "$ACM_COLLECTOR_PID" 2>/dev/null || true
    wait "$ACM_COLLECTOR_PID" 2>/dev/null || true
  fi
  phone_lock_release || true
}
trap cleanup EXIT

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing command: $1" 127
}

validate_seconds() {
  local name="$1"
  local value="$2"
  [[ "$value" =~ ^[0-9]+$ ]] || die "$name must be a non-negative integer, got: $value" 2
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

local_sha() {
  sha256sum "$1" | awk '{ print $1 }'
}

check_pinned_sha() {
  local label="$1"
  local file="$2"
  local expected="$3"
  local actual=""

  actual="$(local_sha "$file")"
  log "$label sha256: $actual"
  if [ "$actual" != "$expected" ] && [ "$ALLOW_UNPINNED" -ne 1 ]; then
    die "$label differs from the pinned candidate; pass --allow-unpinned for an intentional override" 2
  fi
}

upload_and_verify() {
  local label="$1"
  local source="$2"
  local target="$3"
  local expected=""
  local actual=""

  expected="$(local_sha "$source")"
  log "Uploading $label to $target"
  ssh_base "cat > $(remote_quote "$target")" < "$source"
  actual="$(remote_run "sha256sum $(remote_quote "$target")" | awk '{ print $1 }')"
  [ "$actual" = "$expected" ] || die "$label remote hash mismatch: expected $expected, got ${actual:-missing}" 3
  log "$label remote hash verified"
}

bridge_preflight() {
  local probe=""

  log "Checking SSH, root access, and bridge kernel configuration"
  probe="$(remote_run 'printf "boot_id="; cat /proc/sys/kernel/random/boot_id; printf "uname_r="; uname -r; sudo -n id; gzip -dc /proc/config.gz | grep -E "^CONFIG_(KEXEC|DEVMEM)=y$"')" ||
    die "Bridge preflight failed; the r5 kernel may not be running" 3
  printf '%s\n' "$probe" | tee "$run_dir/bridge-preflight.txt"
  grep -q '^CONFIG_KEXEC=y$' "$run_dir/bridge-preflight.txt" || die "Running kernel lacks CONFIG_KEXEC=y" 3
  grep -q '^CONFIG_DEVMEM=y$' "$run_dir/bridge-preflight.txt" || die "Running kernel lacks CONFIG_DEVMEM=y" 3
}

stage_files() {
  local remote_kexec="$REMOTE_DIR/kexec"
  local remote_kernel="$REMOTE_DIR/Image"
  local remote_dtb="$REMOTE_DIR/hotdog.dtb"
  local remote_initramfs="$REMOTE_DIR/initramfs.gz"

  remote_run "rm -rf $(remote_quote "$REMOTE_DIR"); mkdir -p $(remote_quote "$REMOTE_DIR")"
  upload_and_verify "kexec-tools" "$KEXEC_BINARY" "$remote_kexec"
  upload_and_verify "mainline Image" "$KERNEL" "$remote_kernel"
  upload_and_verify "mainline DTB" "$DTB" "$remote_dtb"
  upload_and_verify "initramfs" "$INITRAMFS" "$remote_initramfs"
  remote_run "chmod 700 $(remote_quote "$remote_kexec"); $(remote_quote "$remote_kexec") --version"
  remote_run "printf '%s\n' $(remote_quote "$KEXEC_CMDLINE") > $(remote_quote "$REMOTE_DIR/cmdline")"
  log "Remote staging complete: $REMOTE_DIR"
}

unload_kernel() {
  log "Unloading any previously prepared kexec image"
  remote_run "sudo -n $(remote_quote "$REMOTE_DIR/kexec") -c -u" || true
}

load_kernel() {
  unload_kernel
  log "Loading mainline Image, initramfs, and DTB without executing"
  remote_run "sudo -n $(remote_quote "$REMOTE_DIR/kexec") -c -l $(remote_quote "$REMOTE_DIR/Image") --initrd=$(remote_quote "$REMOTE_DIR/initramfs.gz") --dtb=$(remote_quote "$REMOTE_DIR/hotdog.dtb") --command-line=$(remote_quote "$KEXEC_CMDLINE")"
  log "kexec load completed"
}

start_mainline_acm_collector() {
  local collector_dir="$run_dir/mainline-acm"
  local ready_file="$collector_dir/ready"
  local deadline=$((SECONDS + 5))

  [ "$CAPTURE_MAINLINE_ACM" -eq 1 ] || return 0
  [ -s "$ACM_COLLECTOR" ] || die "Missing ACM collector: $ACM_COLLECTOR" 2
  require_cmd udevadm
  require_cmd dmesg
  require_cmd lsusb

  mkdir -p "$collector_dir"
  log "Starting passive mainline ACM collector before kexec"
  bash "$ACM_COLLECTOR" \
    --out "$collector_dir" \
    --ready-file "$ready_file" \
    --vendor 18d1 \
    --bcd-device 0617 \
    --timeout "$BOOT_WAIT_SEC" \
    > "$collector_dir/launcher.log" 2>&1 &
  ACM_COLLECTOR_PID=$!
  printf '%s\n' "$ACM_COLLECTOR_PID" > "$collector_dir/pid"

  while [ "$SECONDS" -lt "$deadline" ]; do
    if [ -e "$ready_file" ] && kill -0 "$ACM_COLLECTOR_PID" 2>/dev/null; then
      log "Passive mainline ACM collector ready: PID $ACM_COLLECTOR_PID"
      return 0
    fi
    if ! kill -0 "$ACM_COLLECTOR_PID" 2>/dev/null; then
      wait "$ACM_COLLECTOR_PID" 2>/dev/null || true
      die "Passive mainline ACM collector exited before ready; see $collector_dir/launcher.log" 3
    fi
    sleep 0.05
  done

  die "Passive mainline ACM collector did not become ready before kexec" 3
}

start_rescue_watcher() {
  local pidfile="$run_dir/rescue-watcher.pid"
  local watcher_log="$run_dir/rescue-watcher.log"
  local watcher_err="$run_dir/rescue-watcher.err"
  local existing=""

  existing="$(pgrep -f "$HOTDOG_ROOT/scripts/rescue-boot-b-when-visible.sh.*--serial $SERIAL" | head -n 1 || true)"
  if [ -n "$existing" ]; then
    log "Reusing existing rescue watcher PID $existing"
    return 0
  fi

  log "Starting rescue watcher before kexec execution"
  if command -v start-stop-daemon >/dev/null 2>&1; then
    start-stop-daemon --start --background --make-pidfile --pidfile "$pidfile" \
      --chdir "$HOTDOG_ROOT" \
      --env HOTDOG_RESCUE_LOG_TEE=0 \
      --stdout "$watcher_log" --stderr "$watcher_err" \
      --exec "$HOTDOG_ROOT/scripts/rescue-boot-b-when-visible.sh" -- \
      --serial "$SERIAL" \
      --restore-boot-b "$RESTORE_IMAGE" \
      --after-restore system \
      --timeout 21600 \
      --poll 5
    log "Rescue watcher PID $(sed -n '1p' "$pidfile")"
  else
    setsid env HOTDOG_RESCUE_LOG_TEE=0 "$HOTDOG_ROOT/scripts/rescue-boot-b-when-visible.sh" \
      --serial "$SERIAL" \
      --restore-boot-b "$RESTORE_IMAGE" \
      --after-restore system \
      --timeout 21600 \
      --poll 5 \
      > "$watcher_log" 2> "$watcher_err" < /dev/null &
    printf '%s\n' "$!" > "$pidfile"
    log "Rescue watcher PID $!"
  fi
}

disable_bridge_watchdog() {
  local remote_script=""
  local result=""

  if [ "$DISABLE_BRIDGE_WATCHDOG" -ne 1 ]; then
    log "Leaving the downstream Qualcomm watchdog enabled by request"
    return 0
  fi

  remote_script="path=$(remote_quote "$BRIDGE_WATCHDOG_DISABLE_PATH")
[ -r \"\$path\" ] && [ -w \"\$path\" ] || { echo \"watchdog control unavailable: \$path\" >&2; exit 1; }
before=\$(cat \"\$path\")
printf '1\\n' > \"\$path\"
after=\$(cat \"\$path\")
printf 'path=%s\\nbefore=%s\\nafter=%s\\n' \"\$path\" \"\$before\" \"\$after\"
[ \"\$after\" = 1 ]"

  log "Disabling the downstream Qualcomm watchdog before kexec"
  result="$(remote_run "sudo -n sh -c $(remote_quote "$remote_script")")" ||
    die "Could not disable the downstream Qualcomm watchdog; refusing an inherited-watchdog kexec" 3
  printf '%s\n' "$result" | tee "$run_dir/bridge-watchdog-disable.txt"
}

remote_boot_id() {
  timeout 10 sshpass -p "$PMOS_PASSWORD" ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile="$run_dir/known_hosts" \
    -o ConnectTimeout=3 \
    -o PreferredAuthentications=password \
    -o PubkeyAuthentication=no \
    "$PMOS_USER@$PMOS_HOST" 'cat /proc/sys/kernel/random/boot_id; uname -r' 2>/dev/null
}

execute_kernel() {
  local boot_before=""
  local probe=""
  local new_boot_id=""
  local new_uname=""
  local deadline=$((SECONDS + BOOT_WAIT_SEC))

  boot_before="$(remote_run 'cat /proc/sys/kernel/random/boot_id')"
  printf '%s\n' "$boot_before" > "$run_dir/boot-id-before.txt"
  start_mainline_acm_collector
  start_rescue_watcher
  disable_bridge_watchdog

  log "Executing kexec now; boot_b remains the r5 bridge image"
  timeout 15 sshpass -p "$PMOS_PASSWORD" ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile="$run_dir/known_hosts" \
    -o ConnectTimeout=8 \
    -o PreferredAuthentications=password \
    -o PubkeyAuthentication=no \
    "$PMOS_USER@$PMOS_HOST" \
    "sudo -n sh -c $(remote_quote "sync; $REMOTE_DIR/kexec -e")" \
    > "$run_dir/kexec-execute.txt" 2>&1 || true

  phone_lock_release || true
  log "Waiting up to ${BOOT_WAIT_SEC}s for a new SSH boot"
  while [ "$SECONDS" -lt "$deadline" ]; do
    probe="$(remote_boot_id || true)"
    if [ -n "$probe" ]; then
      new_boot_id="$(printf '%s\n' "$probe" | sed -n '1p')"
      new_uname="$(printf '%s\n' "$probe" | sed -n '2p')"
      if [ -n "$new_boot_id" ] && [ "$new_boot_id" != "$boot_before" ]; then
        printf '%s\n' "$probe" | tee "$run_dir/boot-after.txt"
        case "$new_uname" in
          6.17.0-sm8150*) log "SUCCESS: mainline userspace reached SSH ($new_uname)" ;;
          4.14.357-openela-perf*) log "Mainline reset or failed; the persistent r5 bridge recovered automatically" ;;
          *) log "A new SSH boot appeared with kernel: ${new_uname:-unknown}" ;;
        esac
        return 0
      fi
    fi
    sleep 3
  done

  log "No new SSH boot appeared; the detached rescue watcher remains armed"
  return 4
}

main() {
  validate_seconds BOOT_WAIT_SEC "$BOOT_WAIT_SEC"
  validate_seconds LOCK_WAIT_SEC "$LOCK_WAIT_SEC"
  [ -n "$PMOS_PASSWORD" ] || die "Set PMOS_PASSWORD or use --password" 2
  if [ "$MODE" = "execute" ]; then
    [ -n "$SERIAL" ] || die "Set ANDROID_SERIAL or HOTDOG_TARGET_SERIAL before --execute" 2
  fi
  case "$REMOTE_DIR" in
    /tmp/hotdog-kexec-*) ;;
    *) die "--remote-dir must be below /tmp/hotdog-kexec-*" 2 ;;
  esac

  require_cmd ssh
  require_cmd sshpass
  require_cmd sha256sum
  require_cmd awk
  require_cmd timeout

  [ -s "$KEXEC_BINARY" ] || die "Missing kexec binary: $KEXEC_BINARY" 2
  [ -s "$KERNEL" ] || die "Missing kernel: $KERNEL" 2
  [ -s "$DTB" ] || die "Missing DTB: $DTB" 2
  [ -s "$INITRAMFS" ] || die "Missing initramfs: $INITRAMFS" 2
  [ -s "$RESTORE_IMAGE" ] || die "Missing restore image: $RESTORE_IMAGE" 2

  check_pinned_sha "kexec-tools" "$KEXEC_BINARY" "$DEFAULT_KEXEC_SHA"
  check_pinned_sha "mainline Image" "$KERNEL" "$DEFAULT_KERNEL_SHA"
  check_pinned_sha "mainline DTB" "$DTB" "$DEFAULT_DTB_SHA"
  check_pinned_sha "initramfs" "$INITRAMFS" "$DEFAULT_INITRAMFS_SHA"

  log "Run directory: $run_dir"
  log "Mode: $MODE"
  phone_lock_acquire "mainline kexec $MODE" "$LOCK_WAIT_SEC" ||
    die "Could not acquire local phone-operation lock" 3

  bridge_preflight
  stage_files
  case "$MODE" in
    stage) log "Stage-only complete; no kexec image was loaded" ;;
    unload) unload_kernel; log "Unload complete" ;;
    load) load_kernel; log "Load-only complete; mainline was not executed" ;;
    execute) load_kernel; execute_kernel ;;
    *) die "Internal mode error: $MODE" 2 ;;
  esac
}

main "$@"
