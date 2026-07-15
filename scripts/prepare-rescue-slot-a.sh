#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source "$(dirname "$0")/env.sh"
# shellcheck disable=SC1091
source "$(dirname "$0")/phone-lock.sh"

RESCUE_BOOT="$HOTDOG_ROOT/images/pmos-experiments/2026-07-12-234100-lineage414-r6-nowdog-kexec-fbwait-acm-rootwatchdog/boot-noefi-pmosdtb-watchdog-300s.img"
RESCUE_DTBO="$HOTDOG_ROOT/logs/partition-read-vbmeta-dtbo-clean-2026-07-08-230943/dtbo_a.img"
REBOOT_HELPER="$HOTDOG_ROOT/build/hotdog-reboot-mode-aarch64"

RESCUE_BOOT_SHA=e76c85a56cdbcc6ddd105844eb322cb854fb33b2b23077da12ff098adc8f2369
RESCUE_DTBO_SHA=66dba793d7efc7016716afd0ef7ee2712170b72070fa8750eb610d3288a26d88
REBOOT_HELPER_SHA=045a3d9d696ddee6922e1ce506aeb82a77c261978ea6a3220fd114751952d711
EXPECTED_KERNEL=4.14.357-openela-perf
WAIT_SEC="${WAIT_SEC:-480}"
RESCUE_BOOT_SIZE="$(stat -c %s "$RESCUE_BOOT" 2>/dev/null || printf 0)"

stamp="$(date +%F-%H%M%S)"
run_dir="$HOTDOG_LOG_ROOT/prepare-rescue-slot-a-$stamp"
mkdir -p "$run_dir"
exec > >(tee "$run_dir/run.log") 2>&1

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die() { log "ERROR: $1"; exit "${2:-1}"; }

cleanup() {
	phone_lock_release || true
}
trap cleanup EXIT

check_sha() {
	local label="$1" file="$2" expected="$3" actual=""
	[ -s "$file" ] || die "Missing $label: $file" 2
	actual="$(sha256sum "$file" | awk '{ print $1 }')"
	[ "$actual" = "$expected" ] ||
		die "$label SHA256 mismatch: expected $expected, got $actual" 3
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

fastboot_do() {
	fastboot -s "$HOTDOG_TARGET_SERIAL" "$@"
}

get_fastboot_var() {
	local name="$1"
	fastboot_do getvar "$name" 2>&1 |
		sed -n "s/^[[:space:]]*${name}:[[:space:]]*//p" |
		tail -n 1
}

wait_for_rescue_ssh() {
	local deadline=$((SECONDS + WAIT_SEC))
	while [ "$SECONDS" -lt "$deadline" ]; do
		if ping -c 1 -W 1 "$HOTDOG_PMOS_HOST" >/dev/null 2>&1 &&
			ssh_base 'printf HOTDOG_RESCUE_SSH_OK' 2>/dev/null |
			grep -q '^HOTDOG_RESCUE_SSH_OK$'; then
			return 0
		fi
		sleep 2
	done
	return 1
}

if [ "${1:-}" = -h ] || [ "${1:-}" = --help ]; then
	cat <<'USAGE'
Usage: prepare-rescue-slot-a.sh

Back up the current slot-A boot assets, install the pinned R6 postmarketOS
rescue kernel and stock slot-A DTBO, boot slot A, and mark it successful only
after its kernel identity and slot suffix have been verified over SSH.

The phone must currently be running the known R6 postmarketOS bridge with SSH.
USAGE
	exit 0
fi

[ "$#" -eq 0 ] || die "This pinned rescue preparation accepts no options" 2
hotdog_require_pmos_password
hotdog_require_target_serial
[[ "$WAIT_SEC" =~ ^[0-9]+$ ]] && [ "$WAIT_SEC" -gt 0 ] ||
	die "WAIT_SEC must be a positive integer" 2

for command in adb awk base64 fastboot grep ping sed sha256sum ssh sshpass; do
	command -v "$command" >/dev/null 2>&1 || die "Missing command: $command" 127
done

check_sha "R6 rescue boot image" "$RESCUE_BOOT" "$RESCUE_BOOT_SHA"
check_sha "stock slot-A DTBO" "$RESCUE_DTBO" "$RESCUE_DTBO_SHA"
check_sha "R6 bootloader reboot helper" "$REBOOT_HELPER" "$REBOOT_HELPER_SHA"
[ "$RESCUE_BOOT_SIZE" -gt 0 ] || die "Could not determine R6 rescue image size" 2

phone_lock_acquire "prepare verified R6 rescue slot A" 0 ||
	die "Could not acquire phone-operation lock" 3

log "Run directory: $run_dir"
log "Validating the currently running source kernel"
source_boot_id="$(ssh_base 'cat /proc/sys/kernel/random/boot_id')"
source_kernel="$(ssh_base 'uname -r')"
source_cmdline="$(ssh_base 'cat /proc/cmdline')"
printf '%s\n' "$source_boot_id" > "$run_dir/source-boot-id.txt"
printf '%s\n' "$source_kernel" > "$run_dir/source-kernel.txt"
printf '%s\n' "$source_cmdline" > "$run_dir/source-cmdline.txt"
[ "$source_kernel" = "$EXPECTED_KERNEL" ] ||
	die "Expected R6 kernel $EXPECTED_KERNEL, got $source_kernel" 3
case " $source_cmdline " in
	*' androidboot.slot_suffix=_a '*|*' androidboot.slot_suffix=_b '*) ;;
	*) die "Running kernel has no proven Android slot suffix" 3 ;;
