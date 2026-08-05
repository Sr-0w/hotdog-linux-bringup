#!/usr/bin/env bash
set -Eeuo pipefail

# The remote-program helpers are passed by name through run_root_program.

# shellcheck source=/dev/null
source "$(dirname "$0")/env.sh"
# shellcheck source=/dev/null
source "$(dirname "$0")/phone-lock.sh"

PMOS_HOST="${PMOS_HOST:-$HOTDOG_PMOS_HOST}"
PMOS_USER="${PMOS_USER:-$HOTDOG_PMOS_USER}"
PMOS_PASSWORD="${PMOS_PASSWORD:-$HOTDOG_PMOS_PASSWORD}"
EXPECTED_KERNEL_MARKER="${EXPECTED_KERNEL_MARKER:-oneplus-hotdog-mainline616}"
APP_ID="${APP_ID:-com.play0ad.zeroad}"
MAX_SECTORS_KB="${MAX_SECTORS_KB:-}"
PHASE="${1:-}"
stamp="$(date +%F-%H%M%S)"
OUT="${OUT:-$HOTDOG_LOG_ROOT/flatpak-ufs-${PHASE:-unknown}-$stamp}"
REMOTE_PIDS=()

usage() {
	cat <<'USAGE'
Usage: test-flatpak-ufs-finalization.sh pull|deploy

Separate Flatpak's storage-heavy installation into two observable phases:
  pull    Download and import objects, but do not deploy the application.
  deploy  Deploy only objects already present in the local Flatpak repository.

The test keeps UFS runtime power active, streams kernel messages, syscall
metadata, and high-rate storage state to the host, and performs a read-only
Sahara region-table listing plus bounded ramoops and firmware KMSG captures if
Qualcomm 05c6:900e appears. It never resets or flashes the phone.

Environment:
  APP_ID                  Flatpak application ID (default: com.play0ad.zeroad)
  OUT                     Host output directory
  EXPECTED_KERNEL_MARKER  Required substring in uname -a
  MAX_SECTORS_KB          Optional temporary /sys/block/sda queue limit
USAGE
}

