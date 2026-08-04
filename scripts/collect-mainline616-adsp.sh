#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=/dev/null
source "$(dirname "$0")/env.sh"

PMOS_HOST="${PMOS_HOST:-$HOTDOG_PMOS_HOST}"
PMOS_USER="${PMOS_USER:-$HOTDOG_PMOS_USER}"
PMOS_PASSWORD="${PMOS_PASSWORD:-$HOTDOG_PMOS_PASSWORD}"
EXPECTED_KERNEL_MARKER="${EXPECTED_KERNEL_MARKER:-oneplus-hotdog-mainline616}"
TARGET_SERIAL="${ANDROID_SERIAL:-$HOTDOG_TARGET_SERIAL}"
DURATION_SEC="${DURATION_SEC:-60}"
INTERVAL_SEC="${INTERVAL_SEC:-5}"
REQUIRE_READY=0
stamp="$(date +%F-%H%M%S)"
OUT="${OUT:-$HOTDOG_LOG_ROOT/mainline616-adsp-$stamp}"

usage() {
	cat <<'USAGE'
Usage: collect-mainline616-adsp.sh [options]

Collect a read-only ADSP, GLINK and APR snapshot from a running OnePlus
hotdog mainline system over SSH. The script never loads a module, starts a
service, or writes remoteproc state.

Options:
  --host HOST           SSH host. Default: 172.16.42.1.
  --user USER           SSH user. Default: user.
  --password PASS       SSH password. Defaults to PMOS_PASSWORD.
  --kernel-marker TEXT  Required substring in uname -a.
  --serial SERIAL       Required androidboot.serialno value.
  --duration SEC        Stability observation. Default: 60.
  --interval SEC        Seconds between samples. Default: 5.
  --require-ready       Require running ADSP, exact firmware and APR/GLINK.
  --out DIR             Output directory.
  -h, --help            Show this help.
USAGE
}

die() {
	printf 'collect-mainline616-adsp: %s\n' "$*" >&2
	exit 2
}

positive_integer() {
	local name="$1"
	local value="$2"

	[[ "$value" =~ ^[1-9][0-9]*$ ]] || die "$name must be a positive integer: $value"
}

ssh_base() {
	sshpass -p "$PMOS_PASSWORD" ssh \
		-o StrictHostKeyChecking=no \
		-o UserKnownHostsFile="$OUT/known_hosts" \
		-o ConnectTimeout=5 \
		-o PreferredAuthentications=password \
		-o PubkeyAuthentication=no \
		"$PMOS_USER@$PMOS_HOST" "$@"
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
		--duration)
			[ "$#" -ge 2 ] || die "missing value for --duration"
			DURATION_SEC="$2"
			shift
			;;
		--interval)
			[ "$#" -ge 2 ] || die "missing value for --interval"
			INTERVAL_SEC="$2"
			shift
			;;
		--require-ready)
			REQUIRE_READY=1
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

positive_integer DURATION_SEC "$DURATION_SEC"
positive_integer INTERVAL_SEC "$INTERVAL_SEC"
[ -n "$PMOS_PASSWORD" ] || die "set PMOS_PASSWORD or use --password"
[ -n "$EXPECTED_KERNEL_MARKER" ] || die "kernel marker must not be empty"
command -v ssh >/dev/null 2>&1 || die "missing ssh"
command -v sshpass >/dev/null 2>&1 || die "missing sshpass"

mkdir -p "$OUT"
exec > >(tee "$OUT/run.log") 2>&1

uname_output="$(ssh_base 'uname -a')" || die "SSH or uname failed"
cmdline="$(ssh_base 'cat /proc/cmdline')" || die "could not read /proc/cmdline"
boot_id="$(ssh_base 'cat /proc/sys/kernel/random/boot_id')" || die "could not read boot_id"

printf '%s\n' "$uname_output" | tee "$OUT/uname.txt"
printf '%s\n' "$cmdline" > "$OUT/cmdline.txt"
printf '%s\n' "$boot_id" > "$OUT/boot-id.txt"

