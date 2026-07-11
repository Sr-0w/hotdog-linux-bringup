#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/env.sh"

bridge_dir="$HOTDOG_ROOT/images/pmos-experiments/2026-07-11-130500-lineage414-r5-kexec-fbwait-nopaint-acm-rootwatchdog"
bridge_image="$bridge_dir/boot-noefi-pmosdtb-watchdog-300s.img"
bridge_apk="$HOTDOG_ROOT/pmbootstrap-work/packages/edge/aarch64/linux-oneplus-hotdog-lineage414-4.14.357_git20260703-r5.apk"
bridge_kernel="$HOTDOG_ROOT/build/apk-extract/linux-oneplus-hotdog-lineage414-r5/boot/vmlinuz"
bridge_dtb="$HOTDOG_ROOT/build/apk-extract/linux-oneplus-hotdog-lineage414-r5/boot/dtbs/qcom/sm8150-oneplus-hotdog.dtb"
r4_dtb="$HOTDOG_ROOT/build/apk-extract/linux-oneplus-hotdog-lineage414-r4/boot/dtbs/qcom/sm8150-oneplus-hotdog.dtb"
r4_dir="$HOTDOG_ROOT/images/pmos-experiments/2026-07-10-073742-lineage414-r4-simplefb-nomap-ttykmsg-visibletty-prompt-verbose-acm-rootwatchdog"
r4_listing="$r4_dir/initramfs-watchdog-contents.txt"

psci_kernel_dir="$HOTDOG_ROOT/build/experiments/2026-07-10-172000-mainline617-psci-entry-reset-kernel"
psci_boot_dir="$HOTDOG_ROOT/images/pmos-experiments/2026-07-10-172100-mainline617-psci-entry-reset-stockdtbpack-fastbootboot"
psci_image="$psci_boot_dir/boot-noefi-pmosdtb-watchdog-420s.img"

mainline_image="$HOTDOG_ROOT/build/experiments/2026-07-09-224000-mainline617-pstore-ramoops-kernel/Image"
mainline_dtb="$HOTDOG_ROOT/images/pmos-experiments/2026-07-09-014500-mainline617-external-appenddtb-header0-watchdog60/components/sm8150-oneplus-hotdog.dtb"
kexec_binary="$HOTDOG_ROOT/tools/aarch64/kexec-tools-2.0.32-r2/usr/sbin/kexec"
reboot_helper="$HOTDOG_ROOT/build/hotdog-reboot-mode-aarch64"
rootfs="$HOTDOG_ROOT/pmbootstrap-work/chroot_rootfs_oneplus-hotdog"
extract_ikconfig="$HOTDOG_ROOT/src/kernel/linux-mainline/scripts/extract-ikconfig"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

check_file() {
  [ -s "$1" ] || fail "missing or empty file: $1"
}

check_sha() {
  local file="$1"
  local expected="$2"
  local actual=""
  actual="$(sha256sum "$file" | awk '{ print $1 }')"
  [ "$actual" = "$expected" ] || fail "sha256 mismatch for $file: $actual"
  printf 'OK sha256 %s  %s\n' "$actual" "$file"
}

for file in \
  "$bridge_image" \
  "$bridge_apk" \
  "$bridge_kernel" \
  "$bridge_dtb" \
  "$bridge_dir/components/initramfs-watchdog.gz" \
  "$bridge_dir/initramfs-watchdog-contents.txt" \
  "$psci_kernel_dir/Image" \
  "$psci_kernel_dir/primary_entry.objdump.txt" \
  "$psci_image" \
  "$psci_boot_dir/components/kernel" \
  "$psci_boot_dir/components/dtb" \
  "$mainline_image" \
  "$mainline_dtb" \
  "$kexec_binary" \
  "$reboot_helper"; do
  check_file "$file"
done

check_sha "$bridge_image" "23fa53d382425e9414a2e2a4b6e10f42d59ce1d6623b7fa1fbebf21ffe0c8a50"
check_sha "$bridge_apk" "96427716f9b747b5e74821e000caf0a5ab2c4a2ffa60ec107ab355f9412534d1"
check_sha "$bridge_kernel" "e4aeafa8d3db6fe236b78cdb878576848b81996e1a96f53a0afc45072a13fb8d"
check_sha "$bridge_dtb" "a4d493f0d70414d508403a463202b0f324860467321e729e756dc120efb6c763"
check_sha "$bridge_dir/components/initramfs-watchdog.gz" "0fa76f009642df43bebb63a17dcafd2a07847ceca21a5073ace4a7886e185c1a"
check_sha "$psci_kernel_dir/Image" "6c7eb9f79c9c7e45bf0ebb67a71acd846e61a01b79e0213c7e5380a48be084ad"
check_sha "$psci_image" "dee513b2c2bf0a91d2a44ea8b972c9f330417bf3e13a154079520d587a4dcd94"
check_sha "$psci_boot_dir/components/dtb" "f3afd969891fa461afe3bf61711863e6be3ba462d47e93794af1455b03253572"
check_sha "$mainline_image" "48ac790a9f15dbf3e976557d1baee6a72b847fefed17fed9e700424d91e3fa83"
check_sha "$mainline_dtb" "44052506301f7fcad9725c77a98323ec283adf1159b7bee941e7ed2ac3447b49"
check_sha "$kexec_binary" "0e0524a41579c38a741ce53a2d44b77743135b2ada988d10e2ec3943f54f43f5"
check_sha "$reboot_helper" "045a3d9d696ddee6922e1ce506aeb82a77c261978ea6a3220fd114751952d711"

