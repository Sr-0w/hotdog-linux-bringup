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
d1_dir="$HOTDOG_ROOT/images/pmos-experiments/2026-07-11-150002-mainline617-direct-repro-clean-c"
d1_avb_image="$d1_dir/boot.img"
d1_raw_image="$d1_dir/boot-mainline617-direct-d1.img"
d1_launcher="$HOTDOG_ROOT/scripts/test-mainline617-direct-d1.sh"
d1_newc_extractor="$HOTDOG_ROOT/scripts/extract-last-newc-member.py"
d1_pack_dir="$HOTDOG_ROOT/images/pmos-experiments/2026-07-11-150010-mainline617-direct-pack-clean"
d1_pack_avb_image="$d1_pack_dir/boot.img"
d1_pack_raw_image="$d1_pack_dir/boot-mainline617-direct-d1-pack.img"
d1_pack_launcher="$HOTDOG_ROOT/scripts/test-mainline617-direct-d1-pack.sh"
boot_b_tester="$HOTDOG_ROOT/scripts/test-boot-b-image.sh"
fastboot_boot_tester="$HOTDOG_ROOT/scripts/test-fastboot-boot-image.sh"
acm_collector="$HOTDOG_ROOT/scripts/collect-mainline-acm-window.sh"

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

check_size() {
  local file="$1"
  local expected="$2"
  local actual=""

  actual="$(stat -c %s "$file")"
  [ "$actual" = "$expected" ] || fail "size mismatch for $file: $actual"
  printf 'OK size %s  %s\n' "$actual" "$file"
}

require_text() {
  local label="$1"
  local file="$2"
  local text="$3"

  grep -Fq -- "$text" "$file" || fail "$label missing expected text in $file: $text"
}

validate_kernel_prefix_tester_guards() {
  local telnet_body=""

  bash -n "$boot_b_tester" "$fastboot_boot_tester"

  require_text "boot_b tester documents kernel-prefix guard" "$boot_b_tester" "--expect-kernel-prefix PREFIX"
  require_text "boot_b tester parses kernel-prefix guard" "$boot_b_tester" "--expect-kernel-prefix)"
  require_text "boot_b tester rejects empty kernel prefix" "$boot_b_tester" "--expect-kernel-prefix must not be empty"
  require_text "boot_b tester checks expected kernel prefix" "$boot_b_tester" '"$EXPECT_KERNEL_PREFIX"*)'
  require_text "boot_b tester reports kernel mismatch" "$boot_b_tester" "pmos-ssh-kernel-mismatch"
  require_text "boot_b tester rejects unchanged boot_id under guard" "$boot_b_tester" "pmos-ssh-unchanged-boot-id"
  require_text "boot_b tester returns nonzero for kernel guard failures" "$boot_b_tester" "return 5"
  require_text "boot_b tester treats telnet as diagnostic" "$boot_b_tester" "pmOS telnet is diagnostic only while strict SSH identity is required"
  require_text "boot_b tester requires SSH for guarded success" "$boot_b_tester" "was not verified by a fresh pmOS SSH probe"
  require_text "boot_b tester waits for rescue readiness" "$boot_b_tester" "wait_for_rescue_watcher_ready"
  require_text "boot_b tester captures target cmdline" "$boot_b_tester" "PMOS_CMDLINE="
  require_text "boot_b tester checks complete cmdline tokens" "$boot_b_tester" "cmdline_has_token"
  require_text "boot_b tester checks source kernel" "$boot_b_tester" "EXPECT_SOURCE_KERNEL_PREFIX"
  require_text "boot_b tester checks source cmdline" "$boot_b_tester" "EXPECT_SOURCE_CMDLINE_TOKENS"
  require_text "boot_b tester passes pinned restore hash" "$boot_b_tester" "--restore-boot-b-sha256"
  require_text "boot_b tester delays watchdog acknowledgement" "$boot_b_tester" "acknowledge_pmos_watchdog"
  telnet_body="$(sed -n '/^collect_pmos_telnet_logs()/,/^}/p' "$boot_b_tester")"
  if grep -Fq 'hotdog_rescue_watchdog.ok' <<< "$telnet_body"; then
    fail "telnet diagnostics still acknowledge the rescue watchdog"
  fi
  require_text "SSH flasher pins device serial" "$HOTDOG_ROOT/scripts/flash-boot-b-from-pmos-ssh.sh" "androidboot.serialno=\$expected_serial"
  require_text "SSH flasher pins hotdog project" "$HOTDOG_ROOT/scripts/flash-boot-b-from-pmos-ssh.sh" "androidboot.prjname=19801"
  require_text "SSH flasher validates boot_b PARTNAME" "$HOTDOG_ROOT/scripts/flash-boot-b-from-pmos-ssh.sh" 'partname" = "boot_b'
  require_text "rescue watcher publishes readiness" "$HOTDOG_ROOT/scripts/rescue-boot-b-when-visible.sh" "publish_ready"
  require_text "rescue watcher publishes restore hash" "$HOTDOG_ROOT/scripts/rescue-boot-b-when-visible.sh" "restore_sha256="
  require_text "rescue watcher revalidates restore hash" "$HOTDOG_ROOT/scripts/rescue-boot-b-when-visible.sh" "verify_restore_image_hash"

  require_text "fastboot tester documents kernel-prefix guard" "$fastboot_boot_tester" "--expect-kernel-prefix PREFIX"
  require_text "fastboot tester parses kernel-prefix guard" "$fastboot_boot_tester" "--expect-kernel-prefix)"
  require_text "fastboot tester checks expected kernel prefix" "$fastboot_boot_tester" '"$ssh_kernel" != "$EXPECTED_KERNEL_PREFIX"*'
  require_text "fastboot tester classifies bridge recovery" "$fastboot_boot_tester" "pmos-bridge-recovery"
  require_text "fastboot tester classifies unexpected kernel" "$fastboot_boot_tester" "pmos-unexpected-kernel"
  require_text "fastboot tester returns nonzero for kernel guard failures" "$fastboot_boot_tester" "return 5"
  printf 'OK kernel-prefix guards in boot_b and fastboot boot testers\n'
}

