#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=/dev/null
source "$(dirname "$0")/env.sh"
# shellcheck source=/dev/null
source "$(dirname "$0")/phone-lock.sh"

PMOS_HOST="${PMOS_HOST:-$HOTDOG_PMOS_HOST}"
PMOS_USER="${PMOS_USER:-$HOTDOG_PMOS_USER}"
PMOS_PASSWORD="${PMOS_PASSWORD:-$HOTDOG_PMOS_PASSWORD}"
TARGET_SERIAL="${ANDROID_SERIAL:-$HOTDOG_TARGET_SERIAL}"
EXPECTED_KERNEL_MARKER="${EXPECTED_KERNEL_MARKER:-oneplus-hotdog-mainline616}"
WIDTH="${WIDTH:-640}"
HEIGHT="${HEIGHT:-480}"
POLL_TIMEOUT_MS="${POLL_TIMEOUT_MS:-8000}"
stamp="$(date +%F-%H%M%S)"
OUT="${OUT:-$HOTDOG_LOG_ROOT/camera-csid-tpg-$stamp}"
REMOTE_DIR="/tmp/hotdog-camera-csid-tpg-$stamp"
REMOTE_CAPTURE="$REMOTE_DIR/camera-prefill-capture.py"
REMOTE_SUDO_MODE=""

usage() {
	cat <<'USAGE'
Usage: test-mainline616-camera-csid-tpg.sh [options]

Isolate the SM8150 CSID-to-VFE path with the CSID generation-2 color-bars
test pattern. The physical CSIPHY link is disabled only for the duration of
the test and restored on exit. This script never flashes or resets the phone.

Options:
  --host HOST           SSH host. Default: 172.16.42.1.
  --user USER           SSH user. Default: user.
  --password PASS       SSH and sudo password. Defaults to PMOS_PASSWORD.
  --kernel-marker TEXT  Required substring in uname -a.
  --serial SERIAL       Required androidboot.serialno value.
  --width PIXELS        Test frame width. Default: 640.
  --height PIXELS       Test frame height. Default: 480.
  --poll-timeout MS     Per-frame poll timeout. Default: 8000.
  --out DIR             Host output directory.
  -h, --help            Show this help.
USAGE
}