[[ "$uname_output" == *"$EXPECTED_KERNEL_MARKER"* ]] ||
	die "running kernel does not contain marker: $EXPECTED_KERNEL_MARKER"
if [ -n "$TARGET_SERIAL" ] && [[ "$cmdline" != *"androidboot.serialno=$TARGET_SERIAL"* ]]; then
	die "running target serial does not match the configured serial"
fi

remote_command="
if [ \"\$(id -u)\" -eq 0 ]; then
	exec sh -s -- '$REQUIRE_READY' '$DURATION_SEC' '$INTERVAL_SEC'
elif command -v doas >/dev/null 2>&1; then
	exec doas -n sh -s -- '$REQUIRE_READY' '$DURATION_SEC' '$INTERVAL_SEC'
elif command -v sudo >/dev/null 2>&1; then
	exec sudo -n sh -s -- '$REQUIRE_READY' '$DURATION_SEC' '$INTERVAL_SEC'
else
	echo 'root read access is unavailable' >&2
	exit 126
fi
"

set +e
ssh_base "$remote_command" \
	> >(tee "$OUT/snapshot.txt") 2> >(tee "$OUT/snapshot.stderr" >&2) <<'REMOTE'
set -eu

require_ready="$1"
duration_sec="$2"
interval_sec="$3"
expected_firmware=qcom/sm8150/oneplus/hotdog/adsp.mbn
firmware_file=/lib/firmware/qcom/sm8150/oneplus/hotdog/adsp.mbn

section() {
	printf '\n=== %s ===\n' "$1"
}

read_file() {
	file="$1"
	if [ -r "$file" ]; then
		cat "$file"
	else
		printf '<unavailable>\n'
	fi
}

section identity
uname -a
cat /proc/cmdline
printf 'boot_id='
cat /proc/sys/kernel/random/boot_id

section firmware
firmware_present=0
if [ -r "$firmware_file" ]; then
	firmware_present=1
	printf '%s size=%s' "$firmware_file" "$(wc -c < "$firmware_file")"
	if command -v sha256sum >/dev/null 2>&1; then
		printf ' sha256=%s' "$(sha256sum "$firmware_file" | cut -d' ' -f1)"
	fi
	printf '\n'
else
	printf '%s MISSING\n' "$firmware_file"
fi

section platform
platform_found=0
platform_bound=0
for device in /sys/bus/platform/devices/*17300000.remoteproc*; do
	[ -d "$device" ] || continue
	platform_found=1
	printf 'device=%s\n' "$device"
	printf 'driver='
	if driver="$(readlink "$device/driver" 2>/dev/null)"; then
		platform_bound=1
		printf '%s\n' "$driver"
	else
		printf '<unbound>\n'
	fi
	[ ! -r "$device/modalias" ] || printf 'modalias=%s\n' "$(cat "$device/modalias")"
done
[ "$platform_found" -eq 1 ] || echo 'adsp-platform=<not-found>'

section remoteproc
adsp_found=0
adsp_running=0
adsp_firmware_exact=0
adsp_path=''
for remoteproc in /sys/class/remoteproc/remoteproc*; do
	[ -d "$remoteproc" ] || continue
	name="$(read_file "$remoteproc/name")"
	state="$(read_file "$remoteproc/state")"
	firmware="$(read_file "$remoteproc/firmware")"
	printf '%s name=%s state=%s firmware=%s\n' \
		"${remoteproc##*/}" "$name" "$state" "$firmware"
	case "$name $firmware" in
		*[Aa][Dd][Ss][Pp]*|*[Ll][Pp][Aa][Ss][Ss]*)
			adsp_found=1
			adsp_path="$remoteproc"
			[ "$state" = running ] && adsp_running=1
			[ "$firmware" = "$expected_firmware" ] && adsp_firmware_exact=1
			;;
	esac
done
[ "$adsp_found" -eq 1 ] || echo 'adsp-remoteproc=<not-found>'

