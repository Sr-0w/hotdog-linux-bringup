#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/env.sh"

PMOS_HOST="${PMOS_HOST:-172.16.42.1}"
PMOS_USER="${PMOS_USER:-user}"
PMOS_PASSWORD="${PMOS_PASSWORD:-$HOTDOG_PMOS_PASSWORD}"
REMOTE_SRC="/tmp/hotdog-drm-console.c"
REMOTE_BIN="/usr/local/bin/hotdog-drm-console"
REMOTE_FONT="/tmp/hotdog-ter-v32n.psf"
REMOTE_FIFO="/tmp/hotdog-drm-console.in"
REMOTE_TRANSCRIPT="/tmp/hotdog-drm-console.transcript"

usage() {
	cat <<'USAGE'
Usage: install-hotdog-drm-console.sh [install|start|stop|status|transcript [LINES]|send COMMAND|enable-boot|disable-boot]

Build and run a small DRM text console on an already booted stable pmOS system.
It uses SSH only. It does not use adb, fastboot, block devices, or flashing.

Modes:
  install       Install packages, copy source, compile helper, prepare font.
  start         Stop other KMS clients and start the DRM console.
  stop          Stop the DRM console.
  status        Print process/log/DRM status.
  transcript    Print the visible shell transcript, defaulting to the last 120 lines.
  send COMMAND  Send COMMAND plus newline to the visible shell FIFO.
  enable-boot   Install an OpenRC local.d hook to start the console at boot.
  disable-boot  Remove the OpenRC local.d hook.
USAGE
}

ssh_base() {
	sshpass -p "$PMOS_PASSWORD" ssh \
		-o StrictHostKeyChecking=no \
		-o UserKnownHostsFile=/dev/null \
		-o ConnectTimeout=8 \
		-o ServerAliveInterval=10 \
		"$PMOS_USER@$PMOS_HOST" "$@"
}

scp_base() {
	sshpass -p "$PMOS_PASSWORD" scp \
		-o StrictHostKeyChecking=no \
		-o UserKnownHostsFile=/dev/null \
		-o ConnectTimeout=8 \
		"$@"
}

remote_install() {
	sudo -n sh -s <<REMOTE
set -eux
REMOTE_SRC="$REMOTE_SRC"
REMOTE_BIN="$REMOTE_BIN"
REMOTE_FONT="$REMOTE_FONT"
apk add --no-cache build-base libdrm-dev pkgconf font-terminus gzip
cc -O2 -Wall -Wextra -o "$REMOTE_BIN" "$REMOTE_SRC" \$(pkg-config --cflags --libs libdrm)
gzip -dc /usr/share/consolefonts/ter-v32n.psf.gz > "$REMOTE_FONT"
chmod 0755 "$REMOTE_BIN"
ls -l "$REMOTE_BIN" "$REMOTE_FONT"
REMOTE
}

remote_stop() {
	sudo -n sh -s <<'REMOTE'
set -eu
if [ -r /tmp/hotdog-drm-console.pid ]; then
	pid="$(cat /tmp/hotdog-drm-console.pid)"
	kill "$pid" 2>/dev/null || true
	sleep 1
	[ ! -d "/proc/$pid" ] || kill -KILL "$pid" 2>/dev/null || true
	rm -f /tmp/hotdog-drm-console.pid
fi
pidof hotdog-drm-console 2>/dev/null | tr ' ' '\n' | while read -r p; do
	[ -n "$p" ] && kill -KILL "$p" 2>/dev/null || true
done
REMOTE
}