validate_d1_direct_launcher() {
  local effective_fb_probe=""

  bash -n "$d1_launcher"
  require_text "D1 launcher pins AVB image" "$d1_launcher" 'BOOT_IMAGE="$HOTDOG_ROOT/images/pmos-experiments/2026-07-11-150002-mainline617-direct-repro-clean-c/boot.img"'
  require_text "D1 launcher pins restore image" "$d1_launcher" 'RESTORE_IMAGE="$HOTDOG_ROOT/images/pmos-experiments/2026-07-11-130500-lineage414-r5-kexec-fbwait-nopaint-acm-rootwatchdog/boot-noefi-pmosdtb-watchdog-300s.img"'
  require_text "D1 launcher pins boot wait default" "$d1_launcher" 'BOOT_WAIT_SEC="${HOTDOG_D1_BOOT_WAIT_SEC:-540}"'
  require_text "D1 launcher enforces minimum wait" "$d1_launcher" 'HOTDOG_D1_BOOT_WAIT_SEC must be at least 480'
  require_text "D1 launcher hash-checks AVB image" "$d1_launcher" 'f8e83ae15cb016612433b8a2d800d828b025d56c76640a2ebb41a3061baf8994'
  require_text "D1 launcher hash-checks restore image" "$d1_launcher" '23fa53d382425e9414a2e2a4b6e10f42d59ce1d6623b7fa1fbebf21ffe0c8a50'
  require_text "D1 launcher requires pmOS password" "$d1_launcher" "hotdog_require_pmos_password"
  require_text "D1 launcher requires target serial" "$d1_launcher" "hotdog_require_target_serial"
  require_text "D1 launcher rejects unsupported options" "$d1_launcher" "Unsupported option for pinned D1 test"
  require_text "D1 launcher uses boot_b tester" "$d1_launcher" 'exec "$HOTDOG_ROOT/scripts/test-boot-b-image.sh"'
  require_text "D1 launcher starts from pmOS SSH" "$d1_launcher" "--from-pmos-ssh"
  require_text "D1 launcher prearms rescue watcher" "$d1_launcher" "--start-rescue-watcher"
  require_text "D1 launcher pins expected products" "$d1_launcher" '--expected-product "msmnile hotdog"'
  require_text "D1 launcher pins configured serial" "$d1_launcher" '--serial "$HOTDOG_TARGET_SERIAL"'
  require_text "D1 launcher requires bridge source kernel" "$d1_launcher" "--expect-source-kernel-prefix 4.14.357-openela-perf"
  require_text "D1 launcher requires source slot b" "$d1_launcher" "--expect-source-cmdline-token androidboot.slot_suffix=_b"
  require_text "D1 launcher enforces mainline kernel prefix" "$d1_launcher" "--expect-kernel-prefix 6.17.0-sm8150"
  require_text "D1 launcher requires unique wrapper marker" "$d1_launcher" "--expect-cmdline-token rdinit=/hotdog-mainline-wrapper"
  require_text "D1 launcher requires target slot b" "$d1_launcher" "--expect-cmdline-token androidboot.slot_suffix=_b"
  require_text "D1 launcher restores to system" "$d1_launcher" "--restore-after system"
  [ -f "$d1_newc_extractor" ] || fail "missing concatenated newc extractor: $d1_newc_extractor"
  effective_fb_probe="$(python3 "$d1_newc_extractor" "$d1_dir/components/ramdisk" hotdog_fb_test.sh)"
  grep -Fq 'wait-only mode' <<< "$effective_fb_probe" || fail "D1 effective framebuffer probe is not wait-only"
  if grep -Eq 'hotdog_fb_test_fill|color=(red|green|blue|white)' <<< "$effective_fb_probe"; then
    fail "D1 effective framebuffer probe still contains RGB paint code"
  fi
  printf 'OK D1 direct launcher format\n'
}

