#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source "$(dirname "$0")/env.sh"

MODULE="$HOTDOG_ROOT/helpers/r6-ram-marker-reader/hotdog_r6_pmsg_marker_writer.ko"
MODULE_SHA=059d6a672561f8c759af5a034ac1d42095ab6b4c796528d4c8cdc252282bbb13
MODULE_NAME=hotdog_r6_pmsg_marker_writer
EXPECTED_KERNEL=4.14.357-openela-perf
SERIAL="${ANDROID_SERIAL:-$HOTDOG_TARGET_SERIAL}"

stamp="$(date +%F-%H%M%S)"
run_dir="$HOTDOG_LOG_ROOT/r6-pmsg-marker-test-$stamp"
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

[ -s "$MODULE" ] || die "Missing pmsg writer module: $MODULE" 2
actual_sha="$(sha256sum "$MODULE" | awk '{ print $1 }')"
[ "$actual_sha" = "$MODULE_SHA" ] ||
	die "Pmsg writer SHA256 mismatch: expected $MODULE_SHA, got $actual_sha" 3

ssh_base 'printf "KERNEL="; uname -r; printf "CMDLINE="; cat /proc/cmdline; sudo -n true' \
	> "$run_dir/r6-attestation.txt"
grep -qx "KERNEL=$EXPECTED_KERNEL" "$run_dir/r6-attestation.txt" ||
	die "The reachable SSH system is not verified R6" 4
grep -q "androidboot.serialno=$SERIAL" "$run_dir/r6-attestation.txt" ||
	die "R6 command line does not contain the pinned target serial" 4

remote_module="/tmp/$MODULE_NAME.ko"
scp_base "$MODULE" "$HOTDOG_PMOS_USER@$HOTDOG_PMOS_HOST:$remote_module"
ssh_base "sudo -n rmmod $MODULE_NAME 2>/dev/null || true; sudo -n insmod $remote_module; sudo -n dmesg | grep HOTDOG_PMSG_TEST | tail -n 1; sudo -n rmmod $MODULE_NAME; rm -f $remote_module" \
	| tee "$run_dir/writer.txt"

grep -q 'HOTDOG_PMSG_TEST written sig=43474244 start=16 size=16 magic=4d504448 build=00000001 stage=feed0002 stage_inv=0112fffd' \
	"$run_dir/writer.txt" || die "The pmsg test marker was not confirmed" 5

printf 'Pmsg marker test write: %s\n' "$run_dir/writer.txt"