log() {
	printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

die() {
	log "ERROR: $1"
	exit "${2:-1}"
}

stop_remote_streams() {
	local pid=""

	for pid in "${REMOTE_PIDS[@]:-}"; do
		[ -n "$pid" ] || continue
		if kill -0 "$pid" 2>/dev/null; then
			kill "$pid" 2>/dev/null || true
		fi
	done
	for pid in "${REMOTE_PIDS[@]:-}"; do
		[ -n "$pid" ] || continue
		wait "$pid" 2>/dev/null || true
	done
	REMOTE_PIDS=()
}

# shellcheck disable=SC2329
cleanup() {
	stop_remote_streams
	phone_lock_release || true
}
trap cleanup EXIT INT TERM

ssh_base() {
	sshpass -p "$PMOS_PASSWORD" ssh \
		-o StrictHostKeyChecking=no \
		-o UserKnownHostsFile="$OUT/known_hosts" \
		-o ConnectTimeout=5 \
		-o ServerAliveInterval=1 \
		-o ServerAliveCountMax=2 \
		-o PreferredAuthentications=password \
		-o PubkeyAuthentication=no \
		"$PMOS_USER@$PMOS_HOST" "$@"
}

run_root_program() {
	local remote_command="$1"
	shift
	{
		printf '%s\n' "$PMOS_PASSWORD"
		"$@"
	} | ssh_base "sudo -S -p '' $remote_command"
}

# shellcheck disable=SC2329
setup_program() {
	cat <<'REMOTE'
set -eu
max_sectors_kb="$1"
ufs=/sys/bus/platform/devices/1d84000.ufshc
queue=/sys/block/sda/queue
[ -d "$ufs" ] || { echo "missing UFS host: $ufs" >&2; exit 20; }
[ -d "$queue" ] || { echo "missing UFS queue: $queue" >&2; exit 22; }
[ -c /dev/pmsg0 ] || { echo 'missing /dev/pmsg0' >&2; exit 21; }
command -v flatpak >/dev/null
command -v strace >/dev/null
echo on > "$ufs/power/control"
printf 'ufs_control=%s\n' "$(cat "$ufs/power/control")"
printf 'ufs_runtime=%s\n' "$(cat "$ufs/power/runtime_status")"
for attribute in max_sectors_kb max_hw_sectors_kb max_segments max_segment_size nr_requests scheduler; do
	if [ -r "$queue/$attribute" ]; then
		printf 'queue_%s_before=%s\n' "$attribute" "$(cat "$queue/$attribute")"
	fi
done
if [ -n "$max_sectors_kb" ]; then
	[ -w "$queue/max_sectors_kb" ] || {
		echo "UFS queue max_sectors_kb is not writable" >&2
		exit 23
	}
	printf '%s\n' "$max_sectors_kb" > "$queue/max_sectors_kb"
fi
effective_max_sectors_kb="$(cat "$queue/max_sectors_kb")"
printf 'queue_max_sectors_kb_after=%s\n' "$effective_max_sectors_kb"
printf '<6>HOTDOG_FLATPAK_TEST phase=prepared ufs_control=%s max_sectors_kb=%s uptime=%s\n' \
	"$(cat "$ufs/power/control")" "$effective_max_sectors_kb" \
	"$(cut -d' ' -f1 /proc/uptime)" > /dev/pmsg0
REMOTE
}

# shellcheck disable=SC2329
dmesg_program() {
	cat <<'REMOTE'
set -eu
dmesg -w
REMOTE
}

# shellcheck disable=SC2329
sampler_program() {
	cat <<'REMOTE'
set -eu
phase="$1"
ufs=/sys/bus/platform/devices/1d84000.ufshc
sample=0
while :; do
	sample=$((sample + 1))
	uptime_now="$(cut -d' ' -f1 /proc/uptime)"
	ufs_control="$(cat "$ufs/power/control" 2>/dev/null || printf missing)"
	ufs_runtime="$(cat "$ufs/power/runtime_status" 2>/dev/null || printf missing)"
	dirty="$(awk '/^Dirty:/ { print $2 }' /proc/meminfo)"
	writeback="$(awk '/^Writeback:/ { print $2 }' /proc/meminfo)"
	sda="$(awk '$3 == "sda" { print $4 ":" $6 ":" $8 ":" $10 ":" $12 ":" $14 }' /proc/diskstats)"
	loop0="$(awk '$3 == "loop0" { print $4 ":" $6 ":" $8 ":" $10 ":" $12 ":" $14 }' /proc/diskstats)"
	printf 'sample=%s uptime=%s phase=%s ufs_control=%s ufs_runtime=%s dirty_kb=%s writeback_kb=%s sda=%s loop0=%s\n' \
		"$sample" "$uptime_now" "$phase" "$ufs_control" "$ufs_runtime" \
		"$dirty" "$writeback" "${sda:-missing}" "${loop0:-missing}"
	if [ $((sample % 5)) -eq 0 ] && [ -c /dev/pmsg0 ]; then
		printf '<6>HOTDOG_FLATPAK_TEST phase=%s sample=%s uptime=%s ufs=%s/%s dirty_kb=%s writeback_kb=%s\n' \
			"$phase" "$sample" "$uptime_now" "$ufs_control" "$ufs_runtime" \
			"$dirty" "$writeback" > /dev/pmsg0
	fi
	sleep 0.2
done
REMOTE
}

# shellcheck disable=SC2329
flatpak_program() {
	cat <<'REMOTE'
set -eu
phase="$1"
app_id="$2"
case "$phase" in
	pull)
		phase_args='--no-deploy'
		;;
	deploy)
		phase_args='--no-pull'
		;;
	*)
		echo "unsupported phase: $phase" >&2
		exit 2
		;;
esac
printf '<6>HOTDOG_FLATPAK_TEST phase=%s-start uptime=%s\n' \
	"$phase" "$(cut -d' ' -f1 /proc/uptime)" > /dev/pmsg0
set +e
strace -f -ttt -T -yy -s 256 \
	-e trace=%file,%process,fsync,fdatasync,sync,syncfs,fallocate,ioctl,fcntl,flock,copy_file_range,sendfile,splice \
	flatpak -vv --ostree-verbose install --system --assumeyes --noninteractive \
		--no-related --no-deps $phase_args flathub "$app_id"
status=$?
set -e
printf '<6>HOTDOG_FLATPAK_TEST phase=%s-exit status=%s uptime=%s\n' \
	"$phase" "$status" "$(cut -d' ' -f1 /proc/uptime)" > /dev/pmsg0
exit "$status"
REMOTE
}

usb_state() {
	if lsusb -d 05c6:900e 2>/dev/null | grep -q .; then
		printf qualcomm-900e
	elif hotdog_fastboot_usb_visible; then
		printf fastboot
	elif ping -c 1 -W 1 "$PMOS_HOST" >/dev/null 2>&1; then
		printf mainline
	else
		printf other
	fi
}

case "$PHASE" in
	pull|deploy)
		;;
	-h|--help|'')
		usage
		exit 0
		;;
	*)
		usage >&2
		die "unknown phase: $PHASE" 2
		;;