log() {
	printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

die() {
	log "ERROR: $1" >&2
	exit "${2:-1}"
}

positive_integer() {
	local name="$1"
	local value="$2"

	[[ "$value" =~ ^[1-9][0-9]*$ ]] || die "$name must be a positive integer: $value" 2
}

cleanup() {
	phone_lock_release || true
}
trap cleanup EXIT INT TERM

ssh_base() {
	sshpass -p "$PMOS_PASSWORD" ssh \
		-o StrictHostKeyChecking=no \
		-o UserKnownHostsFile="$OUT/known_hosts" \
		-o ConnectTimeout=5 \
		-o ServerAliveInterval=2 \
		-o ServerAliveCountMax=2 \
		-o PreferredAuthentications=password \
		-o PubkeyAuthentication=no \
		"$PMOS_USER@$PMOS_HOST" "$@"
}

scp_base() {
	sshpass -p "$PMOS_PASSWORD" scp \
		-o StrictHostKeyChecking=no \
		-o UserKnownHostsFile="$OUT/known_hosts" \
		-o ConnectTimeout=5 \
		-o PreferredAuthentications=password \
		-o PubkeyAuthentication=no \
		"$@"
}

detect_remote_sudo_mode() {
	if ssh_base 'sudo -n true' >/dev/null 2>&1; then
		REMOTE_SUDO_MODE=noninteractive
	elif printf '%s\n' "$PMOS_PASSWORD" |
		ssh_base "sudo -S -p '' true" >/dev/null 2>&1; then
		REMOTE_SUDO_MODE=password
	else
		die "remote sudo authentication failed" 3
	fi
}

remote_program() {
	cat <<'REMOTE'
set -eu

out="$1"
capture_helper="$2"
width="$3"
height="$4"
poll_timeout_ms="$5"
media=/dev/media0
format="fmt:SGRBG10_1X10/${width}x${height}"
physical_link='"msm_csiphy0":1 -> "msm_csid0":0'
restore_needed=0
dmesg_pid=

find_video_node() {
	wanted="$1"
	for name_file in /sys/class/video4linux/*/name; do
		[ -r "$name_file" ] || continue
		if [ "$(cat "$name_file")" = "$wanted" ]; then
			printf '/dev/%s\n' "$(basename "$(dirname "$name_file")")"
			return 0
		fi
	done
	return 1
}

restore_graph() {
	set +e
	[ "$restore_needed" -eq 1 ] || return 0
	if [ -n "${csid:-}" ]; then
		v4l2-ctl -d "$csid" --set-ctrl=test_pattern=0
	fi
	media-ctl -d "$media" -l "$physical_link [1]"
	printf '%s\n' 'RESTORE attempted=1'
}

stop_dmesg() {
	set +e
	[ -n "$dmesg_pid" ] || return 0
	kill "$dmesg_pid" 2>/dev/null || true
	wait "$dmesg_pid" 2>/dev/null || true
	dmesg_pid=
}

cleanup_remote() {
	stop_dmesg
	restore_graph
}
trap cleanup_remote EXIT HUP INT TERM

mkdir -p "$out"
csid="$(find_video_node msm_csid0)" || {
	echo 'missing msm_csid0 subdevice' >&2
	exit 20
}
video="$(find_video_node msm_vfe0_rdi0)" || {
	echo 'missing msm_vfe0_rdi0 video node' >&2
	exit 20
}

for command_name in dmesg media-ctl python3 v4l2-ctl; do
	command -v "$command_name" >/dev/null 2>&1 || {
		echo "missing $command_name" >&2
		exit 21
	}
done

printf 'IDENTITY csid=%s video=%s width=%s height=%s\n' "$csid" "$video" "$width" "$height"
media-ctl -d "$media" -p > "$out/media-before.txt"
dmesg > "$out/dmesg-before.txt"

grep -F -- '-> "msm_vfe0_rdi0":0 [ENABLED' "$out/media-before.txt" >/dev/null || {
	echo 'CSID0 source pad 1 is not linked to VFE0 RDI0; refusing to alter that link' >&2
	exit 22
}
grep -F -- '-> "msm_csid0":0 [ENABLED' "$out/media-before.txt" >/dev/null || {
	echo 'CSIPHY0 is not linked to CSID0; refusing to change an unknown graph state' >&2
	exit 22
}

restore_needed=1
media-ctl -d "$media" -l "$physical_link [0]"
v4l2-ctl -d "$csid" --set-ctrl=test_pattern=9
v4l2-ctl -d "$csid" --get-ctrl=test_pattern

media-ctl -d "$media" -V "\"msm_csid0\":1 [$format]"
media-ctl -d "$media" -V "\"msm_vfe0_rdi0\":0 [$format]"
v4l2-ctl -d "$video" \
	--set-fmt-video="width=$width,height=$height,pixelformat=pgAA"

media-ctl -d "$media" -p > "$out/media-test.txt"
v4l2-ctl -d "$csid" --get-subdev-fmt pad=1 > "$out/csid-format.txt"
v4l2-ctl -d "$video" --get-fmt-video > "$out/video-format.txt"

dmesg -w > "$out/dmesg-live.txt" 2>&1 &
dmesg_pid=$!
set +e
python3 "$capture_helper" \
	--device "$video" \
	--buffers 2 \
	--frames 3 \
	--poll-timeout-ms "$poll_timeout_ms" \
	--fill 0xaa \
	--dump-first "$out/first-frame.raw" \
	> "$out/capture.txt" 2>&1
capture_status=$?
set -e
cat "$out/capture.txt"
kill "$dmesg_pid" 2>/dev/null || true
wait "$dmesg_pid" 2>/dev/null || true
dmesg_pid=
dmesg > "$out/dmesg-after.txt"
printf 'CAPTURE status=%s\n' "$capture_status"

v4l2-ctl -d "$csid" --set-ctrl=test_pattern=0
media-ctl -d "$media" -l "$physical_link [1]"
restore_needed=0
media-ctl -d "$media" -p > "$out/media-restored.txt"
trap - EXIT HUP INT TERM
chmod -R a+rX "$out"
exit "$capture_status"
REMOTE
}

while [ "$#" -gt 0 ]; do
	case "$1" in
	--host)
		[ "$#" -ge 2 ] || die "missing value for --host"
		PMOS_HOST="$2"
		shift
		;;
	--user)
		[ "$#" -ge 2 ] || die "missing value for --user"
		PMOS_USER="$2"
		shift
		;;
	--password)
		[ "$#" -ge 2 ] || die "missing value for --password"
		PMOS_PASSWORD="$2"
		shift
		;;
	--kernel-marker)
		[ "$#" -ge 2 ] || die "missing value for --kernel-marker"
		EXPECTED_KERNEL_MARKER="$2"
		shift
		;;
	--serial)
		[ "$#" -ge 2 ] || die "missing value for --serial"
		TARGET_SERIAL="$2"
		shift
		;;
	--width)
		[ "$#" -ge 2 ] || die "missing value for --width"
		WIDTH="$2"
		shift
		;;
	--height)
		[ "$#" -ge 2 ] || die "missing value for --height"
		HEIGHT="$2"
		shift
		;;
	--poll-timeout)
		[ "$#" -ge 2 ] || die "missing value for --poll-timeout"
		POLL_TIMEOUT_MS="$2"
		shift
		;;
	--out)
		[ "$#" -ge 2 ] || die "missing value for --out"
		OUT="$2"
		shift
		;;
	-h|--help)
		usage
		exit 0
		;;
	*)
		die "unknown argument: $1"
		;;
	esac
	shift
done

positive_integer WIDTH "$WIDTH"
positive_integer HEIGHT "$HEIGHT"
positive_integer POLL_TIMEOUT_MS "$POLL_TIMEOUT_MS"
[ -n "$PMOS_PASSWORD" ] || die "set PMOS_PASSWORD or use --password"
[ -n "$EXPECTED_KERNEL_MARKER" ] || die "kernel marker must not be empty"

for command_name in ping scp ssh sshpass timeout; do
	command -v "$command_name" >/dev/null 2>&1 || die "missing $command_name" 127
done

mkdir -p "$OUT"
exec > >(tee "$OUT/run.log") 2>&1
phone_lock_acquire "mainline616 CSID test-pattern diagnostic" 0 ||
	die "could not acquire phone-operation lock" 3

ping -c 1 -W 2 "$PMOS_HOST" >/dev/null 2>&1 || die "phone is not reachable at $PMOS_HOST" 4

uname_output="$(ssh_base 'uname -a')" || die "SSH or uname failed" 4
cmdline="$(ssh_base 'cat /proc/cmdline')" || die "could not read /proc/cmdline" 4
boot_id="$(ssh_base 'cat /proc/sys/kernel/random/boot_id')" || die "could not read boot ID" 4
printf '%s\n' "$uname_output" | tee "$OUT/uname.txt"
printf '%s\n' "$cmdline" > "$OUT/cmdline.txt"
printf '%s\n' "$boot_id" > "$OUT/boot-id.txt"

[[ "$uname_output" == *"$EXPECTED_KERNEL_MARKER"* ]] ||
	die "running kernel does not contain marker: $EXPECTED_KERNEL_MARKER" 5
if [ -n "$TARGET_SERIAL" ] && [[ "$cmdline" != *"androidboot.serialno=$TARGET_SERIAL"* ]]; then
	die "running target serial does not match the configured serial" 5
fi

detect_remote_sudo_mode
ssh_base "mkdir -p '$REMOTE_DIR'" || die "could not create remote test directory" 6
scp_base "$(dirname "$0")/camera-prefill-capture.py" \
	"$PMOS_USER@$PMOS_HOST:$REMOTE_CAPTURE" || die "could not stage capture helper" 6

log "Running CSID color-bars test on boot $boot_id"
set +e
if [ "$REMOTE_SUDO_MODE" = noninteractive ]; then
	remote_program |
		timeout --signal=TERM --kill-after=3 45 \
		sshpass -p "$PMOS_PASSWORD" ssh \
			-o StrictHostKeyChecking=no \
			-o UserKnownHostsFile="$OUT/known_hosts" \
			-o ConnectTimeout=5 \
			-o ServerAliveInterval=2 \
			-o ServerAliveCountMax=2 \
			-o PreferredAuthentications=password \
			-o PubkeyAuthentication=no \
			"$PMOS_USER@$PMOS_HOST" \
			"sudo -n sh -s -- '$REMOTE_DIR' '$REMOTE_CAPTURE' '$WIDTH' '$HEIGHT' '$POLL_TIMEOUT_MS'" \
		> >(tee "$OUT/test.txt") 2> >(tee "$OUT/test.stderr" >&2)
	test_status=${PIPESTATUS[1]}
else
	{
		printf '%s\n' "$PMOS_PASSWORD"
		remote_program
	} |
		timeout --signal=TERM --kill-after=3 45 \
		sshpass -p "$PMOS_PASSWORD" ssh \
			-o StrictHostKeyChecking=no \
			-o UserKnownHostsFile="$OUT/known_hosts" \
			-o ConnectTimeout=5 \
			-o ServerAliveInterval=2 \
			-o ServerAliveCountMax=2 \
			-o PreferredAuthentications=password \
			-o PubkeyAuthentication=no \
			"$PMOS_USER@$PMOS_HOST" \
			"sudo -S -p '' sh -s -- '$REMOTE_DIR' '$REMOTE_CAPTURE' '$WIDTH' '$HEIGHT' '$POLL_TIMEOUT_MS'" \
		> >(tee "$OUT/test.txt") 2> >(tee "$OUT/test.stderr" >&2)
	test_status=${PIPESTATUS[1]}
fi
set -e

mkdir -p "$OUT/remote"
set +e
scp_base -r "$PMOS_USER@$PMOS_HOST:$REMOTE_DIR/." "$OUT/remote" \
	> >(tee "$OUT/scp.txt") 2> >(tee "$OUT/scp.stderr" >&2)
scp_status=$?
set -e

printf 'test_status=%s\nscp_status=%s\n' "$test_status" "$scp_status" > "$OUT/result.txt"
if [ "$test_status" -eq 124 ] || [ "$test_status" -eq 137 ]; then
	die "camera test exceeded its host timeout; inspect USB state before any reset" 7
fi
if [ "$test_status" -ne 0 ]; then
	die "camera test failed with status $test_status; evidence is in $OUT" 8
fi
if [ "$scp_status" -ne 0 ]; then
	die "test completed but remote artifacts could not be copied" 9
fi

log "CSID test-pattern evidence: $OUT"
