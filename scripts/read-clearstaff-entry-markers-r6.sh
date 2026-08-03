#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source "$(dirname "$0")/env.sh"

MODULE="$HOTDOG_ROOT/helpers/r6-ram-marker-reader/hotdog_r6_ram_marker_reader.ko"
MODULE_SHA=6982ce766ae7fc8c391dc0f5ecaedbc5969f669c55d83770dc570aef2ae31c54
MODULE_NAME=hotdog_r6_ram_marker_reader
EXPECTED_KERNEL=4.14.357-openela-perf
SERIAL="${ANDROID_SERIAL:-$HOTDOG_TARGET_SERIAL}"

stamp="$(date +%F-%H%M%S)"
run_dir="$HOTDOG_LOG_ROOT/clearstaff-entry-markers-r6-$stamp"
mkdir -p "$run_dir"
exec > >(tee "$run_dir/run.log") 2>&1

die() {
	printf 'ERROR: %s\n' "$1" >&2
	exit "${2:-1}"
}

ssh_base() {
	sshpass -p "$HOTDOG_PMOS_PASSWORD" ssh \
		-o StrictHostKeyChecking=no \
		-o UserKnownHostsFile="$run_dir/known_hosts" \
		-o ConnectTimeout=5 \
		-o PreferredAuthentications=password \
		-o PubkeyAuthentication=no \
		"$HOTDOG_PMOS_USER@$HOTDOG_PMOS_HOST" "$@"
}

scp_base() {
	sshpass -p "$HOTDOG_PMOS_PASSWORD" scp \
		-o StrictHostKeyChecking=no \
		-o UserKnownHostsFile="$run_dir/known_hosts" \
		-o ConnectTimeout=5 \
		-o PreferredAuthentications=password \
		-o PubkeyAuthentication=no \
		"$@"
}

hotdog_require_target_serial
hotdog_require_pmos_password
for command in sha256sum ssh sshpass scp; do
	command -v "$command" >/dev/null 2>&1 || die "Missing command: $command" 127
done

[ -s "$MODULE" ] || die "Missing reader module: $MODULE" 2
actual_sha="$(sha256sum "$MODULE" | awk '{ print $1 }')"
[ "$actual_sha" = "$MODULE_SHA" ] ||
	die "Reader module SHA256 mismatch: expected $MODULE_SHA, got $actual_sha" 3

ssh_base 'printf "KERNEL="; uname -r; printf "CMDLINE="; cat /proc/cmdline; sudo -n true' \
	> "$run_dir/r6-attestation.txt"
grep -qx "KERNEL=$EXPECTED_KERNEL" "$run_dir/r6-attestation.txt" ||
	die "The reachable SSH system is not verified R6" 4
grep -q "androidboot.serialno=$SERIAL" "$run_dir/r6-attestation.txt" ||
	die "R6 command line does not contain the pinned target serial" 4

remote_module="/tmp/$MODULE_NAME.ko"
scp_base "$MODULE" "$HOTDOG_PMOS_USER@$HOTDOG_PMOS_HOST:$remote_module"
ssh_base "sudo -n rmmod $MODULE_NAME 2>/dev/null || true; sudo -n insmod $remote_module; sudo -n dmesg | grep -E 'HOTDOG_(RAM_(MARKER|COMPACT)|PMSG_MARKER)' | tail -n 5; sudo -n rmmod $MODULE_NAME; rm -f $remote_module" \
	| tee "$run_dir/markers.txt"

[ "$(grep -c 'HOTDOG_RAM_MARKER slot=' "$run_dir/markers.txt" || true)" -eq 3 ] ||
	die "Did not recover exactly three marker records" 5
grep -q 'HOTDOG_RAM_COMPACT valid=' "$run_dir/markers.txt" ||
	die "Did not recover the compact marker record" 5
grep -q 'HOTDOG_PMSG_MARKER valid=' "$run_dir/markers.txt" ||
	die "Did not recover the pmsg marker record" 5

printf 'Marker capture: %s\n' "$run_dir/markers.txt"
