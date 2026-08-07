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
OUT="${OUT:-$HOTDOG_LOG_ROOT/mainline616-wcd9340-$stamp}"

usage() {
	cat <<'USAGE'
Usage: collect-mainline616-wcd9340.sh [options]

Collect a read-only SLIMbus and WCD9340 snapshot from a running OnePlus
hotdog mainline system over SSH. The script never loads a module, starts a
service, writes sysfs, or changes audio state.

Options:
  --host HOST           SSH host. Default: 172.16.42.1.
  --user USER           SSH user. Default: user.
  --password PASS       SSH password. Defaults to PMOS_PASSWORD.
  --kernel-marker TEXT  Required substring in uname -a.
  --serial SERIAL       Required androidboot.serialno value.
  --duration SEC        Stability observation. Default: 60.
  --interval SEC        Seconds between samples. Default: 5.
  --require-ready       Require ADSP, NGD, WCD9340 and child bindings.
  --out DIR             Output directory.
  -h, --help            Show this help.
USAGE
}

die() {
	printf 'collect-mainline616-wcd9340: %s\n' "$*" >&2
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

bound_driver() {
	device="$1"
	if target="$(readlink "$device/driver" 2>/dev/null)"; then
		basename "$target"
	else
		printf '<unbound>\n'
	fi
}

section identity
uname -a
cat /proc/cmdline
printf 'boot_id='
cat /proc/sys/kernel/random/boot_id

section adsp
adsp_found=0
adsp_running=0
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
			;;
	esac
done
[ "$adsp_found" -eq 1 ] || echo 'adsp-remoteproc=<not-found>'

section ngd-platform
ngd_platform_found=0
ngd_platform_bound=0
ngd_child_found=0
ngd_child_bound=0
for device in /sys/bus/platform/devices/*171c0000*; do
	[ -d "$device" ] || continue
	ngd_platform_found=1
	driver="$(bound_driver "$device")"
	[ "$driver" != '<unbound>' ] && ngd_platform_bound=1
	printf 'controller=%s driver=%s modalias=%s\n' \
		"$device" "$driver" "$(read_file "$device/modalias")"
done
for device in /sys/bus/platform/devices/qcom,slim-ngd.*; do
	[ -d "$device" ] || continue
	ngd_child_found=1
	driver="$(bound_driver "$device")"
	[ "$driver" = 'qcom,slim-ngd' ] && ngd_child_bound=1
	printf 'ngd=%s driver=%s\n' "$device" "$driver"
done
[ "$ngd_platform_found" -eq 1 ] || echo 'ngd-controller=<not-found>'
[ "$ngd_child_found" -eq 1 ] || echo 'ngd-child=<not-found>'

section slimbus
ifd_found=0
codec_found=0
codec_bound=0
for device in /sys/bus/slimbus/devices/*; do
	[ -d "$device" ] || continue
	name="${device##*/}"
	driver="$(bound_driver "$device")"
	printf 'slimbus=%s driver=%s modalias=%s\n' \
		"$name" "$driver" "$(read_file "$device/modalias")"
	[ "$name" = '217:250:0:0' ] && ifd_found=1
	if [ "$name" = '217:250:1:0' ]; then
		codec_found=1
		[ "$driver" = 'wcd934x-slim' ] && codec_bound=1
	fi
done
[ "$ifd_found" -eq 1 ] || echo 'wcd9340-interface=<not-found>'
[ "$codec_found" -eq 1 ] || echo 'wcd9340-codec=<not-found>'

section mfd-children
codec_child_found=0
codec_child_bound=0
gpio_child_found=0
gpio_child_bound=0
soundwire_child_found=0
soundwire_child_bound=0
for device in /sys/bus/platform/devices/wcd934x-codec.*; do
	[ -d "$device" ] || continue
	codec_child_found=1
	driver="$(bound_driver "$device")"
	[ "$driver" = 'wcd934x-codec' ] && codec_child_bound=1
	printf 'codec-child=%s driver=%s\n' "$device" "$driver"
done
for device in /sys/bus/platform/devices/wcd934x-gpio.*; do
	[ -d "$device" ] || continue
	gpio_child_found=1
	driver="$(bound_driver "$device")"
	[ "$driver" = 'wcd934x-gpio' ] && gpio_child_bound=1
	printf 'gpio-child=%s driver=%s\n' "$device" "$driver"
done
for device in /sys/bus/platform/devices/wcd934x-soundwire.*; do
	[ -d "$device" ] || continue
	soundwire_child_found=1
	driver="$(bound_driver "$device")"
	[ "$driver" = 'qcom-soundwire' ] && soundwire_child_bound=1
	printf 'soundwire-child=%s driver=%s\n' "$device" "$driver"
done

section gpiochips
for chip in /sys/class/gpio/gpiochip*; do
	[ -d "$chip" ] || continue
	label="$(read_file "$chip/label")"
	case "$label" in
		*wcd934x*)
			printf 'gpiochip=%s label=%s base=%s ngpio=%s\n' \
				"$chip" "$label" "$(read_file "$chip/base")" "$(read_file "$chip/ngpio")"
			;;
	esac
done

section modules
if command -v lsmod >/dev/null 2>&1; then
	lsmod | grep -E '(^Module|slim|wcd934|soundwire|qcom_q6v5_pas|qcom_apr)' || true