esac
[[ "$APP_ID" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid Flatpak application ID: $APP_ID" 2
if [ -n "$MAX_SECTORS_KB" ]; then
	[[ "$MAX_SECTORS_KB" =~ ^[1-9][0-9]*$ ]] ||
		die "MAX_SECTORS_KB must be a positive integer" 2
fi
[ -n "$PMOS_PASSWORD" ] || die "set PMOS_PASSWORD or HOTDOG_PMOS_PASSWORD" 2
hotdog_require_target_serial || die "set ANDROID_SERIAL or HOTDOG_TARGET_SERIAL" 2
for command_name in grep lsusb ping ssh sshpass tee; do
	command -v "$command_name" >/dev/null 2>&1 || die "missing command: $command_name" 127
done
"$HOTDOG_ROOT/scripts/capture-qdl-900e-ramdump.sh" preflight ||
	die "QDL full-RAM crash capture preflight failed" 127

mkdir -p "$OUT"
exec > >(tee "$OUT/run.log") 2>&1
log "Run directory: $OUT"
log "Phase: $PHASE"
log "Application: $APP_ID"
log "UFS max_sectors_kb override: ${MAX_SECTORS_KB:-unchanged}"
log "Reset policy: never"
phone_lock_acquire "Flatpak UFS finalization test ($PHASE)" 0 ||
	die "could not acquire phone-operation lock" 4

uname_output="$(ssh_base 'uname -a')" || die "mainline SSH is unavailable" 5
printf '%s\n' "$uname_output" | tee "$OUT/uname.txt"
[[ "$uname_output" == *"$EXPECTED_KERNEL_MARKER"* ]] ||
	die "running kernel does not contain marker: $EXPECTED_KERNEL_MARKER" 6

run_root_program "sh -s -- '$MAX_SECTORS_KB'" setup_program | tee "$OUT/setup.txt"

run_root_program 'sh -s' dmesg_program \
	> >(tee "$OUT/dmesg-live.txt") \
	2> >(tee "$OUT/dmesg-live.stderr" >&2) &
REMOTE_PIDS+=("$!")
run_root_program "sh -s -- '$PHASE'" sampler_program \
	> >(tee "$OUT/storage-live.txt") \
	2> >(tee "$OUT/storage-live.stderr" >&2) &
REMOTE_PIDS+=("$!")
log "Live monitors started"

set +e
run_root_program "sh -s -- '$PHASE' '$APP_ID'" flatpak_program \
	> >(tee "$OUT/flatpak.stdout.txt") \
	2> >(tee "$OUT/flatpak-strace.stderr.txt" >&2) &
test_pid=$!
set -e
log "Flatpak test PID: $test_pid"

transition=mainline
while kill -0 "$test_pid" 2>/dev/null; do
	transition="$(usb_state)"
	case "$transition" in
		qualcomm-900e|fastboot)
			log "USB transition detected: $transition"
			break
			;;
	esac
	sleep 0.2
done

if kill -0 "$test_pid" 2>/dev/null; then
	kill "$test_pid" 2>/dev/null || true
fi
set +e
wait "$test_pid"
test_status=$?
set -e

if [ "$transition" = mainline ] || [ "$transition" = other ]; then
	deadline=$((SECONDS + 10))
	while [ "$SECONDS" -lt "$deadline" ]; do
		transition="$(usb_state)"
		case "$transition" in
			qualcomm-900e|fastboot)
				log "USB transition detected after command exit: $transition"
				break
				;;
		esac
		sleep 0.2
	done
fi

stop_remote_streams
case "$transition" in
	qualcomm-900e)
		printf 'result=qualcomm-900e phase=%s command_status=%s\n' "$PHASE" "$test_status" |
			tee "$OUT/result.txt"
		phone_lock_release
		OUT="$OUT/qdl-900e-ramdump" \
			"$HOTDOG_ROOT/scripts/capture-qdl-900e-ramdump.sh" capture || true
		exit 10
		;;
	fastboot)
		printf 'result=fastboot phase=%s command_status=%s\n' "$PHASE" "$test_status" |
			tee "$OUT/result.txt"
		exit 11
		;;
esac

printf 'result=command-exit phase=%s command_status=%s usb_state=%s\n' \
	"$PHASE" "$test_status" "$transition" | tee "$OUT/result.txt"
if [ "$test_status" -eq 0 ]; then
	log "Flatpak phase completed while mainline remained reachable"
	exit 0
fi
die "Flatpak phase failed without a classified USB transition" "$test_status"
