#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/env.sh"

KERNEL="$HOTDOG_ROOT/build/experiments/2026-07-09-224000-mainline617-pstore-ramoops-kernel/Image"
DTB="$HOTDOG_ROOT/build/experiments/2026-07-11-122000-mainline617-pmos-boot-dtb/sm8150-oneplus-hotdog-mainline-pmos-boot.dtb"
INITRAMFS="$HOTDOG_ROOT/build/experiments/2026-07-11-130000-mainline617-pmos-r5-wrapped-settle-nofbpaint/initramfs-pmos-wrapped.cpio"
RESTORE_IMAGE="$HOTDOG_ROOT/images/pmos-experiments/2026-07-11-130500-lineage414-r5-kexec-fbwait-nopaint-acm-rootwatchdog/boot-noefi-pmosdtb-watchdog-300s.img"

SETTLE_SEC="${HOTDOG_MAINLINE_SETTLE_SEC:-120}"
BOOT_WAIT_SEC="${BOOT_WAIT_SEC:-420}"

usage() {
	cat <<'USAGE'
Usage: test-mainline617-pmos-full.sh [options passed to test-mainline-via-kexec.sh]

Boot the hardware-validated postmarketOS rootfs under mainline 6.17 through
the persistent downstream 4.14 kexec bridge. The default 120-second settle
period is required by the current bring-up DT; 15 seconds was tested and is
not sufficient. Both initramfs stages keep the framebuffer probe wait-only and
never write RGB test frames over the kernel console.

Environment:
  HOTDOG_MAINLINE_SETTLE_SEC  Override the validated 120-second settle period.
  BOOT_WAIT_SEC               Override the 420-second SSH result timeout.

The kernel, DTB, initramfs, and restore image are hash-pinned below. Extra
arguments are forwarded after the pinned defaults for deliberate overrides.
USAGE
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
	usage
	exit 0
fi

case "$SETTLE_SEC" in
	''|*[!0-9]*) printf 'Invalid HOTDOG_MAINLINE_SETTLE_SEC: %s\n' "$SETTLE_SEC" >&2; exit 2 ;;
esac
case "$BOOT_WAIT_SEC" in
	''|*[!0-9]*) printf 'Invalid BOOT_WAIT_SEC: %s\n' "$BOOT_WAIT_SEC" >&2; exit 2 ;;
esac

check_sha() {
	local label="$1"
	local file="$2"
	local expected="$3"
	local actual

	[ -s "$file" ] || { printf 'Missing %s: %s\n' "$label" "$file" >&2; exit 2; }
	actual="$(sha256sum "$file" | awk '{ print $1 }')"
	[ "$actual" = "$expected" ] || {
		printf '%s hash mismatch: expected %s, got %s\n' "$label" "$expected" "$actual" >&2
		exit 3
	}
}

check_sha kernel "$KERNEL" 48ac790a9f15dbf3e976557d1baee6a72b847fefed17fed9e700424d91e3fa83
check_sha dtb "$DTB" cf63ae7f686bc76b912520f54e14c589b4c23c833069e45ba9097157a0665440
check_sha initramfs "$INITRAMFS" b7e939614b7cb34ecdd8639613d76b8adba39b069b6591e35c39bc4c57a37622
check_sha restore-image "$RESTORE_IMAGE" 23fa53d382425e9414a2e2a4b6e10f42d59ce1d6623b7fa1fbebf21ffe0c8a50

cmdline="initcall_blacklist=disp_cc_sm8250_driver_init,gpu_cc_sm8150_driver_init,video_cc_sm8150_driver_init,armv8_pmu_driver_init,qcom_cpufreq_hw_init initramfs_async=0 iommu.passthrough=1 arm-smmu.disable_bypass=0 rdinit=/hotdog-mainline-wrapper hotdog_wrapper_settle_sec=$SETTLE_SEC"

exec "$HOTDOG_ROOT/scripts/test-mainline-via-kexec.sh" \
	--execute \
	--allow-unpinned \
	--kernel "$KERNEL" \
	--dtb "$DTB" \
	--initramfs "$INITRAMFS" \
	--restore "$RESTORE_IMAGE" \
	--append-cmdline "$cmdline" \
	--boot-wait "$BOOT_WAIT_SEC" \
	"$@"