section stability
stability_pass=1
sample_count=$((duration_sec / interval_sec + 1))
sample=1
while [ "$sample" -le "$sample_count" ]; do
	state='<not-found>'
	if [ -n "$adsp_path" ] && [ -r "$adsp_path/state" ]; then
		state="$(cat "$adsp_path/state")"
	fi
	printf 'sample=%s/%s uptime=%s state=%s\n' \
		"$sample" "$sample_count" "$(cut -d' ' -f1 /proc/uptime)" "$state"
	[ "$state" = running ] || stability_pass=0
	[ "$sample" -eq "$sample_count" ] || sleep "$interval_sec"
	sample=$((sample + 1))
done

section rpmsg-and-apr
apr_found=0
for device in /sys/bus/rpmsg/devices/*; do
	[ -d "$device" ] || continue
	name="$(read_file "$device/name")"
	printf 'rpmsg=%s name=%s driver=' "$device" "$name"
	readlink "$device/driver" 2>/dev/null || printf '<unbound>\n'
	case "$name" in
		*apr_audio_svc*|*APR*|*apr*) apr_found=1 ;;
	esac
done
for device in /sys/bus/apr/devices/*; do
	[ -d "$device" ] || continue
	apr_found=1
	printf 'apr=%s driver=' "$device"
	readlink "$device/driver" 2>/dev/null || printf '<unbound>\n'
done
[ "$apr_found" -eq 1 ] || echo 'apr-endpoint=<not-found>'

section modules
if command -v lsmod >/dev/null 2>&1; then
	lsmod | grep -E '(^Module|qcom_q6v5_pas|qcom_q6v5|qcom_sysmon|qcom_glink|qcom_apr|q6)' || true
else
	cat /proc/modules | grep -E 'qcom_q6v5_pas|qcom_q6v5|qcom_sysmon|qcom_glink|qcom_apr|q6' || true
fi

section intentionally-disabled-audio
for card in /sys/class/sound/card*; do
	[ -e "$card" ] || continue
	printf 'sound-card=%s id=%s\n' "$card" "$(read_file "$card/id")"
done
for codec in /sys/bus/i2c/devices/*-0034; do
	[ -e "$codec" ] || continue
	printf 'speaker-codec=%s\n' "$codec"
done

section dmesg
dmesg_output="$(dmesg)"
printf '%s\n' "$dmesg_output" |
	grep -Ei 'remoteproc|q6v5|adsp|lpass|glink|apr|qcom.*pas|firmware' || true
adsp_fault=0
if printf '%s\n' "$dmesg_output" |
	grep -Ei '(adsp|lpass|q6v5).*(crash|fatal|watchdog|auth[^ ]* fail|failed to load|timed out)'; then
	adsp_fault=1
fi

section result
printf 'firmware_present=%s\n' "$firmware_present"
printf 'platform_found=%s\n' "$platform_found"
printf 'platform_bound=%s\n' "$platform_bound"
printf 'adsp_found=%s\n' "$adsp_found"
printf 'adsp_running=%s\n' "$adsp_running"
printf 'adsp_firmware_exact=%s\n' "$adsp_firmware_exact"
printf 'stability_pass=%s\n' "$stability_pass"
printf 'apr_found=%s\n' "$apr_found"
printf 'adsp_fault=%s\n' "$adsp_fault"

if [ "$require_ready" -eq 1 ]; then
	[ "$firmware_present" -eq 1 ] || exit 20
	[ "$platform_found" -eq 1 ] || exit 21
	[ "$platform_bound" -eq 1 ] || exit 22
	[ "$adsp_found" -eq 1 ] || exit 23
	[ "$adsp_running" -eq 1 ] || exit 24
	[ "$adsp_firmware_exact" -eq 1 ] || exit 25
	[ "$stability_pass" -eq 1 ] || exit 26
	[ "$apr_found" -eq 1 ] || exit 27
	[ "$adsp_fault" -eq 0 ] || exit 28
	echo 'ADSP_VALIDATION_PASS'
fi
REMOTE
remote_status=$?
set -e

printf 'remote_status=%s\n' "$remote_status" | tee "$OUT/result.txt"
[ "$remote_status" -eq 0 ] || die "remote collection failed with status $remote_status"
printf 'ADSP evidence written to %s\n' "$OUT"
