#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source "$(dirname "$0")/env.sh"

BOOT_IMAGE="$HOTDOG_ROOT/images/pmos-experiments/2026-07-30-114100-mainline617-direct-udev-bounded-apss-wdt32-kicked/boot.img"
D7_DTBO="$HOTDOG_ROOT/images/pmos-experiments/2026-07-12-220500-d7-ufs-gdsc-bridge-dtbo/dtbo_b-d7-ufs-gdsc-bridge-filtered.img"
RESTORE_DTBO="$HOTDOG_ROOT/logs/partition-read-vbmeta-dtbo-clean-2026-07-08-230943/dtbo_b.img"
RESTORE_BOOT="$HOTDOG_ROOT/images/pmos-experiments/2026-07-12-234100-lineage414-r6-nowdog-kexec-fbwait-acm-rootwatchdog/boot-noefi-pmosdtb-watchdog-300s.img"
REBOOT_HELPER="$HOTDOG_ROOT/build/hotdog-reboot-mode-aarch64"
SOURCE_SLOT_SUFFIX="${HOTDOG_EXPECT_SOURCE_SLOT_SUFFIX:-_b}"
START_MODE="${HOTDOG_TEST_START_MODE:-pmos-ssh}"

BOOT_SHA=eaba526054d41001366a87a4b2e500d5b8cd54f459a2a696715a9df03fced565
EARLY_BREADCRUMB_PHYS=0x81c0f800
D7_DTBO_SHA=c7b22d3c2b8d9d09d95ee9ef8f3ead91dae2d7ec85e259c03b44bc3b2afa8978
RESTORE_DTBO_SHA=95a111deb5302d0fc677c3d58f880a049461ffcaba856c75471d2789040ae672
RESTORE_BOOT_SHA=e76c85a56cdbcc6ddd105844eb322cb854fb33b2b23077da12ff098adc8f2369
REBOOT_HELPER_SHA=045a3d9d696ddee6922e1ce506aeb82a77c261978ea6a3220fd114751952d711

die() { printf 'ERROR: %s\n' "$1" >&2; exit "${2:-1}"; }

check_sha() {
	local label="$1" file="$2" expected="$3" actual=""
	[ -s "$file" ] || die "Missing $label: $file" 2
	actual="$(sha256sum "$file" | awk '{ print $1 }')"
	[ "$actual" = "$expected" ] ||
		die "$label SHA256 mismatch: expected $expected, got $actual" 3
}

if [ "${1:-}" = -h ] || [ "${1:-}" = --help ]; then
	cat <<'USAGE'
Usage: test-mainline617-direct-autorescue-breadcrumb.sh

Test the K1 direct-boot path with a 32-second early APSS watchdog, a downstream
OnePlus fastboot restart marker, an Image-resident early-stage breadcrumb,
three pre-MMU framebuffer checkpoints, identity-mapped checkpoints through the
early virtual-address transition, and C-entry checkpoints that subdivide
`paging_init()` and `map_mem()`. The diagnostic band is cleared at entry, then
reuses the same proven pixels in yellow (slots 0-10), cyan (11-21), and magenta
(22-32). Early EL1 synchronous aborts and SErrors are
captured as a red or magenta marker plus ESR/FAR/PC framebuffer barcodes.
After the initcall trace, eleven large outlined cells replace the compact band
and fill sequentially through the end of kernel_init_freeable. A second row of
twelve larger cells then traces the post-init path. Cell 0 marks entry into the
global async wait; cell 1 means it completed normally. If that wait is still
blocked after 15 seconds, cell 11 fills instead, the first row becomes a
16-bit geometric code for the pending callback, init memory is deliberately
retained, and boot continues for diagnosis. Cells 2-10 trace initmem handling,
PTI, RCU, sysctl, rdinit entry, and successful kernel_execve.
Their state is readable by geometry without relying on camera color accuracy.
The diagnostic wrapper then paints four large static white bands at userspace
entry, before `/init`, after pmOS USB setup, and after mounting the rootfs.
The first two bands come from a static AArch64 wrapper with raw syscalls, while
three kernel bands bracket the initial EL1-to-EL0 return and the first EL0
synchronous event is captured as a framebuffer barcode. Eight large syscall
cells then report PID 1's first EL0 SVC entry/return, an initial openat,
successful framebuffer open, second SVC, framebuffer I/O, fallback execve,
and sustained userspace activity. A final row of eleven large cells traces
init entry, entry/return around `mount_proc_sys_dev`, watchdog arming,
command-line parsing, and entry into the first `jump_init_2nd`. The executed
`init_2nd.sh` reuses cells 6-10 for entry into `setup_udev`, return from
`udevd`, return from `udevadm trigger`, return from `udevadm settle`, and
return from `setup_usb_network`. Each udev command gets 15 seconds; a command
that remains blocked leaves its cell hollow and is detached so stage two can
continue toward USB and the rootfs. At stage one, a raw APSS watchdog is armed
for the hardware-safe maximum of 32 seconds and kicked once per second until
the 300-second logical deadline. It is disarmed only after the rootfs success
marker, so a fully wedged userspace still returns to Fastboot.
Later checkpoints retain the persistent per-initcall breadcrumb. If Qualcomm 900e
appears, the stage and raw counter samples are read automatically. The verified
R6 bridge and stock DTBO remain the rollback target. Set
HOTDOG_EXPECT_SOURCE_SLOT_SUFFIX to the exact running R6 slot (`_a` or `_b`);
the default is `_b`.

