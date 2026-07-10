#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/env.sh"

SERIAL="${ANDROID_SERIAL:-b6bd2252}"
TIMEOUT_SEC="${TIMEOUT_SEC:-600}"
POLL_SEC="${POLL_SEC:-2}"
AFTER_FASTBOOT_RESTORE="${AFTER_FASTBOOT_RESTORE:-system}"
EDL_WRITE=0
FASTBOOT_RESTORE_SCRIPT="${FASTBOOT_RESTORE_SCRIPT:-$HOTDOG_ROOT/scripts/restore-pmos-boot-b-from-fastboot.sh}"
EDL_RESTORE_SCRIPT="${EDL_RESTORE_SCRIPT:-$HOTDOG_ROOT/scripts/restore-boot-b-from-edl-firehose.sh}"
QDL_BIN="${QDL_BIN:-$HOTDOG_ROOT/tools/qdl-install/bin/qdl}"
LABEL="${LABEL:-usb-visible}"
ALLOW_DUPLICATE="${ALLOW_DUPLICATE:-0}"
USB_RESCUE_RUNNING_PID=""

usage() {
	cat <<'EOF'
Usage: rescue-boot-b-when-usb-visible.sh [options]

Watch USB until the phone appears, then restore the known-good pmOS boot_b
through the safest available path.

Actions:
  - fastboot serial match: restore boot_b and reboot according to --after-fastboot
  - Qualcomm 05c6:9008: validate EDL Firehose; write only with --edl-write
  - Qualcomm 05c6:900e: do not flash; optionally collect a tiny ramdump

Options:
  --serial SERIAL         Target fastboot serial. Default: b6bd2252.
  --timeout SEC           Total wait timeout. Default: 600.
  --poll SEC              Poll interval. Default: 2.
  --after-fastboot MODE   system, bootloader, or none. Default: system.
  --edl-write             If 9008 appears and validation passes, write boot_b.
  --no-edl-write          Validate only on 9008. Default.
  --label NAME            Instance label. Default: usb-visible.
  --allow-duplicate       Allow another USB rescue watcher for same serial/label.
  -h, --help              Show this help.
EOF
}

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

log() {
	printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--serial)
			[ "$#" -ge 2 ] || die "--serial requires a value"
			SERIAL="$2"
			shift
			;;
		--timeout)
			[ "$#" -ge 2 ] || die "--timeout requires a value"
			TIMEOUT_SEC="$2"
			shift
			;;
		--poll)
			[ "$#" -ge 2 ] || die "--poll requires a value"
			POLL_SEC="$2"
			shift
			;;
		--after-fastboot)
			[ "$#" -ge 2 ] || die "--after-fastboot requires a value"
			AFTER_FASTBOOT_RESTORE="$2"
			shift
			;;
		--edl-write)
			EDL_WRITE=1
			;;
		--no-edl-write)
			EDL_WRITE=0
			;;
		--label)
			[ "$#" -ge 2 ] || die "--label requires a value"
			LABEL="$2"
			shift
			;;
		--allow-duplicate)
			ALLOW_DUPLICATE=1
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

case "$AFTER_FASTBOOT_RESTORE" in
	system|bootloader|none)
		;;
	*)
		die "--after-fastboot must be one of: system, bootloader, none"
		;;
esac
[[ "$TIMEOUT_SEC" =~ ^[0-9]+$ ]] || die "--timeout must be numeric: $TIMEOUT_SEC"
[[ "$POLL_SEC" =~ ^[0-9]+$ ]] || die "--poll must be numeric: $POLL_SEC"
[ "$POLL_SEC" -ge 1 ] || die "--poll must be >= 1"
[ -x "$FASTBOOT_RESTORE_SCRIPT" ] || die "missing fastboot restore script: $FASTBOOT_RESTORE_SCRIPT"
[ -x "$EDL_RESTORE_SCRIPT" ] || die "missing EDL restore script: $EDL_RESTORE_SCRIPT"
command -v fastboot >/dev/null 2>&1 || die "missing fastboot"
command -v lsusb >/dev/null 2>&1 || die "missing lsusb"

safe_name() {
	printf '%s' "$1" | tr -c 'A-Za-z0-9_.:-' '_'
}

args_has_option_value() {
	local args_text=" $1 "
	local opt="$2"
	local value="$3"

	printf '%s\n' "$args_text" | grep -F -- " $opt $value " >/dev/null 2>&1 ||
		printf '%s\n' "$args_text" | grep -F -- " $opt=$value " >/dev/null 2>&1
}

usb_rescue_running() {
	local pid
	local args
	local comm
	local pids_file="$run_dir/usb-rescue-pids.txt"

	USB_RESCUE_RUNNING_PID=""
	pgrep -f "$HOTDOG_ROOT/scripts/rescue-boot-b-when-usb-visible.sh" > "$pids_file" 2>/dev/null || true
	while read -r pid; do
		[ -n "$pid" ] || continue
		[ "$pid" != "$$" ] || continue
		args="$(ps -o args= -p "$pid" 2>/dev/null || true)"
		comm="$(ps -o comm= -p "$pid" 2>/dev/null || true)"
		case "$comm:$args" in
			bash:"$HOTDOG_ROOT/scripts/rescue-boot-b-when-usb-visible.sh"*|bash:"bash $HOTDOG_ROOT/scripts/rescue-boot-b-when-usb-visible.sh"*|rescue-boot-b-when-usb-visible.sh:*)
				;;
			*)
				continue
				;;
		esac
		if args_has_option_value "$args" "--serial" "$SERIAL" &&
			args_has_option_value "$args" "--label" "$LABEL"; then
			USB_RESCUE_RUNNING_PID="$pid"
			return 0
		fi
	done < "$pids_file"

	return 1
}

