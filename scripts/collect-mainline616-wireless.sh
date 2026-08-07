#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=/dev/null
source "$(dirname "$0")/env.sh"

PMOS_HOST="${PMOS_HOST:-$HOTDOG_PMOS_HOST}"
PMOS_USER="${PMOS_USER:-$HOTDOG_PMOS_USER}"
PMOS_PASSWORD="${PMOS_PASSWORD:-$HOTDOG_PMOS_PASSWORD}"
EXPECTED_KERNEL_MARKER="${EXPECTED_KERNEL_MARKER:-oneplus-hotdog-mainline616}"
TARGET_SERIAL="${ANDROID_SERIAL:-$HOTDOG_TARGET_SERIAL}"
REQUIRE_WORKING=0
REQUIRE_MPSS=0
stamp="$(date +%F-%H%M%S)"
OUT="${OUT:-$HOTDOG_LOG_ROOT/mainline616-wireless-$stamp}"

usage() {
	cat <<'USAGE'
Usage: collect-mainline616-wireless.sh [options]

Collect a read-only MPSS, QRTR, ATH10K and WiFi snapshot from a running
OnePlus hotdog mainline system over SSH. The script never starts a service,
writes a remoteproc state, changes rfkill state, or configures an interface.

Options:
  --host HOST           SSH host. Default: 172.16.42.1.
  --user USER           SSH user. Default: user.
  --password PASS       SSH password. Defaults to PMOS_PASSWORD.
  --kernel-marker TEXT  Required substring in uname -a.
  --serial SERIAL       Required androidboot.serialno value.
  --require-mpss        Fail unless read-only RMTFS and MPSS are running.
  --require-working     Fail unless MPSS is running and a WLAN netdev exists.
  --out DIR             Output directory.
  -h, --help            Show this help.
USAGE
}

die() {
	printf 'collect-mainline616-wireless: %s\n' "$*" >&2
	exit 2
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
		--require-working)
			REQUIRE_WORKING=1
			REQUIRE_MPSS=1
			;;
		--require-mpss)
			REQUIRE_MPSS=1
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

set +e
ssh_base "sudo -n sh -s -- '$REQUIRE_MPSS' '$REQUIRE_WORKING'" \
	> >(tee "$OUT/snapshot.txt") 2> >(tee "$OUT/snapshot.stderr" >&2) <<'REMOTE'
set -eu

require_mpss="$1"
require_working="$2"

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
for file in \
	/lib/firmware/qcom/sm8150/oneplus/hotdog/modem.mbn \
	/lib/firmware/qcom/sm8150/oneplus/hotdog/wlanmdsp.mbn \
	/lib/firmware/ath10k/WCN3990/hw1.0/board-2.bin \
	/lib/firmware/ath10k/WCN3990/hw1.0/firmware-5.bin; do
	if [ -r "$file" ]; then
		printf '%s size=%s\n' "$file" "$(wc -c < "$file")"
	else
		printf '%s MISSING\n' "$file"
	fi
done

section remoteproc
mpss_found=0
mpss_running=0
for remoteproc in /sys/class/remoteproc/remoteproc*; do
	[ -d "$remoteproc" ] || continue
	name="$(read_file "$remoteproc/name")"
	state="$(read_file "$remoteproc/state")"
	firmware="$(read_file "$remoteproc/firmware")"
	printf '%s name=%s state=%s firmware=%s\n' \
		"${remoteproc##*/}" "$name" "$state" "$firmware"
	case "$name $firmware" in
		*[Mm][Pp][Ss][Ss]*|*[Mm][Oo][Dd][Ee][Mm]*)
			mpss_found=1
			[ "$state" = running ] && mpss_running=1
			;;
	esac
done
[ "$mpss_found" -eq 1 ] || echo 'mpss=<not-found>'

section services
for service in qrtr-ns tqftpserv pd-mapper rmtfs; do
	if command -v rc-service >/dev/null 2>&1 && [ -e "/etc/init.d/$service" ]; then
		rc-service "$service" status 2>&1 || true
	else
		printf '%s=<not-installed>\n' "$service"
	fi
done

section rmtfs
rmtfs_device_found=0
for device in /dev/qcom_rmtfs_mem*; do
	[ -e "$device" ] || continue
	rmtfs_device_found=1
	ls -l "$device"
done
[ "$rmtfs_device_found" -eq 1 ] || echo 'rmtfs-device=<not-found>'

rmtfs_process_found=0
rmtfs_readonly=0
for cmdline_file in /proc/[0-9]*/cmdline; do
	[ -r "$cmdline_file" ] || continue
	cmdline_text="$(tr '\000' ' ' < "$cmdline_file")"
	case "$cmdline_text" in
		*rmtfs*)
			rmtfs_process_found=1
			printf '%s\n' "$cmdline_text"
			case " $cmdline_text " in
				*' -r '*) rmtfs_readonly=1 ;;
			esac
			;;
	esac
