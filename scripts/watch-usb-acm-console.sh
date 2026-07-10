#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Usage: watch-usb-acm-console.sh [options]

Passively wait for a USB CDC ACM serial console, then capture it to logs and
create an input FIFO for commands. This script does not use adb, fastboot, SSH,
or USB reset.

Options:
  --timeout SEC   Seconds to wait for /dev/ttyACM*. Default: 86400.
  --poll SEC      Poll interval while waiting. Default: 2.
  --baud RATE     Serial baud rate. Default: 115200.
  --device DEV    Use a specific serial device instead of auto-detecting.
  -h, --help      Show this help.
USAGE
}

log() {
  printf '[watch-usb-acm-console] %s\n' "$*"
}

die() {
  printf '[watch-usb-acm-console] ERROR: %s\n' "$*" >&2
  exit 1
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/env.sh"

timeout_sec=86400
poll_sec=2
baud=115200
device=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --timeout)
      [ "$#" -ge 2 ] || die "--timeout requires a value"
      timeout_sec="$2"
      shift
      ;;
    --poll)
      [ "$#" -ge 2 ] || die "--poll requires a value"
      poll_sec="$2"
      shift
      ;;
    --baud)
      [ "$#" -ge 2 ] || die "--baud requires a value"
      baud="$2"
      shift
      ;;
    --device)
      [ "$#" -ge 2 ] || die "--device requires a path"
      device="$2"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "unknown argument: $1"
      ;;
  esac
  shift
done

case "$timeout_sec" in ""|*[!0-9]*) die "--timeout must be an integer" ;; esac
case "$poll_sec" in ""|*[!0-9]*) die "--poll must be an integer" ;; esac
case "$baud" in ""|*[!0-9]*) die "--baud must be an integer" ;; esac
[ "$timeout_sec" -gt 0 ] || die "--timeout must be > 0"
[ "$poll_sec" -gt 0 ] || die "--poll must be > 0"

stamp="$(date +%Y-%m-%d-%H%M%S)"
run_dir="$HOTDOG_LOG_ROOT/watch-usb-acm-console-$stamp"
mkdir -p "$run_dir"
echo $$ > "$HOTDOG_LOG_ROOT/watch-usb-acm-console.pid"

cleanup() {
  rm -f "$HOTDOG_LOG_ROOT/watch-usb-acm-console.pid"
}
trap cleanup EXIT

pick_device() {
  local dev

  if [ -n "$device" ]; then
    [ -e "$device" ] && printf '%s\n' "$device"
    return 0
  fi

  for dev in /dev/serial/by-id/*; do
    [ -e "$dev" ] || continue
    case "$(readlink -f "$dev" 2>/dev/null || true)" in
      /dev/ttyACM*)
        printf '%s\n' "$dev"
        return 0
        ;;
    esac
  done

  for dev in /dev/ttyACM*; do
    [ -e "$dev" ] || continue
    printf '%s\n' "$dev"
    return 0
  done

  return 1
}

log "Run directory: $run_dir"
log "Waiting for USB ACM serial console, timeout=${timeout_sec}s"
deadline=$((SECONDS + timeout_sec))
serial_dev=""
while [ "$SECONDS" -lt "$deadline" ]; do
  serial_dev="$(pick_device 2>/dev/null || true)"
  if [ -n "$serial_dev" ]; then
    break
  fi
  sleep "$poll_sec"
done

[ -n "$serial_dev" ] || die "timed out waiting for /dev/ttyACM*"

real_dev="$(readlink -f "$serial_dev" 2>/dev/null || printf '%s\n' "$serial_dev")"
log "Serial console found: $serial_dev -> $real_dev"
{
  printf 'serial_dev=%s\n' "$serial_dev"
  printf 'real_dev=%s\n' "$real_dev"
  printf 'baud=%s\n' "$baud"
  date -Iseconds
} > "$run_dir/metadata.txt"
ls -l /dev/ttyACM* /dev/serial/by-id/* > "$run_dir/devices.txt" 2>&1 || true
udevadm info --query=all --name="$real_dev" > "$run_dir/udev.txt" 2>&1 || true
lsusb > "$run_dir/lsusb.txt" 2>&1 || true
dmesg | tail -240 > "$run_dir/dmesg-tail-at-detect.txt" 2>&1 || true

stty -F "$real_dev" "$baud" raw -echo -crtscts -ixon -ixoff 2>"$run_dir/stty.err" || true

input_fifo="$run_dir/input.fifo"
capture="$run_dir/capture.txt"
touch "$capture"
mkfifo "$input_fifo"
log "Capture: $capture"
log "Input FIFO: $input_fifo"

(
  while :; do
    if IFS= read -r line < "$input_fifo"; then
      printf '%s\r\n' "$line" > "$real_dev" 2>>"$run_dir/write.err" || true
    fi
  done
) &
writer_pid=$!
echo "$writer_pid" > "$run_dir/writer.pid"

(
  # Wake pmOS run_getty-on-ttyGS0, which intentionally waits for host-side I/O.
  sleep 1
  printf '\r\n' > "$real_dev" 2>>"$run_dir/write.err" || true
  sleep 2
  printf 'printf "\\n--- hotdog usb acm auto-probe ---\\n"; uname -a; cat /proc/cmdline; ip -br addr 2>/dev/null || ip addr; dmesg | tail -80\r\n' \
    > "$real_dev" 2>>"$run_dir/write.err" || true
) &
echo $! > "$run_dir/autoprobe.pid"

set +e
cat "$real_dev" 2>"$run_dir/read.err" | tee -a "$capture"
reader_status=${PIPESTATUS[0]}
set -e

kill "$writer_pid" 2>/dev/null || true
log "Reader exited with status $reader_status"
exit "$reader_status"
