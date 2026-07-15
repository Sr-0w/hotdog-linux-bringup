#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/env.sh"

PMOS_HOST="${PMOS_HOST:-$HOTDOG_PMOS_HOST}"
PMOS_USER="${PMOS_USER:-$HOTDOG_PMOS_USER}"
PMOS_PASSWORD="${PMOS_PASSWORD:-$HOTDOG_PMOS_PASSWORD}"
SERIAL="${ANDROID_SERIAL:-$HOTDOG_TARGET_SERIAL}"
TIMEOUT_SEC="${TIMEOUT_SEC:-604800}"
POLL_SEC="${POLL_SEC:-2}"
FASTBOOT_WAIT_SEC="${FASTBOOT_WAIT_SEC:-180}"
EXPECTED_KERNEL_PREFIX=""
EXPECTED_CMDLINE_TOKENS=()

usage() {
	cat <<'USAGE'
Usage: rescue-pmos-to-fastboot-when-visible.sh [options]

Wait for a specific postmarketOS boot to become reachable over SSH, verify its
kernel and command line, then request RESTART2(bootloader). This script does not
write partitions; a separately prearmed fastboot watcher may perform recovery.

Options:
  --host HOST       postmarketOS SSH host. Default: 172.16.42.1.
  --user USER       SSH user. Default: user.
  --serial SERIAL   Expected fastboot serial.
  --timeout SEC     Overall visibility timeout. Default: 604800 (7 days).
  --poll SEC        SSH poll interval. Default: 2.
  --fastboot-wait SEC
                    Bootloader visibility timeout after dispatch. Default: 180.
  --expected-kernel-prefix PREFIX
                    Required uname -r prefix.
  --expected-cmdline-token TOKEN
                    Required /proc/cmdline token; repeat as needed.
  -h, --help        Show this help.

The password is read from PMOS_PASSWORD or an ignored hotdog.env file. It is
intentionally not accepted as a command-line argument.
USAGE
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--host) PMOS_HOST="$2"; shift ;;
		--user) PMOS_USER="$2"; shift ;;
		--serial) SERIAL="$2"; shift ;;
		--timeout) TIMEOUT_SEC="$2"; shift ;;
		--poll) POLL_SEC="$2"; shift ;;
		--fastboot-wait) FASTBOOT_WAIT_SEC="$2"; shift ;;
		--expected-kernel-prefix) EXPECTED_KERNEL_PREFIX="$2"; shift ;;
		--expected-cmdline-token) EXPECTED_CMDLINE_TOKENS+=("$2"); shift ;;
		-h|--help) usage; exit 0 ;;
		*) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
	esac
	shift
done

stamp="$(date +%F-%H%M%S)"
run_dir="$HOTDOG_LOG_ROOT/rescue-pmos-to-fastboot-$stamp"
mkdir -p "$run_dir"
exec > >(tee "$run_dir/run.log") 2>&1

log() {
	printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

die() {
	log "ERROR: $1"
	exit "${2:-1}"
}

validate_positive_integer() {
	local name="$1"
	local value="$2"
	[[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -gt 0 ] ||
		die "$name must be a positive integer" 2
}

ssh_probe() {
	sshpass -p "$PMOS_PASSWORD" ssh \
		-o StrictHostKeyChecking=no \
		-o UserKnownHostsFile="$run_dir/known_hosts" \
		-o ConnectTimeout=2 \
		-o ConnectionAttempts=1 \
		-o PreferredAuthentications=password \
		-o PubkeyAuthentication=no \
		"$PMOS_USER@$PMOS_HOST" \
		'printf "boot_id="; cat /proc/sys/kernel/random/boot_id; printf "kernel="; uname -r; printf "cmdline="; cat /proc/cmdline'
}

identity_matches() {
	local kernel="$1"
	local cmdline="$2"
	local token=""

	[[ "$kernel" == "$EXPECTED_KERNEL_PREFIX"* ]] || return 1
	for token in "${EXPECTED_CMDLINE_TOKENS[@]}"; do
		case " $cmdline " in
			*" $token "*) ;;
			*) return 1 ;;
		esac
	done
}

