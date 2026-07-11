#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/env.sh"

usage() {
	cat <<'USAGE'
Usage: collect-mainline-acm-window.sh --out DIR [options]

Passively capture the short-lived mainline USB CDC ACM window. The collector
only reads host USB, udev, dmesg, and tty devices. It never uses adb,
fastboot, SSH, USB reset, or writes payload bytes to a tty device. It uses
host-side termios ioctls to disable echo before reading a tty.

Options:
  --out DIR             Directory for host-side evidence. Required.
  --ready-file FILE     Created only after udev and dmesg monitors are ready.
  --vendor HEX          Required USB idVendor. Default: 18d1.
  --bcd-device HEX      Required USB bcdDevice from sysfs. Default: 0617.
  --timeout SEC         Total monitoring time. Default: 420.
  --read-window SEC     Read-only tty capture duration. Default: 6.
  --self-test-pty       Run a host-only PTY no-echo regression test.
  -h, --help            Show this help.
USAGE
}

out_dir=""
ready_file=""
vendor="18d1"
bcd_device="0617"
timeout_sec=420
read_window_sec=6
monitor_pids=()
capture_started=0
dmesg_mode=""
dmesg_command=()
self_test_pty=0

log() {
	printf '[collect-mainline-acm-window] %s\n' "$*"
}

die() {
	printf '[collect-mainline-acm-window] ERROR: %s\n' "$*" >&2
	exit "${2:-1}"
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--out) [ "$#" -ge 2 ] || die "--out requires a value" 2; out_dir="$2"; shift ;;
		--ready-file) [ "$#" -ge 2 ] || die "--ready-file requires a value" 2; ready_file="$2"; shift ;;
		--vendor) [ "$#" -ge 2 ] || die "--vendor requires a value" 2; vendor="$2"; shift ;;
		--bcd-device) [ "$#" -ge 2 ] || die "--bcd-device requires a value" 2; bcd_device="$2"; shift ;;
		--timeout) [ "$#" -ge 2 ] || die "--timeout requires a value" 2; timeout_sec="$2"; shift ;;
		--read-window) [ "$#" -ge 2 ] || die "--read-window requires a value" 2; read_window_sec="$2"; shift ;;
		--self-test-pty) self_test_pty=1 ;;
		-h|--help) usage; exit 0 ;;
		*) usage >&2; die "unknown argument: $1" 2 ;;
	esac
	shift
done

normalize_hex() {
	local value="${1,,}"
	value="${value#0x}"
	printf '%s\n' "$value"
}

validate_seconds() {
	local name="$1"
	local value="$2"
	[[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -gt 0 ] || \
		die "$name must be a positive integer, got: $value" 2
}

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || die "missing command: $1" 127
}

timestamp() {
	printf 'wall=%s monotonic=%s\n' "$(date --iso-8601=ns)" "$(cat /proc/uptime 2>/dev/null || true)"
}

python_tty_reader() {
	python3 - "$@" <<'PY'
import json
import os
import pty
import select
import sys
import tempfile
import termios
import threading
import time
import tty


def read_tty(path, output_path, seconds, ready_callback=None):
    fd = os.open(path, os.O_RDONLY | os.O_NOCTTY | os.O_NONBLOCK)
    saved = None
    total = 0
    try:
        saved = termios.tcgetattr(fd)
        tty.setraw(fd, termios.TCSANOW)
        attrs = termios.tcgetattr(fd)
        attrs[3] &= ~(termios.ECHO | getattr(termios, "ECHONL", 0))
        termios.tcsetattr(fd, termios.TCSANOW, attrs)
        if ready_callback is not None:
            ready_callback()

        deadline = time.monotonic() + seconds
        with open(output_path, "wb", buffering=0) as output:
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    break
                readable, _, _ = select.select([fd], [], [], min(remaining, 0.1))
                if not readable:
                    continue
                try:
                    data = os.read(fd, 65536)
                except BlockingIOError:
                    continue
                if not data:
                    break
                output.write(data)
                total += len(data)
        return total
    finally:
        if saved is not None:
            try:
                termios.tcsetattr(fd, termios.TCSANOW, saved)
            except termios.error:
                pass
        os.close(fd)


def self_test_pty():
    master_fd, slave_fd = pty.openpty()
    slave_path = os.ttyname(slave_fd)
    ready = threading.Event()
    result = {}
    payload = b"mainline-acm-pty-no-echo\n"

    try:
        with tempfile.TemporaryDirectory(prefix="hotdog-acm-pty-") as tmpdir:
            output_path = os.path.join(tmpdir, "capture.raw")

            def reader():
                try:
                    result["bytes"] = read_tty(slave_path, output_path, 1.0, ready.set)
                except BaseException as exc:
                    result["error"] = repr(exc)

            thread = threading.Thread(target=reader, daemon=True)
            thread.start()
            if not ready.wait(1.0):
                raise RuntimeError("reader did not apply termios settings")

            os.write(master_fd, payload)
            echoed = bytearray()
            echo_deadline = time.monotonic() + 0.2
            while time.monotonic() < echo_deadline:
                readable, _, _ = select.select([master_fd], [], [], 0.02)
                if not readable:
                    continue
                try:
                    echoed.extend(os.read(master_fd, 65536))
                except BlockingIOError:
                    continue
                except OSError:
                    break

            thread.join(2.0)
            if thread.is_alive():
                raise RuntimeError("reader did not stop")
            if "error" in result:
                raise RuntimeError(result["error"])
            with open(output_path, "rb") as captured_file:
                captured = captured_file.read()

            if captured != payload:
                raise RuntimeError(f"captured payload mismatch: {captured!r}")
            if echoed:
                raise RuntimeError(f"echo leaked back to master: {bytes(echoed)!r}")
            print(json.dumps({"pty_self_test": "ok", "captured_bytes": result["bytes"]}))
    finally:
        os.close(slave_fd)
        os.close(master_fd)


if len(sys.argv) == 2 and sys.argv[1] == "--self-test-pty":
    self_test_pty()
elif len(sys.argv) == 4:
    bytes_read = read_tty(sys.argv[1], sys.argv[2], float(sys.argv[3]))
    print(json.dumps({"tty_reader": "complete", "bytes_read": bytes_read}))
else:
    raise SystemExit("usage: python_tty_reader TTY OUTPUT SECONDS | --self-test-pty")
PY
}