cmp -s "$bridge_dtb" "$r4_dtb" || fail "r5 DTB differs from validated r4 DTB"
cmp -s "$bridge_kernel" "$bridge_dir/components/kernel" || fail "r5 boot image does not contain the verified bridge kernel"
cmp -s "$bridge_dtb" "$bridge_dir/components/dtb" || fail "r5 boot image does not contain the verified bridge DTB"
cmp -s "$bridge_dir/initramfs-watchdog-contents.txt" "$r4_listing" ||
  fail "r5 initramfs contents differ from validated r4 listing"
cmp -s "$psci_kernel_dir/Image" "$psci_boot_dir/components/kernel" ||
  fail "PSCI boot image does not contain the verified PSCI kernel"
grep -q '^boot image header version: 2$' "$bridge_dir/unpack-watchdog.txt" || fail "r5 bridge boot header is not v2"
grep -q '^boot image header version: 2$' "$psci_boot_dir/unpack-watchdog.txt" || fail "PSCI boot header is not v2"
grep -q '^os version: 15\.0\.0$' "$psci_boot_dir/unpack-watchdog.txt" || fail "PSCI boot OS version changed"
bridge_cmdline="$(sed -n -e 's/^command line args: //p' -e 's/^additional command line args: //p' "$bridge_dir/unpack-watchdog.txt" | tr -d '\n')"
r4_cmdline="$(sed -n -e 's/^command line args: //p' -e 's/^additional command line args: //p' "$r4_dir/unpack-watchdog.txt" | tr -d '\n')"
[ "$bridge_cmdline" = "$r4_cmdline" ] || fail "r5 bridge cmdline differs from validated r4"

bridge_config="$($extract_ikconfig "$bridge_kernel")"
for option in \
  CONFIG_KEXEC=y \
  CONFIG_KEXEC_CORE=y \
  CONFIG_DEVMEM=y \
  CONFIG_RELOCATABLE=y \
  CONFIG_SMP=y \
  CONFIG_HOTPLUG_CPU=y \
  CONFIG_FB_SIMPLE=y \
  CONFIG_QCOM_WATCHDOG_V2=y; do
  grep -qx "$option" <<< "$bridge_config" || fail "bridge kernel lacks $option"
done

grep -q $'mov\tx0, #0x9' "$psci_kernel_dir/primary_entry.objdump.txt" || fail "PSCI function ID low word missing"
grep -q $'movk\tx0, #0x8400, lsl #16' "$psci_kernel_dir/primary_entry.objdump.txt" || fail "PSCI function ID high word missing"
grep -q $'smc\t#0' "$psci_kernel_dir/primary_entry.objdump.txt" || fail "PSCI SMC instruction missing"

file "$kexec_binary" | grep -q 'ARM aarch64' || fail "kexec-tools binary is not aarch64"
file "$reboot_helper" | grep -q 'ARM aarch64' || fail "reboot-mode helper is not aarch64"
file "$reboot_helper" | grep -q 'statically linked' || fail "reboot-mode helper is not static"
fdtget -t s "$mainline_dtb" / compatible | grep -q 'oneplus,hotdog' || fail "mainline DTB is not hotdog"

command -v qemu-aarch64 >/dev/null 2>&1 || fail "qemu-aarch64 is not installed"
set +e
qemu_helper_output="$(qemu-aarch64 "$reboot_helper" 2>&1)"
qemu_helper_status=$?
set -e
[ "$qemu_helper_status" -eq 2 ] || fail "reboot helper emulator guard returned $qemu_helper_status"
grep -q 'bootloader|recovery' <<< "$qemu_helper_output" || fail "reboot helper emulator guard output is wrong"

qemu_kexec_output="$(qemu-aarch64 \
  "$rootfs/lib/ld-musl-aarch64.so.1" \
  --library-path "$rootfs/usr/lib" \
  "$kexec_binary" \
  --version 2>&1)" || fail "kexec-tools failed under qemu-aarch64"
grep -q '^kexec-tools 2\.0\.32$' <<< "$qemu_kexec_output" || fail "unexpected emulated kexec-tools version"
qemu_kexec_help="$(qemu-aarch64 \
  "$rootfs/lib/ld-musl-aarch64.so.1" \
  --library-path "$rootfs/usr/lib" \
  "$kexec_binary" \
  --help 2>&1)" || fail "kexec-tools help failed under qemu-aarch64"
grep -q -- '--dtb=FILE' <<< "$qemu_kexec_help" || fail "emulated kexec-tools lacks ARM64 --dtb"
grep -q -- '--initrd=FILE' <<< "$qemu_kexec_help" || fail "emulated kexec-tools lacks ARM64 --initrd"
grep -q -- '--command-line=STRING' <<< "$qemu_kexec_help" || fail "emulated kexec-tools lacks ARM64 --command-line"
printf 'OK qemu-aarch64 reboot helper argument guard\n'
printf 'OK qemu-aarch64 %s with ARM64 DTB/initrd/cmdline options\n' "$qemu_kexec_output"

bash -n \
  "$HOTDOG_ROOT/scripts/test-lineage414-r5-kexec-bridge.sh" \
  "$HOTDOG_ROOT/scripts/test-mainline-via-kexec.sh" \
  "$HOTDOG_ROOT/scripts/test-next-mainline617-psci-entry-reset.sh" \
  "$HOTDOG_ROOT/scripts/build-hotdog-reboot-mode.sh" \
  "$HOTDOG_ROOT/scripts/reboot-pmos-to-bootloader.sh" \
  "$HOTDOG_ROOT/scripts/fetch-kexec-tools-aarch64.sh" \
  "$HOTDOG_ROOT/scripts/install-gentoo-qemu-aarch64-user.sh"

printf '\nAll offline checks passed. No phone command was executed.\n'
