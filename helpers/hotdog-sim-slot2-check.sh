#!/usr/bin/env bash

set -Eeuo pipefail

expected_kernel=6.16.0-sm8150
expected_modemmanager_sha=25cb578e9cf3354b7de14653ab500ab6c911c24d0386ea99ab99554e61d24ef9
expected_modem_sha=559a517c2d4ca5c22d25e0a9b3383bbf7591a632f688b629a19c3e51e3dba9e5
expected_modem_build=MPSS.HE.1.0.c11.1-00007-SM8150_GEN_PACK-2.320290.2.328393.1
stamp=$(date -u +%Y%m%dT%H%M%SZ)
log_file="/home/user/hotdog-sim-slot2-$stamp.log"
dmesg_pid=

# Invoked indirectly by trap.
# shellcheck disable=SC2329
cleanup() {
	if [ -n "$dmesg_pid" ]; then
		kill "$dmesg_pid" 2>/dev/null || true
		wait "$dmesg_pid" 2>/dev/null || true
	fi
	chown user:user "$log_file" "$log_file.dmesg" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

if [ "$(id -u)" -ne 0 ]; then
	exec doas "$0" "$@"
fi

exec > >(tee "$log_file") 2>&1

die() {
	printf 'STOP: %s\n' "$*" >&2
	exit 1
}

uim_status() {
	timeout 8 qmicli -p -d qrtr://0 --uim-get-card-status 2>&1
}

pin_retries() {
	printf '%s\n' "$1" | awk '/PIN1 retries:/ { gsub("[^0-9]", "", $0); print; exit }'
}

puk_retries() {
	printf '%s\n' "$1" | awk '/PUK1 retries:/ { gsub("[^0-9]", "", $0); print; exit }'
}

printf 'Hotdog SIM slot 2 guarded test\n'
printf 'Log: %s\n\n' "$log_file"
printf 'This script never reads or submits the PIN. Enter it only in Plasma.\n'
printf 'Insert the SIM in slot 2 while powered off, boot normally, then run this.\n'
printf 'The script stops before PIN entry unless every safety gate passes.\n\n'

[ "$(uname -r)" = "$expected_kernel" ] || die "unexpected kernel: $(uname -r)"
[ "$(sha256sum /usr/sbin/ModemManager | awk '{ print $1 }')" = "$expected_modemmanager_sha" ] ||
	die "the slot-aware ModemManager build is not installed"
[ "$(sha256sum /usr/lib/firmware/qcom/sm8150/oneplus/hotdog/modem.mbn | awk '{ print $1 }')" = "$expected_modem_sha" ] ||
	die "the OxygenOS 10 modem firmware is not installed"

revision=$(timeout 8 qmicli -p -d qrtr://0 --dms-get-revision 2>&1)
printf '%s\n' "$revision" | grep -Fq "$expected_modem_build" ||
	die "the running MPSS revision is not OxygenOS 10"

status=$(uim_status)
printf '%s\n' "$status" | grep -Fq "Primary GW:   slot '2', application '1'" ||
	die "slot 2 is not the primary GW provisioning session"
slot2=$(printf '%s\n' "$status" | sed -n '/^Slot \[2\]:/,$p')
printf '%s\n' "$slot2" | grep -Fq "Card state: 'present'" ||
	die "no SIM is present in physical slot 2"
printf '%s\n' "$slot2" | grep -Fq "Application state: 'pin1-or-upin-pin-required'" ||
	die "slot 2 is not waiting for PIN1"

pin_left=$(pin_retries "$status")
puk_left=$(puk_retries "$status")
[ "$pin_left" = 3 ] || die "PIN1 retries are $pin_left, expected 3"
[ "$puk_left" = 10 ] || die "PUK1 retries are $puk_left, expected 10"

mm_state=$(timeout 8 mmcli -m any --output-keyvalue 2>&1)
printf '%s\n' "$mm_state" | grep -Eq 'unlock-required[[:space:]]*: sim-pin$' ||
	die "ModemManager is not waiting for sim-pin"
printf '%s\n' "$mm_state" | grep -Eq 'primary-sim-slot[[:space:]]*: 2$' ||
	die "ModemManager does not expose slot 2 as primary"

printf '\nSafety gates PASS:\n'
printf '  kernel=%s\n' "$expected_kernel"
printf '  modem=%s\n' "$expected_modem_build"
printf '  primary_slot=2 PIN_retries=3 PUK_retries=10\n'
printf '  boot_id=%s\n' "$(cat /proc/sys/kernel/random/boot_id)"
printf '\nEnter the correct PIN exactly once in the Plasma prompt now.\n'
printf 'Do not retry if Plasma reports any error. This script is waiting.\n'
sync

dmesg -w >>"$log_file.dmesg" 2>&1 &
dmesg_pid=$!

accepted=0
i=0
while [ "$i" -lt 120 ]; do
	status=$(uim_status || true)
	pin_left=$(pin_retries "$status")
	puk_left=$(puk_retries "$status")
	[ -n "$pin_left" ] || die "could not read PIN1 retries"
	[ "$pin_left" -eq 3 ] || die "PIN1 retries changed to $pin_left; do not retry"
	[ "$puk_left" -eq 10 ] || die "PUK1 retries changed to $puk_left; do not retry"

	if printf '%s\n' "$status" | grep -Fq "Application state: 'ready'"; then
		accepted=1
		printf 'PIN_ACCEPTED without retry loss at t=%ss\n' "$i"
		break
	fi
	if dmesg | grep -q 'crash detected in modem'; then
		die "MPSS crashed before PIN acceptance"
	fi
	sleep 1
	i=$((i + 1))
	[ $((i % 5)) -ne 0 ] || sync
done
[ "$accepted" -eq 1 ] || die "PIN was not accepted within 120 seconds"

printf '\nMonitoring MPSS and network registration for 180 seconds.\n'
i=0
while [ "$i" -lt 180 ]; do
	remote_state=$(cat /sys/class/remoteproc/remoteproc1/state 2>/dev/null || printf missing)
	[ "$remote_state" = running ] || die "MPSS state changed to $remote_state"
	if dmesg | grep -q 'crash detected in modem'; then
		die "MPSS watchdog/crash detected after PIN acceptance"
	fi

	mm_state=$(timeout 5 mmcli -m any --output-keyvalue 2>/dev/null || true)
	registration=$(printf '%s\n' "$mm_state" | sed -n 's/^modem.3gpp.registration-state[[:space:]]*:[[:space:]]*//p')
	signal=$(printf '%s\n' "$mm_state" | sed -n 's/^modem.generic.signal-quality.value[[:space:]]*:[[:space:]]*//p')
	printf 't=%03ss mpss=%s registration=%s signal=%s\n' \
		"$i" "$remote_state" "${registration:---}" "${signal:---}"

	case "$registration" in
		home|roaming)
			printf 'PASS: registered=%s signal=%s\n' "$registration" "${signal:---}"
			sync
			exit 0
			;;
	esac
	sleep 2
	i=$((i + 2))
	[ $((i % 10)) -ne 0 ] || sync
done

die "MPSS stayed alive but did not register within 180 seconds"