usb_parent_for_tty() {
	local tty_name="$1"
	local path=""
	local parent=""

	path="$(readlink -f "/sys/class/tty/$tty_name/device" 2>/dev/null || true)"
	[ -n "$path" ] || return 1

	while [ "$path" != "/" ] && [ -n "$path" ]; do
		if [ -r "$path/idVendor" ] && [ -r "$path/bcdDevice" ]; then
			printf '%s\n' "$path"
			return 0
		fi
		parent="$(dirname "$path")"
		[ "$parent" = "$path" ] && break
		path="$parent"
	done

	return 1
}

usb_matches() {
	local usb_path="$1"
	local found_vendor=""
	local found_bcd=""

	found_vendor="$(normalize_hex "$(cat "$usb_path/idVendor" 2>/dev/null || true)")"
	found_bcd="$(normalize_hex "$(cat "$usb_path/bcdDevice" 2>/dev/null || true)")"
	[ "$found_vendor" = "$vendor" ] && [ "$found_bcd" = "$bcd_device" ]
}

copy_usb_metadata() {
	local usb_path="$1"
	local metadata_dir="$2"
	local item=""
	local bus=""
	local dev=""

	for item in idVendor idProduct bcdDevice manufacturer product serial busnum devnum speed version; do
		[ -r "$usb_path/$item" ] && cat "$usb_path/$item" > "$metadata_dir/usb-$item.txt" 2>/dev/null || true
	done

	bus="$(cat "$usb_path/busnum" 2>/dev/null || true)"
	dev="$(cat "$usb_path/devnum" 2>/dev/null || true)"
	if [ -n "$bus" ] && [ -n "$dev" ]; then
		lsusb -s "$bus:$dev" -v > "$metadata_dir/lsusb-verbose.txt" 2>&1 || true
	fi
}

capture_tty() {
	local tty_path="$1"
	local tty_name="${tty_path##*/}"
	local usb_path="$2"
	local capture_dir=""
	local reader_pid=""

	capture_started=1
	capture_dir="$out_dir/captures/$(date +%Y-%m-%d-%H%M%S-%N)-$tty_name"
	mkdir -p "$capture_dir"

	log "matched $tty_path at $usb_path"
	timestamp > "$capture_dir/detected-at.txt"
	printf '%s\n' "$tty_path" > "$capture_dir/tty-path.txt"
	printf '%s\n' "$usb_path" > "$capture_dir/usb-sysfs-path.txt"

	# The Python reader opens O_RDONLY|O_NOCTTY|O_NONBLOCK and disables host echo.
	python_tty_reader "$tty_path" "$capture_dir/acm-read.raw" "$read_window_sec" \
		> "$capture_dir/acm-reader.stdout" 2> "$capture_dir/acm-reader.stderr" &
	reader_pid=$!

	ls -l /dev/ttyACM* /dev/serial/by-id/* > "$capture_dir/tty-inventory.txt" 2>&1 || true
	readlink -f "$tty_path" > "$capture_dir/tty-realpath.txt" 2>&1 || true
	stat "$tty_path" > "$capture_dir/tty-stat.txt" 2>&1 || true
	udevadm info --query=all --name="$tty_path" > "$capture_dir/tty-udev.txt" 2>&1 || true
	udevadm info --attribute-walk --name="$tty_path" > "$capture_dir/tty-udev-attributes.txt" 2>&1 || true
	copy_usb_metadata "$usb_path" "$capture_dir"
	ln -sfn "../../host-dmesg-usb.log" "$capture_dir/host-dmesg-usb.log"
	tail -n 320 "$out_dir/host-dmesg-usb.log" > "$capture_dir/dmesg-tail-at-detect.txt" 2>&1 || true
	tail -n 320 "$out_dir/udev-usb.log" > "$capture_dir/udev-usb-tail-at-detect.txt" 2>&1 || true
	tail -n 320 "$out_dir/udev-tty.log" > "$capture_dir/udev-tty-tail-at-detect.txt" 2>&1 || true

	wait "$reader_pid" || true
	timestamp > "$capture_dir/read-finished-at.txt"
	log "read-only capture complete: $capture_dir"
}

scan_for_matching_tty() {
	local tty_path=""
	local tty_name=""
	local usb_path=""
	local tries=0

	[ "$capture_started" -eq 0 ] || return 0
	for tty_path in /dev/ttyACM*; do
		[ -e "$tty_path" ] || continue
		tty_name="${tty_path##*/}"
		usb_path=""
		for ((tries = 0; tries < 10; tries++)); do
			usb_path="$(usb_parent_for_tty "$tty_name" || true)"
			if [ -n "$usb_path" ] && usb_matches "$usb_path"; then
				capture_tty "$tty_path" "$usb_path"
				return 0
			fi
			sleep 0.05
		done
	done
}