validate_acm_collector() {
  local output=""

  bash -n "$acm_collector"
  require_text "ACM collector documents self-test" "$acm_collector" "--self-test-pty"
  require_text "ACM collector opens tty read-only" "$acm_collector" "os.O_RDONLY | os.O_NOCTTY | os.O_NONBLOCK"
  require_text "ACM collector puts tty in raw mode" "$acm_collector" "tty.setraw(fd, termios.TCSANOW)"
  require_text "ACM collector clears host echo" "$acm_collector" "attrs[3] &= ~(termios.ECHO"
  require_text "ACM collector checks echo leak" "$acm_collector" "echo leaked back to master"
  require_text "ACM collector dispatches self-test" "$acm_collector" "python_tty_reader --self-test-pty"
  output="$(bash "$acm_collector" --self-test-pty)"
  grep -q '"pty_self_test": "ok"' <<< "$output" || fail "ACM collector --self-test-pty did not report success"
  printf 'OK ACM collector no-echo self-test %s\n' "$output"
}

validate_d1_pack_launcher() {
  bash -n "$d1_pack_launcher"
  require_text "D1-pack launcher pins AVB image" "$d1_pack_launcher" 'BOOT_IMAGE="$HOTDOG_ROOT/images/pmos-experiments/2026-07-11-150010-mainline617-direct-pack-clean/boot.img"'
  require_text "D1-pack launcher pins raw validation image" "$d1_pack_launcher" 'RAW_IMAGE="$HOTDOG_ROOT/images/pmos-experiments/2026-07-11-150010-mainline617-direct-pack-clean/boot-mainline617-direct-d1-pack.img"'
  require_text "D1-pack launcher hashes AVB image" "$d1_pack_launcher" "2f3bf9b7cde3b2d48a3cf4d6fe2fb2f92e210e1a6b1249505fa15be10c26b754"
  require_text "D1-pack launcher hashes raw image" "$d1_pack_launcher" "f72e8eab80d07fe265bfe5520228b3ff758d47980a2f0204f774b14d5314b1ac"
  require_text "D1-pack launcher requires configured serial" "$d1_pack_launcher" "hotdog_require_target_serial"
  require_text "D1-pack launcher requires bridge source" "$d1_pack_launcher" "--expect-source-kernel-prefix 4.14.357-openela-perf"
  require_text "D1-pack launcher requires target wrapper" "$d1_pack_launcher" "--expect-cmdline-token rdinit=/hotdog-mainline-wrapper"
  require_text "D1-pack launcher uses AVB image only" "$d1_pack_launcher" '--image "$BOOT_IMAGE"'
  printf 'OK D1-pack launcher format\n'
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
  "$reboot_helper" \
  "$d1_avb_image" \
  "$d1_raw_image" \
  "$d1_dir/SHA256SUMS" \
  "$d1_dir/MANIFEST.md" \
  "$d1_dir/avb-info.txt" \
  "$d1_launcher" \
  "$d1_pack_avb_image" \
  "$d1_pack_raw_image" \
  "$d1_pack_dir/MANIFEST.md" \
  "$d1_pack_launcher" \
  "$boot_b_tester" \
  "$fastboot_boot_tester" \
  "$acm_collector"; do
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
check_sha "$d1_avb_image" "f8e83ae15cb016612433b8a2d800d828b025d56c76640a2ebb41a3061baf8994"
check_sha "$d1_raw_image" "8eee58ec96bcaaba5563e1aed9c3a00ac4c41ac495bc9ca728a45aa0bcd56ae0"
check_size "$d1_avb_image" "100663296"
check_size "$d1_raw_image" "50298880"
check_sha "$d1_pack_avb_image" "2f3bf9b7cde3b2d48a3cf4d6fe2fb2f92e210e1a6b1249505fa15be10c26b754"
check_sha "$d1_pack_raw_image" "f72e8eab80d07fe265bfe5520228b3ff758d47980a2f0204f774b14d5314b1ac"
check_size "$d1_pack_avb_image" "100663296"
check_size "$d1_pack_raw_image" "59924480"
require_text "D1-pack manifest mode" "$d1_pack_dir/MANIFEST.md" 'DTB mode: `pack-entry-12`'
require_text "D1 SHA256SUMS raw entry" "$d1_dir/SHA256SUMS" "8eee58ec96bcaaba5563e1aed9c3a00ac4c41ac495bc9ca728a45aa0bcd56ae0  boot-mainline617-direct-d1.img"
require_text "D1 SHA256SUMS AVB entry" "$d1_dir/SHA256SUMS" "f8e83ae15cb016612433b8a2d800d828b025d56c76640a2ebb41a3061baf8994  boot.img"
require_text "D1 manifest raw output" "$d1_dir/MANIFEST.md" "Raw image: \`images/pmos-experiments/2026-07-11-150002-mainline617-direct-repro-clean-c/boot-mainline617-direct-d1.img\`"
require_text "D1 manifest AVB output" "$d1_dir/MANIFEST.md" "AVB image: \`images/pmos-experiments/2026-07-11-150002-mainline617-direct-repro-clean-c/boot.img\`"
require_text "D1 AVB info partition size" "$d1_dir/avb-info.txt" "Image size:               100663296 bytes"
require_text "D1 AVB info algorithm" "$d1_dir/avb-info.txt" "Algorithm:                NONE"
require_text "D1 AVB info partition" "$d1_dir/avb-info.txt" "Partition Name:        boot"
validate_d1_direct_launcher
validate_d1_pack_launcher
validate_kernel_prefix_tester_guards
validate_acm_collector

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
  "$HOTDOG_ROOT/scripts/test-mainline617-direct-d1.sh" \
  "$HOTDOG_ROOT/scripts/test-boot-b-image.sh" \
  "$HOTDOG_ROOT/scripts/test-fastboot-boot-image.sh" \
  "$HOTDOG_ROOT/scripts/collect-mainline-acm-window.sh" \
  "$HOTDOG_ROOT/scripts/build-hotdog-reboot-mode.sh" \
  "$HOTDOG_ROOT/scripts/reboot-pmos-to-bootloader.sh" \
  "$HOTDOG_ROOT/scripts/fetch-kexec-tools-aarch64.sh" \
  "$HOTDOG_ROOT/scripts/install-gentoo-qemu-aarch64-user.sh"

printf '\nAll offline checks passed. No phone command was executed.\n'