done
[ "$rmtfs_process_found" -eq 1 ] || echo 'rmtfs-process=<not-found>'
printf 'rmtfs-read-only=%s\n' "$rmtfs_readonly"

for device in /sys/bus/platform/devices/*f2901000*; do
	[ -d "$device" ] || continue
	printf 'platform-device=%s driver=' "$device"
	readlink "$device/driver" 2>/dev/null || printf '<unbound>\n'
	[ ! -r "$device/uevent" ] || sed 's/^/  /' "$device/uevent"
done
grep -Ei 'f2901000|rmtfs' /proc/iomem 2>/dev/null || true

section modules
if command -v lsmod >/dev/null 2>&1; then
	lsmod | grep -E '(^Module|ath10k|qcom_q6v5|qcom_rproc|qrtr|qcom_pd_mapper)' || true
else
	cat /proc/modules | grep -E 'ath10k|qcom_q6v5|qcom_rproc|qrtr|qcom_pd_mapper' || true
fi

section wifi-platform
wifi_found=0
for device in /sys/bus/platform/devices/*18800000.wifi* /sys/bus/platform/devices/*.wifi; do
	[ -d "$device" ] || continue
	wifi_found=1
	printf 'device=%s\n' "$device"
	printf '  driver='
	readlink "$device/driver" 2>/dev/null || printf '<unbound>\n'
	printf '  modalias='
	read_file "$device/modalias"
	[ ! -r "$device/uevent" ] || sed 's/^/  /' "$device/uevent"
done
[ "$wifi_found" -eq 1 ] || echo 'wifi-platform=<not-found>'

section rfkill
if command -v rfkill >/dev/null 2>&1; then
	rfkill list 2>&1 || true
else
	for rfkill in /sys/class/rfkill/rfkill*; do
		[ -d "$rfkill" ] || continue
		printf '%s type=%s name=%s soft=%s hard=%s\n' \
			"${rfkill##*/}" \
			"$(read_file "$rfkill/type")" \
			"$(read_file "$rfkill/name")" \
			"$(read_file "$rfkill/soft")" \
			"$(read_file "$rfkill/hard")"
	done
fi

section network
wlan_found=0
for interface in /sys/class/net/*; do
	[ -d "$interface" ] || continue
	name="${interface##*/}"
	printf '%s address=%s operstate=%s\n' \
		"$name" "$(read_file "$interface/address")" "$(read_file "$interface/operstate")"
	if [ -d "$interface/wireless" ] || [ -e "$interface/phy80211" ]; then
		wlan_found=1
	fi
done
if command -v iw >/dev/null 2>&1; then
	iw dev 2>&1 || true
	if iw dev 2>/dev/null | grep -q 'Interface '; then
		wlan_found=1
	fi
fi

section qrtr
if command -v qrtr-lookup >/dev/null 2>&1; then
	timeout 2 qrtr-lookup 2>&1 || true
else
	echo 'qrtr-lookup=<not-installed>'
fi
ss -a 2>/dev/null | grep -i qrtr || true

section dmesg
dmesg | grep -Ei 'remoteproc|q6v5|mpss|modem|qrtr|rmtfs|pd.mapper|tqftp|ath10k|wcn3990|wlan|wifi|firmware' || true

if [ "$require_mpss" -eq 1 ]; then
	[ "$rmtfs_device_found" -eq 1 ] || {
		echo 'ERROR: RMTFS memory device is missing' >&2
		exit 18
	}
	[ "$rmtfs_process_found" -eq 1 ] || {
		echo 'ERROR: RMTFS process is not running' >&2
		exit 19
	}
	[ "$rmtfs_readonly" -eq 1 ] || {
		echo 'ERROR: RMTFS process is not in read-only mode' >&2
		exit 20
	}
	[ "$mpss_found" -eq 1 ] || {
		echo 'ERROR: MPSS remoteproc is missing' >&2
		exit 21
	}
	[ "$mpss_running" -eq 1 ] || {
		echo 'ERROR: MPSS remoteproc is not running' >&2
		exit 22
	}
	fi

if [ "$require_working" -eq 1 ]; then
	[ "$wifi_found" -eq 1 ] || {
		echo 'ERROR: WiFi platform device is missing' >&2
		exit 23
	}
	[ "$wlan_found" -eq 1 ] || {
		echo 'ERROR: WLAN netdev is missing' >&2
		exit 24
	}
fi
REMOTE
remote_status=$?
set -e

printf 'remote_status=%s\n' "$remote_status" | tee "$OUT/result.txt"
[ "$remote_status" -eq 0 ] || die "remote collection failed with status $remote_status"

printf 'Wireless evidence written to %s\n' "$OUT"
