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
DURATION_SEC="${DURATION_SEC:-900}"
INTERVAL_SEC="${INTERVAL_SEC:-1}"
TRANSITION_GRACE_SEC="${TRANSITION_GRACE_SEC:-20}"
stamp="$(date +%F-%H%M%S)"
OUT="${OUT:-$HOTDOG_LOG_ROOT/mainline616-runtime-$stamp}"
REMOTE_SUDO_MODE=""
REMOTE_MONITOR_PID=""

usage() {
	cat <<'USAGE'
Usage: monitor-mainline616-runtime.sh [options]

Record a low-rate mainline runtime heartbeat in ramoops pmsg while the host
watches USB state. If Qualcomm 05c6:900e appears, capture the bounded 4 MiB
ramoops reservation read-only. This script never flashes or resets the phone.

Options:
  --host HOST           SSH host. Default: 172.16.42.1.
  --user USER           SSH user. Default: user.
  --password PASS       SSH and sudo password. Defaults to PMOS_PASSWORD.
  --duration SEC        Maximum observation duration. Default: 900.
  --interval SEC        Seconds between pmsg records. Default: 1.
  --transition-grace SEC
                        USB classification time after SSH exits. Default: 20.
  --kernel-marker TEXT  Required substring in uname -a.
  --serial SERIAL       Required androidboot.serialno value.
  --out DIR             Output directory.
  -h, --help            Show this help.
USAGE
}

log() {
	printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

die() {
	log "ERROR: $1"
	exit "${2:-1}"
}

positive_integer() {
	local name="$1"
	local value="$2"

	[[ "$value" =~ ^[1-9][0-9]*$ ]] || die "$name must be a positive integer: $value" 2
}

cleanup() {
	if [ -n "$REMOTE_MONITOR_PID" ] && kill -0 "$REMOTE_MONITOR_PID" 2>/dev/null; then
		kill "$REMOTE_MONITOR_PID" 2>/dev/null || true
		wait "$REMOTE_MONITOR_PID" 2>/dev/null || true
	fi
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

detect_remote_sudo_mode() {
	if ssh_base 'sudo -n true' >/dev/null 2>&1; then
		REMOTE_SUDO_MODE=noninteractive
	elif printf '%s\n' "$PMOS_PASSWORD" |
		ssh_base "sudo -S -p '' true" >/dev/null 2>&1; then
		REMOTE_SUDO_MODE=password
	else
		die "remote sudo authentication failed" 3
	fi
	log "Remote sudo mode: $REMOTE_SUDO_MODE"
}

remote_program() {
	cat <<'REMOTE'
set -eu

duration_sec="$1"
interval_sec="$2"
pmsg=/dev/pmsg0
ufs=/sys/bus/platform/devices/1d84000.ufshc
battery=/sys/class/power_supply/qcom-battery
charger=/sys/class/power_supply/pm8150b-charger

[ -c "$pmsg" ] || {
	echo "ERROR: missing $pmsg" >&2
	exit 20
}

read_one_line() {
	path="$1"
	if [ -r "$path" ]; then
		tr '[:space:]' '_' < "$path" | sed 's/_*$//'
	else
		printf unavailable
	fi
}

device_flag() {
	[ -e "$1" ] && printf 1 || printf 0
}

udc_state() {
	for udc in /sys/class/udc/*; do
		[ -e "$udc" ] || continue
		printf '%s:%s' "${udc##*/}" "$(read_one_line "$udc/state")"
		return
	done
	printf absent
}

sample_count=$((duration_sec / interval_sec + 1))
sample=1
while [ "$sample" -le "$sample_count" ]; do
	line="HOTDOG_RUNTIME_V1"
	line="$line seq=$sample/$sample_count"
	line="$line uptime=$(cut -d' ' -f1 /proc/uptime)"
	line="$line ufs_runtime=$(read_one_line "$ufs/power/runtime_status")"
	line="$line ufs_control=$(read_one_line "$ufs/power/control")"
	line="$line sda=$(device_flag /dev/sda)"
	line="$line root_loop=$(device_flag /dev/loop0p2)"
	line="$line udc=$(udc_state)"
	line="$line charger_status=$(read_one_line "$charger/status")"
	line="$line charger_online=$(read_one_line "$charger/online")"
	line="$line charger_current=$(read_one_line "$charger/current_now")"
	line="$line charger_limit=$(read_one_line "$charger/current_max")"
	line="$line battery_status=$(read_one_line "$battery/status")"
	line="$line battery_voltage=$(read_one_line "$battery/voltage_now")"
	line="$line battery_current=$(read_one_line "$battery/current_now")"

	printf '<6>%s\n' "$line" > "$pmsg"
	printf '%s\n' "$line"

	[ "$sample" -eq "$sample_count" ] || sleep "$interval_sec"
	sample=$((sample + 1))
done
REMOTE
}

run_remote_monitor() {
	case "$REMOTE_SUDO_MODE" in
		noninteractive)
			remote_program |
				ssh_base "sudo -n sh -s -- '$DURATION_SEC' '$INTERVAL_SEC'"
			;;
		password)
			{
				printf '%s\n' "$PMOS_PASSWORD"
				remote_program
			} | ssh_base "sudo -S -p '' sh -s -- '$DURATION_SEC' '$INTERVAL_SEC'"
			;;
		*)
			die "remote sudo mode was not initialized" 3
			;;
	esac
}

usb_state() {
	if lsusb -d 05c6:900e 2>/dev/null | grep -q .; then
		printf qualcomm-900e
	elif hotdog_fastboot_usb_visible; then
		printf fastboot
	else
		printf other
	fi
}

