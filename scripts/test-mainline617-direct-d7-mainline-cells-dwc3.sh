#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source "$(dirname "$0")/env.sh"

BOOT_IMAGE="$HOTDOG_ROOT/images/pmos-experiments/2026-07-30-193500-mainline617-direct-source-init2-dwc3-probe/boot.img"
CANDIDATE_DTBO="$HOTDOG_ROOT/images/pmos-experiments/2026-07-30-233100-d7-ufs-gdsc-mainline-cells/dtbo_b-d7-ufs-gdsc-bridge-filtered-drop-fragment-46.img"
RESTORE_DTBO="$HOTDOG_ROOT/logs/partition-read-vbmeta-dtbo-clean-2026-07-08-230943/dtbo_b.img"
RESTORE_BOOT="$HOTDOG_ROOT/images/pmos-experiments/2026-07-12-234100-lineage414-r6-nowdog-kexec-fbwait-acm-rootwatchdog/boot-noefi-pmosdtb-watchdog-300s.img"
REBOOT_HELPER="$HOTDOG_ROOT/build/hotdog-reboot-mode-aarch64"
SOURCE_SLOT_SUFFIX="${HOTDOG_EXPECT_SOURCE_SLOT_SUFFIX:-_b}"
START_MODE="${HOTDOG_TEST_START_MODE:-pmos-ssh}"

BOOT_SHA=fa26b3668d3fc043936d13dadca6b34dc56a1bbc54d0ea92243cd128ec3324c2
EARLY_BREADCRUMB_PHYS=0x81c0f800
CANDIDATE_DTBO_SHA=53af6ed402294ea23177103fd92c529490f87fc6c60996699484fe581e0fda4f
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
Usage: test-mainline617-direct-d7-mainline-cells-dwc3.sh

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
command-line parsing, and entry into the first `jump_init_2nd`. This candidate
sources `init_2nd.sh` in PID 1 to isolate the observed blocked second execve.
The sourced script uses a diagnostic udev bypass after the per-command
fork/exec candidate proved that the first `udevd` launch never returned. The
first bypass run reached 11/11 without exposing USB because the pmOS helper
soft-fails when prerequisites are absent. The USB prerequisite probe then
reached 8/11: configfs and libcomposite are available, but no UDC registered.
The first DWC3 trace reached 7/11 with D7 and exposed a malformed runtime
`/soc@0`: D7 replaced the mainline two-cell address and size format with the
downstream one-cell format. The D3 no-op control then returned to Fastboot
before the first kernel marker, proving that an empty selected overlay is not
a usable hardware baseline. This candidate changes only `dtbo_b`: it retains
D7's 57 remaining fragments, including the validated UFS supply bridge, while
dropping vendor `fragment@46`. That fragment only adds camera-flash nodes and
was solely responsible for changing `/soc@0` to the downstream one-cell
format. Offline application to this exact embedded DTB preserves the mainline
two-cell format and valid four-cell USB and UFS `reg` properties.
Cells 6-10 report diagnostic entry, the QCOM USB platform device, QCOM wrapper
binding, HS PHY binding, and DWC3 core binding. `consoleblank=0` keeps the
result visible for remote observation. A separate static supervisor uses a
monotonic 300-second deadline, requests
`RESTART2(bootloader)` directly, and keeps a hardware-safe 32-second APSS
fallback armed between periodic kicks. The rootfs success marker disarms that
fallback. The observation window includes both the logical deadline and the
hardware fallback interval.
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
check_sha "D7 mainline-cell candidate dtbo_b" "$CANDIDATE_DTBO" "$CANDIDATE_DTBO_SHA"
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
	--candidate-dtbo-b "$CANDIDATE_DTBO" \
		--candidate-dtbo-b-sha256 "$CANDIDATE_DTBO_SHA" \
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
		--expect-cmdline-token consoleblank=0 \
		--restore-after system --boot-wait 390 --poll 1 --fastboot-timeout 15 \
	--rescue-watch-timeout 604800 --rescue-watch-poll 1
test_status=$?
set -e

if lsusb -d 05c6:900e 2>/dev/null | grep -q .; then
	printf 'Qualcomm 900e detected; reading fixed and early breadcrumbs.\n'
	"$HOTDOG_ROOT/scripts/qualcomm-900e-autorescue.sh" inspect \
		--early-breadcrumb-address "$EARLY_BREADCRUMB_PHYS" || true
fi

exit "$test_status"