record_matching_usb_devices() {
	local usb_path=""
	local seen_file="$out_dir/matching-usb-devices.txt"
	local known_file="$out_dir/matching-usb-paths.txt"

	for usb_path in /sys/bus/usb/devices/*; do
		[ -d "$usb_path" ] || continue
		if usb_matches "$usb_path"; then
			if ! grep -Fqx -- "$usb_path" "$known_file" 2>/dev/null; then
				printf '%s\n' "$usb_path" >> "$known_file"
				printf '%s ' "$usb_path" >> "$seen_file"
				timestamp >> "$seen_file"
			fi
		fi
	done
}

start_monitor() {
	local output="$1"
	shift
	setsid "$@" > "$output" 2>&1 &
	monitor_pids+=("$!")
}

cleanup() {
	local pid=""
	for pid in "${monitor_pids[@]}"; do
		if kill -0 "$pid" 2>/dev/null; then
			kill -- "-$pid" 2>/dev/null || true
		fi
	done
	for pid in "${monitor_pids[@]}"; do
		wait "$pid" 2>/dev/null || true
	done
}

select_dmesg_command() {
	if dmesg --ctime >/dev/null 2>&1; then
		dmesg_mode="direct"
		dmesg_command=(dmesg --follow --ctime)
		return 0
	fi

	if command -v sudo >/dev/null 2>&1 && sudo -n dmesg --ctime >/dev/null 2>&1; then
		dmesg_mode="sudo-n"
		dmesg_command=(sudo -n dmesg --follow --ctime)
		return 0
	fi

	die "dmesg is unreadable directly and through sudo -n; refusing to create ready" 3
}

main() {
	local deadline=0
	local pid=""

	[ -n "$out_dir" ] || die "--out DIR is required" 2
	[ -n "$ready_file" ] || ready_file="$out_dir/ready"
	vendor="$(normalize_hex "$vendor")"
	bcd_device="$(normalize_hex "$bcd_device")"
	[[ "$vendor" =~ ^[0-9a-f]{4}$ ]] || die "--vendor must be four hex digits" 2
	[[ "$bcd_device" =~ ^[0-9a-f]{4}$ ]] || die "--bcd-device must be four hex digits" 2
	validate_seconds --timeout "$timeout_sec"
	validate_seconds --read-window "$read_window_sec"

	for command in udevadm dmesg date readlink lsusb stat tail cat grep setsid python3; do
		require_cmd "$command"
	done
	select_dmesg_command

	mkdir -p "$out_dir/captures"
	rm -f "$ready_file"
	exec > >(tee "$out_dir/collector.log") 2>&1
	trap cleanup EXIT

	timestamp > "$out_dir/started-at.txt"
	printf 'vendor=%s\nbcd_device=%s\ntimeout_sec=%s\nread_window_sec=%s\ndmesg_mode=%s\n' \
		"$vendor" "$bcd_device" "$timeout_sec" "$read_window_sec" "$dmesg_mode" > "$out_dir/criteria.txt"

	start_monitor "$out_dir/udev-usb.log" udevadm monitor --kernel --udev --property --subsystem-match=usb
	start_monitor "$out_dir/udev-tty.log" udevadm monitor --kernel --udev --property --subsystem-match=tty
	start_monitor "$out_dir/host-dmesg-usb.log" "${dmesg_command[@]}"

	sleep 0.1
	for pid in "${monitor_pids[@]}"; do
		kill -0 "$pid" 2>/dev/null || die "host evidence monitor exited before ready" 3
	done

	: > "$ready_file"
	log "ready: vendor=$vendor bcdDevice=$bcd_device out=$out_dir"

	deadline=$((SECONDS + timeout_sec))
	while [ "$SECONDS" -lt "$deadline" ]; do
		record_matching_usb_devices
		scan_for_matching_tty
		sleep 0.05
	done

	timestamp > "$out_dir/finished-at.txt"
	if [ "$capture_started" -eq 0 ]; then
		log "timed out without a matching ttyACM device"
	else
		log "monitoring timeout reached after read-only ACM capture"
	fi
}

if [ "$self_test_pty" -eq 1 ]; then
	python_tty_reader --self-test-pty
	exit 0
fi

main "$@"