capture_900e() {
	local capture_status=0

	phone_lock_release
	log "Qualcomm 900e detected; extracting bounded ramoops without reset"
	set +e
	"$HOTDOG_ROOT/scripts/qualcomm-900e-autorescue.sh" inspect --extract-ramoops
	capture_status=$?
	set -e
	printf 'result=qualcomm-900e capture_status=%s\n' "$capture_status" |
		tee "$OUT/result.txt"
	return "$capture_status"
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--host)
			[ "$#" -ge 2 ] || die "missing value for --host" 2
			PMOS_HOST="$2"
			shift
			;;
		--user)
			[ "$#" -ge 2 ] || die "missing value for --user" 2
			PMOS_USER="$2"
			shift
			;;
		--password)
			[ "$#" -ge 2 ] || die "missing value for --password" 2
			PMOS_PASSWORD="$2"
			shift
			;;
		--duration)
			[ "$#" -ge 2 ] || die "missing value for --duration" 2
			DURATION_SEC="$2"
			shift
			;;
		--interval)
			[ "$#" -ge 2 ] || die "missing value for --interval" 2
			INTERVAL_SEC="$2"
			shift
			;;
		--transition-grace)
			[ "$#" -ge 2 ] || die "missing value for --transition-grace" 2
			TRANSITION_GRACE_SEC="$2"
			shift
			;;
		--kernel-marker)
			[ "$#" -ge 2 ] || die "missing value for --kernel-marker" 2
			EXPECTED_KERNEL_MARKER="$2"
			shift
			;;
		--serial)
			[ "$#" -ge 2 ] || die "missing value for --serial" 2
			TARGET_SERIAL="$2"
			shift
			;;
		--out)
			[ "$#" -ge 2 ] || die "missing value for --out" 2
			OUT="$2"
			shift
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			die "unknown argument: $1" 2
			;;
	esac
	shift
done

positive_integer DURATION_SEC "$DURATION_SEC"
positive_integer INTERVAL_SEC "$INTERVAL_SEC"
positive_integer TRANSITION_GRACE_SEC "$TRANSITION_GRACE_SEC"
[ -n "$PMOS_PASSWORD" ] || die "set PMOS_PASSWORD or use --password" 2
[ -n "$TARGET_SERIAL" ] || die "set ANDROID_SERIAL or HOTDOG_TARGET_SERIAL" 2
[ -n "$EXPECTED_KERNEL_MARKER" ] || die "kernel marker must not be empty" 2
for command_name in grep lsusb ping ssh sshpass tee; do
	command -v "$command_name" >/dev/null 2>&1 || die "missing command: $command_name" 127
done

mkdir -p "$OUT"
exec > >(tee "$OUT/run.log") 2>&1
log "Run directory: $OUT"
log "Observation: ${DURATION_SEC}s at ${INTERVAL_SEC}s intervals"
log "Reset policy: never"
phone_lock_acquire "mainline616 persistent runtime monitor" 0 ||
	die "could not acquire phone-operation lock" 4

uname_output="$(ssh_base 'uname -a')" || die "SSH or uname failed" 5
cmdline="$(ssh_base 'cat /proc/cmdline')" || die "could not read /proc/cmdline" 5
boot_id="$(ssh_base 'cat /proc/sys/kernel/random/boot_id')" || die "could not read boot_id" 5
printf '%s\n' "$uname_output" | tee "$OUT/uname.txt"
printf '%s\n' "$cmdline" > "$OUT/cmdline.txt"
printf '%s\n' "$boot_id" > "$OUT/boot-id.txt"

[[ "$uname_output" == *"$EXPECTED_KERNEL_MARKER"* ]] ||
	die "running kernel does not contain marker: $EXPECTED_KERNEL_MARKER" 6
[[ "$cmdline" == *"androidboot.serialno=$TARGET_SERIAL"* ]] ||
	die "running target serial does not match the configured serial" 6

detect_remote_sudo_mode
run_remote_monitor \
	> >(tee "$OUT/remote-heartbeat.txt") \
	2> >(tee "$OUT/remote-heartbeat.stderr" >&2) &
REMOTE_MONITOR_PID=$!
log "Remote pmsg monitor PID: $REMOTE_MONITOR_PID"

transition=none
while kill -0 "$REMOTE_MONITOR_PID" 2>/dev/null; do
	transition="$(usb_state)"
	case "$transition" in
		qualcomm-900e|fastboot)
			log "USB transition detected: $transition"
			break
			;;
	esac
	sleep 1
done

if kill -0 "$REMOTE_MONITOR_PID" 2>/dev/null; then
	kill "$REMOTE_MONITOR_PID" 2>/dev/null || true
fi
set +e
wait "$REMOTE_MONITOR_PID"
remote_status=$?
set -e
REMOTE_MONITOR_PID=""

if [ "$transition" = none ] || [ "$transition" = other ]; then
	deadline=$((SECONDS + TRANSITION_GRACE_SEC))
	while [ "$SECONDS" -lt "$deadline" ]; do
		transition="$(usb_state)"
		case "$transition" in
			qualcomm-900e|fastboot)
				log "USB transition detected during grace period: $transition"
				break
				;;
		esac
		sleep 1
	done
fi

case "$transition" in
	qualcomm-900e)
	capture_900e || true
	exit 10
	;;
	fastboot)
	printf 'result=fastboot remote_status=%s\n' "$remote_status" |
		tee "$OUT/result.txt"
	exit 11
	;;
esac

if [ "$remote_status" -eq 0 ]; then
	printf 'result=duration-complete remote_status=0\n' | tee "$OUT/result.txt"
	log "Runtime observation completed without a USB transition"
	exit 0
fi

printf 'result=ssh-ended-unclassified remote_status=%s usb_state=%s\n' \
	"$remote_status" "$transition" | tee "$OUT/result.txt"
die "remote monitor ended without a classified USB transition" 12