acquire_instance_lock() {
	local owner=""

	while true; do
		if mkdir "$instance_lock" 2>/dev/null; then
			printf '%s\n' "$$" > "$instance_lock/pid"
			return 0
		fi

		owner="$(sed -n '1p' "$instance_lock/pid" 2>/dev/null || true)"
		if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
			printf 'USB rescue watcher instance lock is busy by PID %s: %s\n' "$owner" "$instance_lock" >&2
			return 1
		fi

		rm -rf "$instance_lock"
	done
}

stamp="$(date +%F-%H%M%S)"
run_dir="$HOTDOG_LOG_ROOT/rescue-boot-b-when-usb-visible-$stamp"
mkdir -p "$run_dir"
exec > >(tee "$run_dir/run.log") 2>&1

safe_serial="$(safe_name "$SERIAL")"
safe_label="$(safe_name "$LABEL")"
instance_lock="$HOTDOG_LOG_ROOT/manual-rescue-watchers/usb-rescue-${safe_serial}-${safe_label}.lock"
mkdir -p "$HOTDOG_LOG_ROOT/manual-rescue-watchers"
if [ "$ALLOW_DUPLICATE" -ne 1 ]; then
	if usb_rescue_running; then
		log "USB rescue watcher already running for $SERIAL/$LABEL: PID $USB_RESCUE_RUNNING_PID"
		exit 0
	fi
fi
if ! acquire_instance_lock; then
	exit 0
fi
trap 'rm -rf "$instance_lock"' EXIT

log "Run directory: $run_dir"
log "Target serial: $SERIAL"
log "Timeout: ${TIMEOUT_SEC}s"
log "EDL write: $EDL_WRITE"
log "Label: $LABEL"

deadline=$((SECONDS + TIMEOUT_SEC))
last_state=""

while [ "$SECONDS" -lt "$deadline" ]; do
	lsusb > "$run_dir/lsusb-last.txt" 2>&1 || true
	fastboot devices -l > "$run_dir/fastboot-last.txt" 2>&1 || true

	state="none"
	if grep -q "^${SERIAL}[[:space:]]" "$run_dir/fastboot-last.txt"; then
		state="fastboot"
	elif grep -qi '05c6:9008' "$run_dir/lsusb-last.txt"; then
		state="qualcomm-9008"
	elif grep -qi '05c6:900e' "$run_dir/lsusb-last.txt"; then
		state="qualcomm-900e"
	elif grep -Eqi '18d1|2a70|2717|Google|OnePlus|Qualcomm' "$run_dir/lsusb-last.txt"; then
		state="usb-other"
	fi

	if [ "$state" != "$last_state" ]; then
		log "state=$state"
		cp "$run_dir/lsusb-last.txt" "$run_dir/lsusb-${state}-$(date +%H%M%S).txt" 2>/dev/null || true
		cp "$run_dir/fastboot-last.txt" "$run_dir/fastboot-${state}-$(date +%H%M%S).txt" 2>/dev/null || true
		last_state="$state"
	fi

	case "$state" in
		fastboot)
			log "fastboot visible; restoring pmOS boot_b"
			set +e
			"$FASTBOOT_RESTORE_SCRIPT" \
				--serial "$SERIAL" \
				--after-restore "$AFTER_FASTBOOT_RESTORE" \
				2>&1 | tee "$run_dir/restore-fastboot.log"
			rc="${PIPESTATUS[0]}"
			set -e
			if [ "$rc" -eq 75 ]; then
				log "Fastboot restore lock busy; leaving target untouched and retrying"
				sleep "$POLL_SEC"
				continue
			fi
			exit "$rc"
			;;
		qualcomm-9008)
			log "EDL 9008 visible; validating Firehose path"
			"$EDL_RESTORE_SCRIPT" --validate-only 2>&1 | tee "$run_dir/edl-validate.log"
			rc="${PIPESTATUS[0]}"
			[ "$rc" -eq 0 ] || exit "$rc"
			if [ "$EDL_WRITE" -eq 1 ]; then
				log "EDL validation passed; writing restore image"
				"$EDL_RESTORE_SCRIPT" --write 2>&1 | tee "$run_dir/edl-write.log"
				exit "${PIPESTATUS[0]}"
			fi
			log "EDL validation passed; no write requested"
			exit 0
			;;
		qualcomm-900e)
			log "crashdump 900e visible; not flashing from this mode"
			;;
	esac

	sleep "$POLL_SEC"
done

log "timeout waiting for recoverable USB state"
printf 'Run directory: %s\n' "$run_dir"
exit 124