esac

log "Backing up the current slot-A boot image and DTBO"
ssh_base 'sudo -n dd if=/dev/disk/by-partlabel/boot_a bs=4M status=none' > "$run_dir/boot_a-before.img"
ssh_base 'sudo -n dd if=/dev/disk/by-partlabel/dtbo_a bs=4M status=none' > "$run_dir/dtbo_a-before.img"
sha256sum "$run_dir/boot_a-before.img" "$run_dir/dtbo_a-before.img" |
	tee "$run_dir/before-sha256.txt"

log "Requesting a verified R6-to-fastboot handoff"
slot_token="$(grep -o 'androidboot.slot_suffix=_[ab]' "$run_dir/source-cmdline.txt" | head -n 1)"
"$HOTDOG_ROOT/scripts/reboot-pmos-to-bootloader.sh" \
	--mode bootloader \
	--serial "$HOTDOG_TARGET_SERIAL" \
	--expected-source-boot-id "$source_boot_id" \
	--expected-source-kernel "$source_kernel" \
	--expected-source-cmdline-token "$slot_token" \
	--helper "$REBOOT_HELPER" \
	--helper-sha256 "$REBOOT_HELPER_SHA" \
	--phone-lock-fd "$PHONE_LOCK_FD"

product="$(get_fastboot_var product)"
unlocked="$(get_fastboot_var unlocked)"
is_userspace="$(get_fastboot_var is-userspace)"
printf '%s\n' "$product" > "$run_dir/fastboot-product.txt"
printf '%s\n' "$unlocked" > "$run_dir/fastboot-unlocked.txt"
printf '%s\n' "$is_userspace" > "$run_dir/fastboot-is-userspace.txt"
case "$product" in msmnile|hotdog) ;; *) die "Unexpected fastboot product: $product" 3 ;; esac
[ "$unlocked" = yes ] || die "Bootloader is not unlocked" 3
[ "$is_userspace" = no ] || die "Refusing to flash from userspace fastboot" 3

log "Installing the verified rescue pair on slot A"
fastboot_do flash dtbo_a "$RESCUE_DTBO" 2>&1 | tee "$run_dir/flash-dtbo-a.txt"
fastboot_do flash boot_a "$RESCUE_BOOT" 2>&1 | tee "$run_dir/flash-boot-a.txt"
fastboot_do set_active a 2>&1 | tee "$run_dir/set-active-a.txt"

for var in current-slot slot-retry-count:a slot-successful:a slot-unbootable:a; do
	get_fastboot_var "$var" | tee "$run_dir/fastboot-${var//:/-}-after-flash.txt"
done
[ "$(cat "$run_dir/fastboot-current-slot-after-flash.txt")" = a ] ||
	die "Fastboot did not select slot A" 3
[ "$(cat "$run_dir/fastboot-slot-unbootable-a-after-flash.txt")" = no ] ||
	die "Slot A is still marked unbootable" 3

log "Booting slot A for end-to-end rescue validation"
fastboot_do reboot 2>&1 | tee "$run_dir/fastboot-reboot-a.txt"
phone_lock_release || true
wait_for_rescue_ssh || die "R6 slot A did not expose SSH within ${WAIT_SEC}s" 4

log "Verifying the running slot-A rescue before marking it successful"
validated_kernel="$(ssh_base 'uname -r')"
validated_cmdline="$(ssh_base 'cat /proc/cmdline')"
printf '%s\n' "$validated_kernel" > "$run_dir/validated-kernel.txt"
printf '%s\n' "$validated_cmdline" > "$run_dir/validated-cmdline.txt"
[ "$validated_kernel" = "$EXPECTED_KERNEL" ] ||
	die "Slot A booted unexpected kernel: $validated_kernel" 4
case " $validated_cmdline " in
	*' androidboot.slot_suffix=_a '*) ;;
	*) die "Rescue boot did not originate from slot A" 4 ;;
esac

remote_hashes="$(ssh_base "sudo -n head -c $RESCUE_BOOT_SIZE /dev/disk/by-partlabel/boot_a | sha256sum; sudo -n sha256sum /dev/disk/by-partlabel/dtbo_a")"
printf '%s\n' "$remote_hashes" | tee "$run_dir/validated-partition-sha256.txt"
grep -q "^$RESCUE_BOOT_SHA " "$run_dir/validated-partition-sha256.txt" ||
	die "Running slot-A boot partition does not match pinned R6" 4
grep -q "^$RESCUE_DTBO_SHA " "$run_dir/validated-partition-sha256.txt" ||
	die "Running slot-A DTBO does not match the pinned stock image" 4

ssh_base 'sudo -n qbootctl -m a; sudo -n qbootctl' |
	tee "$run_dir/qbootctl-after-success.txt"
grep -A4 '^SLOT _a:' "$run_dir/qbootctl-after-success.txt" | grep -q 'Successful  : 1' ||
	die "qbootctl did not mark slot A successful" 4
grep -A4 '^SLOT _a:' "$run_dir/qbootctl-after-success.txt" | grep -q 'Bootable    : 1' ||
	die "qbootctl did not leave slot A bootable" 4

cat > "$run_dir/rescue-slot-a-ready" <<EOF
slot=a
kernel=$EXPECTED_KERNEL
boot_sha256=$RESCUE_BOOT_SHA
dtbo_sha256=$RESCUE_DTBO_SHA
validated_at=$(date --iso-8601=seconds)
EOF
log "Verified rescue slot A is ready"