Set HOTDOG_TEST_START_MODE=fastboot only when the verified target is already
in bootloader fastboot. The default, pmOS-ssh, validates and hands off from a
healthy R6 userspace.
USAGE
	exit 0
fi

[ "$#" -eq 0 ] || die "This pinned diagnostic launcher accepts no options" 2
hotdog_require_pmos_password
hotdog_require_target_serial
case "$SOURCE_SLOT_SUFFIX" in
	_a|_b) ;;
	*) die "HOTDOG_EXPECT_SOURCE_SLOT_SUFFIX must be _a or _b" 2 ;;
esac
case "$START_MODE" in
	pmos-ssh|fastboot) ;;
	*) die "HOTDOG_TEST_START_MODE must be pmos-ssh or fastboot" 2 ;;
esac
[ -z "${ANDROID_SERIAL:-}" ] || [ "$ANDROID_SERIAL" = "$HOTDOG_TARGET_SERIAL" ] ||
	die "ANDROID_SERIAL differs from HOTDOG_TARGET_SERIAL" 2

check_sha "direct mainline diagnostic image" "$BOOT_IMAGE" "$BOOT_SHA"
check_sha "D7 candidate dtbo_b" "$D7_DTBO" "$D7_DTBO_SHA"
check_sha "stock restore dtbo_b" "$RESTORE_DTBO" "$RESTORE_DTBO_SHA"
check_sha "R6 restore boot_b" "$RESTORE_BOOT" "$RESTORE_BOOT_SHA"
check_sha "R6 bootloader reboot helper" "$REBOOT_HELPER" "$REBOOT_HELPER_SHA"

export HOTDOG_FLASH_BOOT_B_SSH_HELPER="$HOTDOG_ROOT/scripts/flash-boot-b-from-pmos-ssh.sh"
export HOTDOG_RESCUE_WATCHER_HELPER="$HOTDOG_ROOT/scripts/rescue-boot-b-when-visible.sh"

start_args=()
if [ "$START_MODE" = pmos-ssh ]; then
	start_args=(
		--from-pmos-ssh
		--expect-source-kernel-prefix 4.14.357-openela-perf
		--expect-source-cmdline-token watchdog_v2.enable=0
		--expect-source-cmdline-token "androidboot.slot_suffix=$SOURCE_SLOT_SUFFIX"
		--expect-source-cmdline-token "androidboot.serialno=$HOTDOG_TARGET_SERIAL"
	)
fi

test_status=125
set +e
"$HOTDOG_ROOT/scripts/test-boot-b-image.sh" \
	--image "$BOOT_IMAGE" --image-sha256 "$BOOT_SHA" \
	--dual-partition-transaction \
	--candidate-dtbo-b "$D7_DTBO" --candidate-dtbo-b-sha256 "$D7_DTBO_SHA" \
	--restore-dtbo-b "$RESTORE_DTBO" --restore-dtbo-b-sha256 "$RESTORE_DTBO_SHA" \
	--restore-boot-b "$RESTORE_BOOT" --restore-boot-b-sha256 "$RESTORE_BOOT_SHA" \
	--reboot-helper "$REBOOT_HELPER" --reboot-helper-sha256 "$REBOOT_HELPER_SHA" \
	--serial "$HOTDOG_TARGET_SERIAL" --expected-product 'msmnile hotdog' \
	"${start_args[@]}" --start-rescue-watcher --require-dirty-survival \
		--expect-kernel-prefix 6.17.0-sm8150 \
		--expect-cmdline-token rdinit=/hotdog-mainline-wrapper \
		--expect-cmdline-token hotdog_wrapper_settle_sec=0 \
		--expect-cmdline-token hotdog_rescue_watchdog_sec=300 \
		--expect-cmdline-token initramfs_async=0 \
		--restore-after system --boot-wait 240 --poll 1 --fastboot-timeout 15 \
	--rescue-watch-timeout 604800 --rescue-watch-poll 1
test_status=$?
set -e

if lsusb -d 05c6:900e 2>/dev/null | grep -q .; then
	printf 'Qualcomm 900e detected; reading fixed and early breadcrumbs.\n'
	"$HOTDOG_ROOT/scripts/qualcomm-900e-autorescue.sh" inspect \
		--early-breadcrumb-address "$EARLY_BREADCRUMB_PHYS" || true
fi

exit "$test_status"