main() {
	local deadline=0
	local identity=""
	local boot_id=""
	local kernel=""
	local cmdline=""
	local token=""
	local helper_sha=""
	local last_status=0
	local -a reboot_args=()

	[ -n "$PMOS_PASSWORD" ] || die "Set PMOS_PASSWORD in the environment or hotdog.env" 2
	[ -n "$SERIAL" ] || die "Set ANDROID_SERIAL or use --serial" 2
	[ -n "$EXPECTED_KERNEL_PREFIX" ] || die "--expected-kernel-prefix is required" 2
	[ "${#EXPECTED_CMDLINE_TOKENS[@]}" -gt 0 ] || die "At least one --expected-cmdline-token is required" 2
	validate_positive_integer TIMEOUT_SEC "$TIMEOUT_SEC"
	validate_positive_integer POLL_SEC "$POLL_SEC"
	validate_positive_integer FASTBOOT_WAIT_SEC "$FASTBOOT_WAIT_SEC"

	for command in ssh sshpass sed sha256sum; do
		command -v "$command" >/dev/null 2>&1 || die "Missing command: $command" 127
	done
	[ -x "$HOTDOG_ROOT/scripts/reboot-pmos-to-bootloader.sh" ] ||
		die "Missing reboot helper script" 127
	[ -s "$HOTDOG_ROOT/build/hotdog-reboot-mode-aarch64" ] ||
		die "Build the aarch64 reboot helper first" 127

	helper_sha="$(sha256sum "$HOTDOG_ROOT/build/hotdog-reboot-mode-aarch64" | sed 's/[[:space:]].*//')"
	log "Run directory: $run_dir"
	log "Waiting for verified pmOS SSH at $PMOS_USER@$PMOS_HOST"
	log "Expected kernel prefix: $EXPECTED_KERNEL_PREFIX"
	log "Expected cmdline tokens: ${EXPECTED_CMDLINE_TOKENS[*]}"

	deadline=$((SECONDS + TIMEOUT_SEC))
	while [ "$SECONDS" -lt "$deadline" ]; do
		if identity="$(ssh_probe 2>"$run_dir/ssh-last.err")"; then
			printf '%s\n' "$identity" > "$run_dir/identity-last.txt"
			boot_id="$(printf '%s\n' "$identity" | sed -n 's/^boot_id=//p')"
			kernel="$(printf '%s\n' "$identity" | sed -n 's/^kernel=//p')"
			cmdline="$(printf '%s\n' "$identity" | sed -n 's/^cmdline=//p')"
			if [ -n "$boot_id" ] && identity_matches "$kernel" "$cmdline"; then
				log "Verified pmOS boot: boot_id=$boot_id kernel=$kernel"
				reboot_args=(
					--host "$PMOS_HOST"
					--user "$PMOS_USER"
					--serial "$SERIAL"
					--wait "$FASTBOOT_WAIT_SEC"
					--expected-source-boot-id "$boot_id"
					--expected-source-kernel "$kernel"
					--helper-sha256 "$helper_sha"
				)
				for token in "${EXPECTED_CMDLINE_TOKENS[@]}"; do
					reboot_args+=(--expected-source-cmdline-token "$token")
				done
				if PMOS_PASSWORD="$PMOS_PASSWORD" \
					"$HOTDOG_ROOT/scripts/reboot-pmos-to-bootloader.sh" "${reboot_args[@]}"; then
					log "Bootloader reboot confirmed"
					return 0
				fi
				log "Reboot dispatch did not confirm fastboot; continuing to watch"
			else
				log "SSH answered, but kernel/cmdline identity was not accepted"
			fi
		fi

		if [ $((SECONDS - last_status)) -ge 30 ]; then
			log "Still waiting for the verified pmOS boot"
			last_status=$SECONDS
		fi
		sleep "$POLL_SEC"
	done

	die "Timed out waiting for verified pmOS SSH" 4
}

main "$@"