else
	cat /proc/modules | grep -E 'slim|wcd934|soundwire|qcom_q6v5_pas|qcom_apr' || true
fi

section expected-absence
sound_card_absent=1
for card in /sys/class/sound/card*; do
	[ -e "$card" ] || continue
	sound_card_absent=0
	printf 'sound-card=%s id=%s\n' "$card" "$(read_file "$card/id")"
done
for address in 0034 0035; do
	for codec in /sys/bus/i2c/devices/*-"$address"; do
		[ -e "$codec" ] || continue
		printf 'external-speaker-codec=%s\n' "$codec"
	done
done

section stability
stability_pass=1
sample_count=$((duration_sec / interval_sec + 1))
sample=1
while [ "$sample" -le "$sample_count" ]; do
	adsp_state='<not-found>'
	[ -z "$adsp_path" ] || adsp_state="$(read_file "$adsp_path/state")"
	codec_driver='<not-found>'
	[ ! -d /sys/bus/slimbus/devices/217:250:1:0 ] ||
		codec_driver="$(bound_driver /sys/bus/slimbus/devices/217:250:1:0)"
	codec_child_driver='<not-found>'
	for child in /sys/bus/platform/devices/wcd934x-codec.*; do
		[ -d "$child" ] || continue
		codec_child_driver="$(bound_driver "$child")"
		break
	done
	printf 'sample=%s/%s uptime=%s adsp=%s slim-codec=%s codec-child=%s\n' \
		"$sample" "$sample_count" "$(cut -d' ' -f1 /proc/uptime)" \
		"$adsp_state" "$codec_driver" "$codec_child_driver"
	[ "$adsp_state" = running ] || stability_pass=0
	[ "$codec_driver" = wcd934x-slim ] || stability_pass=0
	[ "$codec_child_driver" = wcd934x-codec ] || stability_pass=0
	[ "$sample" -eq "$sample_count" ] || sleep "$interval_sec"
	sample=$((sample + 1))
done

section dmesg
dmesg_output="$(dmesg)"
printf '%s\n' "$dmesg_output" |
	grep -Ei 'slim|wcd934|soundwire|swrm|adsp|lpass' || true
transport_fault=0
if printf '%s\n' "$dmesg_output" | grep -Ei \
	'capability exchange timed-out|SLIM: capability TX failed|Failed to get logical address|Failed to bring up WCD934|Error allocating slim regmap|Failed to add IRQ chip|Failed to add child devices|soundwire.*probe.*failed'; then
	transport_fault=1
fi

section result
printf 'adsp_found=%s\n' "$adsp_found"
printf 'adsp_running=%s\n' "$adsp_running"
printf 'ngd_platform_found=%s\n' "$ngd_platform_found"
printf 'ngd_platform_bound=%s\n' "$ngd_platform_bound"
printf 'ngd_child_found=%s\n' "$ngd_child_found"
printf 'ngd_child_bound=%s\n' "$ngd_child_bound"
printf 'ifd_found=%s\n' "$ifd_found"
printf 'codec_found=%s\n' "$codec_found"
printf 'codec_bound=%s\n' "$codec_bound"
printf 'codec_child_found=%s\n' "$codec_child_found"
printf 'codec_child_bound=%s\n' "$codec_child_bound"
printf 'gpio_child_found=%s\n' "$gpio_child_found"
printf 'gpio_child_bound=%s\n' "$gpio_child_bound"
printf 'soundwire_child_found=%s\n' "$soundwire_child_found"
printf 'soundwire_child_bound=%s\n' "$soundwire_child_bound"
printf 'sound_card_absent=%s\n' "$sound_card_absent"
printf 'stability_pass=%s\n' "$stability_pass"
printf 'transport_fault=%s\n' "$transport_fault"

if [ "$require_ready" -eq 1 ]; then
	[ "$adsp_found" -eq 1 ] || exit 20
	[ "$adsp_running" -eq 1 ] || exit 21
	[ "$ngd_platform_found" -eq 1 ] || exit 22
	[ "$ngd_platform_bound" -eq 1 ] || exit 23
	[ "$ngd_child_found" -eq 1 ] || exit 24
	[ "$ngd_child_bound" -eq 1 ] || exit 25
	[ "$ifd_found" -eq 1 ] || exit 26
	[ "$codec_found" -eq 1 ] || exit 27
	[ "$codec_bound" -eq 1 ] || exit 28
	[ "$codec_child_found" -eq 1 ] || exit 29
	[ "$codec_child_bound" -eq 1 ] || exit 30
	[ "$gpio_child_found" -eq 1 ] || exit 31
	[ "$gpio_child_bound" -eq 1 ] || exit 32
	[ "$soundwire_child_found" -eq 1 ] || exit 33
	[ "$soundwire_child_bound" -eq 1 ] || exit 34
	[ "$sound_card_absent" -eq 1 ] || exit 35
	[ "$stability_pass" -eq 1 ] || exit 36
	[ "$transport_fault" -eq 0 ] || exit 37
	echo 'WCD9340_TRANSPORT_VALIDATION_PASS'
fi
REMOTE
remote_status=$?
set -e

printf 'remote_status=%s\n' "$remote_status" | tee "$OUT/result.txt"
[ "$remote_status" -eq 0 ] || die "remote collection failed with status $remote_status"
printf 'WCD9340 evidence written to %s\n' "$OUT"