remote_start() {
sudo -n sh -s <<REMOTE
set -eux
REMOTE_BIN="$REMOTE_BIN"
REMOTE_FONT="$REMOTE_FONT"
REMOTE_FIFO="$REMOTE_FIFO"
REMOTE_TRANSCRIPT="$REMOTE_TRANSCRIPT"
if [ -r /tmp/hotdog-drm-console.pid ]; then
	old_pid="\$(cat /tmp/hotdog-drm-console.pid)"
	kill "\$old_pid" 2>/dev/null || true
	sleep 1
	[ ! -d "/proc/\$old_pid" ] || kill -KILL "\$old_pid" 2>/dev/null || true
	rm -f /tmp/hotdog-drm-console.pid
fi
pidof hotdog-drm-console 2>/dev/null | tr ' ' '\n' | while read -r p; do
	[ -n "\$p" ] && kill -KILL "\$p" 2>/dev/null || true
done
pgrep -x kmscon | while read -r p; do kill "\$p" 2>/dev/null || true; done
pgrep -x weston | while read -r p; do kill "\$p" 2>/dev/null || true; done
pgrep -x foot | while read -r p; do kill "\$p" 2>/dev/null || true; done
pgrep -x modetest | while read -r p; do kill "\$p" 2>/dev/null || true; done
pkill plymouthd 2>/dev/null || true

for d in /sys/class/backlight/*; do
	[ -w "\$d/bl_power" ] && echo 0 > "\$d/bl_power" || true
	if [ -r "\$d/max_brightness" ] && [ -w "\$d/brightness" ]; then
		cat "\$d/max_brightness" > "\$d/brightness" || true
	fi
done

nohup "\$REMOTE_BIN" --font "\$REMOTE_FONT" --fifo "\$REMOTE_FIFO" \\
	--transcript "\$REMOTE_TRANSCRIPT" \\
	>/tmp/hotdog-drm-console.log 2>&1 &
echo \$! >/tmp/hotdog-drm-console.pid
sleep 3
cat /tmp/hotdog-drm-console.pid
pid="\$(cat /tmp/hotdog-drm-console.pid)"
if [ -d "/proc/\$pid" ]; then
	tr '\0' ' ' <"/proc/\$pid/cmdline" 2>/dev/null || true
	echo
fi
cat /tmp/hotdog-drm-console.log || true
REMOTE
}

remote_status() {
	set -x
	if [ -r /tmp/hotdog-drm-console.pid ]; then
		pid="$(cat /tmp/hotdog-drm-console.pid)"
		echo "pid=$pid"
		if [ -d "/proc/$pid" ]; then
			tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null || true
			echo
		else
			echo "pid is not running"
		fi
	fi
	cat /tmp/hotdog-drm-console.log 2>/dev/null || true
	tail -80 /tmp/hotdog-drm-console.transcript 2>/dev/null || true
	ls -l /tmp/hotdog-drm-console.in /usr/local/bin/hotdog-drm-console /tmp/hotdog-ter-v32n.psf 2>/dev/null || true
	modetest -p 2>&1 | sed -n '1,100p' || true
}

remote_transcript() {
	lines="${1:-120}"
	case "$lines" in
		''|*[!0-9]*)
			lines=120
			;;
	esac
	sudo -n tail -n "$lines" /tmp/hotdog-drm-console.transcript 2>/dev/null ||
		tail -n "$lines" /tmp/hotdog-drm-console.transcript 2>/dev/null ||
		true
}

remote_enable_boot() {
	sudo -n sh -s <<'REMOTE'
set -eux
mkdir -p /etc/local.d
cat >/etc/local.d/hotdog-drm-console.start <<'EOF'
#!/bin/sh
set -eu

bin=/usr/local/bin/hotdog-drm-console
font=/tmp/hotdog-ter-v32n.psf
fifo=/tmp/hotdog-drm-console.in
transcript=/tmp/hotdog-drm-console.transcript

[ -x "$bin" ] || exit 0

gzip -dc /usr/share/consolefonts/ter-v32n.psf.gz > "$font" 2>/dev/null || exit 0

if [ -r /tmp/hotdog-drm-console.pid ]; then
	pid="$(cat /tmp/hotdog-drm-console.pid)"
	kill "$pid" 2>/dev/null || true
	sleep 1
	[ ! -d "/proc/$pid" ] || kill -KILL "$pid" 2>/dev/null || true
	rm -f /tmp/hotdog-drm-console.pid
fi
pidof hotdog-drm-console 2>/dev/null | tr ' ' '\n' | while read -r p; do
	[ -n "$p" ] && kill -KILL "$p" 2>/dev/null || true
done
pgrep -x modetest | while read -r p; do kill "$p" 2>/dev/null || true; done
pkill plymouthd 2>/dev/null || true

for d in /sys/class/backlight/*; do
	[ -w "$d/bl_power" ] && echo 0 > "$d/bl_power" || true
	if [ -r "$d/max_brightness" ] && [ -w "$d/brightness" ]; then
		cat "$d/max_brightness" > "$d/brightness" || true
	fi
done

nohup "$bin" --font "$font" --fifo "$fifo" --transcript "$transcript" >/tmp/hotdog-drm-console.log 2>&1 &
echo $! >/tmp/hotdog-drm-console.pid
EOF
chmod 0755 /etc/local.d/hotdog-drm-console.start
rc-update add local default 2>/dev/null || true
ls -l /etc/local.d/hotdog-drm-console.start
rc-update show default 2>/dev/null | grep -E '(^| )local($| )' || true
REMOTE
}

remote_disable_boot() {
	sudo -n sh -s <<'REMOTE'
set -eux
rm -f /etc/local.d/hotdog-drm-console.start
REMOTE
}

mode="${1:-install}"
case "$mode" in
	-h|--help)
		usage
		;;
	install)
		scp_base "$HOTDOG_ROOT/helpers/hotdog-drm-console.c" "$PMOS_USER@$PMOS_HOST:$REMOTE_SRC"
		ssh_base "REMOTE_SRC='$REMOTE_SRC' REMOTE_BIN='$REMOTE_BIN' REMOTE_FONT='$REMOTE_FONT'; $(declare -f remote_install); remote_install"
		;;
	start)
		ssh_base "REMOTE_BIN='$REMOTE_BIN' REMOTE_FONT='$REMOTE_FONT' REMOTE_FIFO='$REMOTE_FIFO' REMOTE_TRANSCRIPT='$REMOTE_TRANSCRIPT'; $(declare -f remote_start); remote_start"
		;;
	stop)
		ssh_base "$(declare -f remote_stop); remote_stop"
		;;
	status)
		ssh_base "$(declare -f remote_status); remote_status"
		;;
	transcript)
		shift
		lines="${1:-120}"
		case "$lines" in
			''|*[!0-9]*)
				echo "invalid line count: $lines" >&2
				exit 2
				;;
		esac
		ssh_base "$(declare -f remote_transcript); remote_transcript '$lines'"
		;;
	send)
		shift
		[ "$#" -gt 0 ] || { echo "missing command" >&2; exit 2; }
		printf '%s\n' "$*" | ssh_base "sudo -n tee '$REMOTE_FIFO' >/dev/null"
		;;
	enable-boot)
		ssh_base "$(declare -f remote_enable_boot); remote_enable_boot"
		;;
	disable-boot)
		ssh_base "$(declare -f remote_disable_boot); remote_disable_boot"
		;;
	*)
		echo "unknown mode: $mode" >&2
		usage >&2
		exit 2
		;;
esac
