#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=/dev/null
source "$(dirname "$0")/env.sh"

PMOS_HOST="${PMOS_HOST:-$HOTDOG_PMOS_HOST}"
PMOS_USER="${PMOS_USER:-$HOTDOG_PMOS_USER}"
PMOS_PASSWORD="${PMOS_PASSWORD:-$HOTDOG_PMOS_PASSWORD}"
DURATION_SEC="${DURATION_SEC:-600}"
INTERVAL_SEC="${INTERVAL_SEC:-5}"
MAX_BATTERY_UV="${MAX_BATTERY_UV:-4420000}"
EXPECTED_KERNEL_MARKER="${EXPECTED_KERNEL_MARKER:-oneplus-hotdog-mainline616}"
TARGET_SERIAL="${ANDROID_SERIAL:-$HOTDOG_TARGET_SERIAL}"
stamp="$(date +%F-%H%M%S)"
OUT="${OUT:-$HOTDOG_LOG_ROOT/mainline616-power-$stamp}"

usage() {
	cat <<'USAGE'
Usage: collect-mainline616-power.sh [options]

Collect a read-only battery and charger validation trace from a running
OnePlus hotdog mainline system over SSH. The command fails if the expected
power supplies are absent or battery voltage exceeds the configured limit.

Options:
  --host HOST           SSH host. Default: 172.16.42.1.
  --user USER           SSH user. Default: user.
  --password PASS       SSH password. Defaults to PMOS_PASSWORD.
  --duration SEC        Observation duration. Default: 600.
  --interval SEC        Seconds between samples. Default: 5.
  --max-battery-uv UV   Abort threshold. Default: 4420000.
  --kernel-marker TEXT  Required substring in uname -a.
  --serial SERIAL       Required androidboot.serialno value.
  --out DIR             Output directory.
  -h, --help            Show this help.

The script performs no remote writes. It uses passwordless sudo when available
for optional debugfs data and otherwise validates the public sysfs interface as
the SSH user.
USAGE
}

die() {
	printf 'collect-mainline616-power: %s\n' "$*" >&2
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
		--max-battery-uv)
			[ "$#" -ge 2 ] || die "missing value for --max-battery-uv"
			MAX_BATTERY_UV="$2"
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
positive_integer MAX_BATTERY_UV "$MAX_BATTERY_UV"
[ -n "$PMOS_PASSWORD" ] || die "set PMOS_PASSWORD or use --password"
[ -n "$EXPECTED_KERNEL_MARKER" ] || die "kernel marker must not be empty"
command -v ssh >/dev/null 2>&1 || die "missing ssh"
command -v sshpass >/dev/null 2>&1 || die "missing sshpass"

mkdir -p "$OUT"
exec > >(tee "$OUT/run.log") 2>&1

printf 'host=%s user=%s duration=%ss interval=%ss max_battery_uv=%s\n' \
	"$PMOS_HOST" "$PMOS_USER" "$DURATION_SEC" "$INTERVAL_SEC" "$MAX_BATTERY_UV"

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

remote_monitor="sh -s -- '$DURATION_SEC' '$INTERVAL_SEC' '$MAX_BATTERY_UV'"
if ssh_base 'sudo -n true' >/dev/null 2>&1; then
	remote_monitor="sudo -n $remote_monitor"
fi

set +e
ssh_base "$remote_monitor" \
	> >(tee "$OUT/monitor.txt") 2> >(tee "$OUT/monitor.stderr" >&2) <<'REMOTE'
set -eu

duration_sec="$1"
interval_sec="$2"
max_battery_uv="$3"
battery=/sys/class/power_supply/qcom-battery
charger=/sys/class/power_supply/pm8150b-charger

[ -d "$battery" ] || {
	echo "ERROR: missing $battery" >&2
	exit 10
}
[ -d "$charger" ] || {
	echo "ERROR: missing $charger" >&2
	exit 11
}

read_attr() {
	path="$1"
	if [ -r "$path" ]; then
		cat "$path"
	else
		printf '<unavailable>\n'
	fi
}

dump_supply() {
	supply="$1"
	name="${supply##*/}"
	echo "supply=$name"
	for attribute in \
		type status health present online capacity capacity_level \
		voltage_now voltage_max voltage_max_design current_now current_max \
		constant_charge_current constant_charge_current_max \
		constant_charge_voltage constant_charge_voltage_max \
		charge_now charge_full charge_full_design temp usb_type; do
		value="$(read_attr "$supply/$attribute")"
		printf '  %s=%s\n' "$attribute" "$value"
	done
}

dump_registers() {
	found=0
	for regmap in /sys/kernel/debug/regmap/*; do
		[ -d "$regmap" ] || continue
		[ -r "$regmap/registers" ] || continue
		name="$(read_attr "$regmap/name")"
		registers="$(awk '$1 == "1061:" || $1 == "1070:" || $1 == "1370:" { print }' "$regmap/registers")"
		[ -n "$registers" ] || continue
		found=1
		printf 'regmap=%s name=%s\n' "$regmap" "$name"
		printf '%s\n' "$registers"
	done
	[ "$found" -eq 1 ] || echo 'regmap=<unavailable-or-no-target-registers>'
}

echo '=== initial targeted regmap values ==='
dump_registers
echo '=== initial power-related dmesg ==='
dmesg | grep -Ei 'battery|charger|power_supply|qcom.smbx|smb[25]|qpnp.*fg|fg-gen3' || true

sample_count=$((duration_sec / interval_sec + 1))
sample=1
while [ "$sample" -le "$sample_count" ]; do
	echo "=== sample=$sample/$sample_count monotonic=$(cut -d' ' -f1 /proc/uptime) ==="
	dump_supply "$battery"
	dump_supply "$charger"

	voltage_now="$(read_attr "$battery/voltage_now")"
	case "$voltage_now" in
		''|*[!0-9]*)
			echo "ERROR: invalid battery voltage_now=$voltage_now" >&2
			exit 12
			;;
	esac
	if [ "$voltage_now" -gt "$max_battery_uv" ]; then
		echo "ERROR: battery voltage $voltage_now exceeds $max_battery_uv uV" >&2
		exit 20
	fi

	[ "$sample" -eq "$sample_count" ] || sleep "$interval_sec"
	sample=$((sample + 1))
done

echo '=== final targeted regmap values ==='
dump_registers
echo '=== final power-related dmesg ==='
dmesg | grep -Ei 'battery|charger|power_supply|qcom.smbx|smb[25]|qpnp.*fg|fg-gen3' || true
echo 'POWER_VALIDATION_PASS'
REMOTE
remote_status=$?
set -e

printf 'remote_status=%s\n' "$remote_status" | tee "$OUT/result.txt"
[ "$remote_status" -eq 0 ] || die "remote validation failed with status $remote_status; see $OUT"
printf 'PASS: battery/charger trace completed without exceeding %s uV\n' "$MAX_BATTERY_UV" |
	tee -a "$OUT/result.txt"
