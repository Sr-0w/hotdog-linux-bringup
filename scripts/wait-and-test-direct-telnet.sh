#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/env.sh"

SERIAL="${ANDROID_SERIAL:-b6bd2252}"
IMAGE="${IMAGE:-$HOTDOG_ROOT/images/pmos-experiments/2026-07-08-235800-stockkernel-pmosramdisk-direct-telnet-dualport-rootwatchdog/boot-stockkernel-pmosramdisk-direct-telnet-dualport-rootwatchdog-600s-stockos-avb.img}"
RESTORE_IMAGE="${RESTORE_IMAGE:-$HOTDOG_STABLE_PMOS_BOOT_B}"
BOOT_WAIT_SEC="${BOOT_WAIT_SEC:-720}"
POLL_SEC="${POLL_SEC:-2}"
WAIT_SEC="${WAIT_SEC:-1800}"
FASTBOOT_TIMEOUT_SEC="${FASTBOOT_TIMEOUT_SEC:-12}"

log() {
	printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

adb_recovery_present() {
	adb devices | awk -v s="$SERIAL" '$1 == s && $2 == "recovery" { found=1 } END { exit found ? 0 : 1 }'
}

fastboot_present() {
	fastboot devices | awk -v s="$SERIAL" '$1 == s { found=1 } END { exit found ? 0 : 1 }'
}

main() {
	[ -s "$IMAGE" ] || { log "missing image: $IMAGE"; exit 2; }
	[ -s "$RESTORE_IMAGE" ] || { log "missing restore image: $RESTORE_IMAGE"; exit 2; }

	log "Waiting for fastboot/recovery to run direct-telnet test"
	log "Serial: $SERIAL"
	log "Image: $IMAGE"

	local deadline=$((SECONDS + WAIT_SEC))
	local last_status=0
	while [ "$SECONDS" -lt "$deadline" ]; do
		if fastboot_present; then
			log "fastboot detected; launching direct-telnet test"
			exec "$HOTDOG_ROOT/scripts/test-boot-b-image.sh" \
				--serial "$SERIAL" \
				--image "$IMAGE" \
				--restore-boot-b "$RESTORE_IMAGE" \
				--boot-wait "$BOOT_WAIT_SEC" \
				--poll "$POLL_SEC" \
				--fastboot-timeout "$FASTBOOT_TIMEOUT_SEC"
		fi

		if adb_recovery_present; then
			log "recovery detected; launching direct-telnet test"
			exec "$HOTDOG_ROOT/scripts/test-boot-b-image.sh" \
				--serial "$SERIAL" \
				--image "$IMAGE" \
				--restore-boot-b "$RESTORE_IMAGE" \
				--boot-wait "$BOOT_WAIT_SEC" \
				--poll "$POLL_SEC" \
				--fastboot-timeout "$FASTBOOT_TIMEOUT_SEC"
		fi

		if [ $((SECONDS - last_status)) -ge 30 ]; then
			if ping -c 1 -W 1 172.16.42.1 >/dev/null 2>&1; then
				log "still waiting (pmOS ping)"
			else
				log "still waiting"
			fi
			last_status=$SECONDS
		fi
		sleep "$POLL_SEC"
	done

	log "timed out waiting for fastboot/recovery"
	exit 1
}

main "$@"
