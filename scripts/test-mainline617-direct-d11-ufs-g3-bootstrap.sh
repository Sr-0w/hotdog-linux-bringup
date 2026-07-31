#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source "$(dirname "$0")/env.sh"

BOOT_IMAGE="$HOTDOG_ROOT/images/pmos-experiments/2026-07-31-232651-mainline617-direct-native-ufs-g3-bootstrap/boot.img"
CANDIDATE_DTBO="$HOTDOG_ROOT/images/pmos-experiments/2026-07-31-014429-d7-mainline-native-ufs/dtbo_b-d7-ufs-gdsc-bridge-filtered-drop-fragment-46-drop-fragment-59-drop-fragment-60.img"
RESTORE_DTBO="$HOTDOG_ROOT/logs/partition-read-vbmeta-dtbo-clean-2026-07-08-230943/dtbo_b.img"
RESTORE_BOOT="$HOTDOG_ROOT/images/pmos-experiments/2026-07-12-234100-lineage414-r6-nowdog-kexec-fbwait-acm-rootwatchdog/boot-noefi-pmosdtb-watchdog-300s.img"
REBOOT_HELPER="$HOTDOG_ROOT/build/hotdog-reboot-mode-aarch64"
SOURCE_SLOT_SUFFIX="${HOTDOG_EXPECT_SOURCE_SLOT_SUFFIX:-_b}"
START_MODE="${HOTDOG_TEST_START_MODE:-pmos-ssh}"

BOOT_SHA=1d04ec69cfc06443da92eebe91f84f305d98c1e6bb77e1104a2b076b5ff2430e
CANDIDATE_DTBO_SHA=d23564d42c989c2b86f760937cb6ea8d570074b20b74bd8c0bc0b94d2ba0d8cd
RESTORE_DTBO_SHA=95a111deb5302d0fc677c3d58f880a049461ffcaba856c75471d2789040ae672
RESTORE_BOOT_SHA=e76c85a56cdbcc6ddd105844eb322cb854fb33b2b23077da12ff098adc8f2369
REBOOT_HELPER_SHA=045a3d9d696ddee6922e1ce506aeb82a77c261978ea6a3220fd114751952d711
EARLY_BREADCRUMB_PHYS=0x81c0f800

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
Usage: test-mainline617-direct-d11-ufs-g3-bootstrap.sh

Run the direct-mainline D11 storage experiment. Relative to D10, the DTB,
filtered DTBO, initramfs, command line, watchdogs, and rollback payloads are
unchanged. The kernel keeps the SM8150 G3 PCS calibration writes and limits
only oneplus,hotdog's initial Qualcomm UFS link to HS-G3 Rate B, matching the
known-working downstream bootstrap order. HOTDOG_UFS_* messages record the
controller revision, controller maximum gear, and actual PHY start gear in
ramoops. The candidate remains a diagnostic step; it does not yet implement
the downstream G3-to-G4 reinitialisation.

The default starts from the verified R6 postmarketOS SSH bridge on slot B.
Set HOTDOG_TEST_START_MODE=fastboot only when the phone is already in fastboot.
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

check_sha "D11 direct mainline image" "$BOOT_IMAGE" "$BOOT_SHA"
check_sha "D7 native-mainline UFS candidate dtbo_b" "$CANDIDATE_DTBO" "$CANDIDATE_DTBO_SHA"
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
		--expect-cmdline-token hotdog_rescue_watchdog_sec=120 \
		--expect-cmdline-token initramfs_async=0 \
		--expect-cmdline-token panic=0 \
		--expect-cmdline-token consoleblank=0 \
		--restore-after system --boot-wait 115 --poll 1 --fastboot-timeout 15 \
	--rescue-watch-timeout 604800 --rescue-watch-poll 1
test_status=$?
set -e

if lsusb -d 05c6:900e 2>/dev/null | grep -q .; then
	printf 'Qualcomm 900e detected; reading fixed and early breadcrumbs.\n'
	"$HOTDOG_ROOT/scripts/qualcomm-900e-autorescue.sh" inspect \
		--early-breadcrumb-address "$EARLY_BREADCRUMB_PHYS" || true
fi

exit "$test_status"
