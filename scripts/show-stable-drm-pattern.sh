#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/env.sh"

PMOS_HOST="${PMOS_HOST:-172.16.42.1}"
PMOS_USER="${PMOS_USER:-user}"
PMOS_PASSWORD="${PMOS_PASSWORD:-$HOTDOG_PMOS_PASSWORD}"
CONNECTOR="${CONNECTOR:-28}"
CRTC="${CRTC:-136}"
MODE="${MODE:-#0}"
PATTERN="${PATTERN:-smpte}"

usage() {
	cat <<'USAGE'
Usage: show-stable-drm-pattern.sh [start|stop|status|collect]

Start or stop a non-destructive DRM/KMS test pattern on a booted downstream
pmOS system reachable over USB SSH. This helper does not use adb, fastboot, or
block devices.

Environment:
  PMOS_HOST       SSH host. Default: 172.16.42.1
  PMOS_USER       SSH user. Default: user
  PMOS_PASSWORD   Required SSH password
  CONNECTOR       modetest connector id. Default: 28 (DSI-1)
  CRTC            modetest CRTC id. Default: 136
  MODE            modetest mode selector. Default: #0
  PATTERN         modetest fill pattern. Default: smpte
USAGE
}

die() {
	printf 'show-stable-drm-pattern: %s\n' "$*" >&2
	exit 2
}

ssh_base() {
	sshpass -p "$PMOS_PASSWORD" ssh \
		-o StrictHostKeyChecking=no \
		-o UserKnownHostsFile=/dev/null \
		-o ConnectTimeout=8 \
		-o ServerAliveInterval=10 \
		"$PMOS_USER@$PMOS_HOST" "$@"
}

remote_stop() {
	sudo -n sh -s <<'REMOTE'
set -eu
if [ -r /tmp/hotdog-modetest-held.pid ]; then
	kill "$(cat /tmp/hotdog-modetest-held.pid)" 2>/dev/null || true
	rm -f /tmp/hotdog-modetest-held.pid
fi
pgrep -x modetest | while read -r p; do kill "$p" 2>/dev/null || true; done
REMOTE
}

remote_start() {
	local connector="$1"
	local crtc="$2"
	local mode="$3"
	local pattern="$4"

	CONNECTOR="$connector" CRTC="$crtc" MODE="$mode" PATTERN="$pattern" sudo -n sh -s <<'REMOTE'
set -eu
if ! command -v modetest >/dev/null 2>&1; then
	echo "missing modetest; install libdrm-tests on the booted pmOS rootfs" >&2
	exit 127
fi

if [ -r /tmp/hotdog-modetest-held.pid ]; then
	kill "$(cat /tmp/hotdog-modetest-held.pid)" 2>/dev/null || true
	rm -f /tmp/hotdog-modetest-held.pid
fi
pgrep -x kmscube | while read -r p; do kill "$p" 2>/dev/null || true; done
pgrep -x modetest | while read -r p; do kill "$p" 2>/dev/null || true; done
pkill plymouthd 2>/dev/null || true

for d in /sys/class/backlight/*; do
	[ -w "$d/bl_power" ] && echo 0 > "$d/bl_power" || true
	if [ -r "$d/max_brightness" ] && [ -w "$d/brightness" ]; then
		cat "$d/max_brightness" > "$d/brightness" || true
	fi
done

nohup sh -c "tail -f /dev/null | modetest -s ${CONNECTOR}@${CRTC}:${MODE} -F ${PATTERN}" \
	>/tmp/hotdog-modetest-held.log 2>&1 &
echo "$!" >/tmp/hotdog-modetest-held.pid
sleep 2

for d in /sys/class/backlight/*; do
	[ -w "$d/bl_power" ] && echo 0 > "$d/bl_power" || true
	if [ -r "$d/max_brightness" ] && [ -w "$d/brightness" ]; then
		cat "$d/max_brightness" > "$d/brightness" || true
	fi
done

echo "wrapper_pid=$(cat /tmp/hotdog-modetest-held.pid)"
pgrep -a modetest || true
cat /tmp/hotdog-modetest-held.log 2>/dev/null || true
REMOTE
}

remote_status() {
	date
	cat /proc/sys/kernel/random/boot_id
	uname -a
	pgrep -a modetest || true
	cat /tmp/hotdog-modetest-held.log 2>/dev/null || true
	printf '\nDRM connectors\n'
	modetest 2>&1 | sed -n '1,180p' || true
	printf '\nDRM planes\n'
	modetest -p 2>&1 | sed -n '1,220p' || true
	printf '\nbacklight\n'
	for d in /sys/class/backlight/*; do
		echo "$d"
		for f in brightness actual_brightness max_brightness bl_power; do
			[ -r "$d/$f" ] && printf '%s=' "$f" && cat "$d/$f"
		done
	done
}

collect_status() {
	local stamp out
	stamp="$(date +%Y%m%d-%H%M%S)"
	out="$HOTDOG_LOG_ROOT/live-drm-visible-$stamp"
	mkdir -p "$out"
	ssh_base "$(declare -f remote_status); remote_status" > "$out/state.txt" 2>&1
	printf '%s\n' "$out"
}

mode="${1:-start}"
case "$mode" in
	-h|--help)
		usage
		;;
	start)
		ssh_base "$(declare -f remote_start); remote_start '$CONNECTOR' '$CRTC' '$MODE' '$PATTERN'"
		;;
	stop)
		ssh_base "$(declare -f remote_stop); remote_stop"
		;;
	status)
		ssh_base "$(declare -f remote_status); remote_status"
		;;
	collect)
		collect_status
		;;
	*)
		die "unknown mode: $mode"
		;;
esac
