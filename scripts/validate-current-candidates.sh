#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/env.sh"

usage() {
  cat <<'USAGE'
Usage: validate-current-candidates.sh [--historical-rgb-control NAME]

Validate the locally prepared hotdog boot candidates without using adb,
fastboot, SSH, USB reset, or any phone command.

Checks:
  - current r5 no-paint wrapper image/restore paths resolve and exist
  - current r5 cmdline keeps the expected console/fbcon/debug args
  - current r5 initramfs framebuffer helper is wait-only and has no RGB fill
  - selected Android DTB pack entry 12 contains the hotdog simplefb wiring
  - generated initramfs/rootfs helper scripts pass shell syntax checks
  - pinned D1/D1-pack artifacts, launchers, SSH identity guards, and ACM collector

Optional historical RGB controls, validated only when explicitly named:
  fbcon-only, r4-fbwait, r4-ttykmsg, splash-ttykmsg, fbtest-pstore,
  simplefb-shell
USAGE
}

historical_rgb_control=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --historical-rgb-control)
      [ "$#" -ge 2 ] || {
        usage >&2
        exit 2
      }
      historical_rgb_control="$2"
      shift 2
      ;;
    --historical-rgb-control=*)
      historical_rgb_control="${1#*=}"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      printf '[validate-current-candidates] ERROR: unknown argument: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

log() {
  printf '[validate-current-candidates] %s\n' "$*"
}

fail() {
  printf '[validate-current-candidates] ERROR: %s\n' "$*" >&2
  exit 1
}

require_file() {
  local path="$1"
  [ -f "$path" ] || fail "missing file: $path"
}

expand_hotdog_path() {
  local path="$1"
  path="${path//\$HOTDOG_STABLE_PMOS_BOOT_B/$HOTDOG_STABLE_PMOS_BOOT_B}"
  path="${path//\$HOTDOG_ROOT/$HOTDOG_ROOT}"
  path="${path//\$HOTDOG_LOG_ROOT/$HOTDOG_LOG_ROOT}"
  printf '%s\n' "$path"
}

wrapper_value() {
  local wrapper="$1"
  local key="$2"
  awk -F'"' -v key="$key" '$0 ~ "^" key "=" { print $2; exit }' "$wrapper"
}

check_cmdline_word() {
  local cmdline="$1"
  local word="$2"
  case " $cmdline " in
    *" $word "*) ;;
    *) fail "cmdline missing expected word: $word" ;;
  esac
}

check_sha() {
  local label="$1"
  local path="$2"
  local expected="$3"
  local actual=""

  require_file "$path"
  actual="$(sha256sum "$path" | awk '{ print $1 }')"
  [ "$actual" = "$expected" ] ||
    fail "$label sha256 mismatch for $path: expected $expected, got $actual"
  log "$label sha256 OK: $actual"
}

check_size() {
  local label="$1"
  local path="$2"
  local expected="$3"
  local actual=""

  require_file "$path"
  actual="$(stat -c %s "$path")"
  [ "$actual" = "$expected" ] ||
    fail "$label size mismatch for $path: expected $expected, got $actual"
  log "$label size OK: $actual"
}

require_text() {
  local label="$1"
  local path="$2"
  local text="$3"

  require_file "$path"
  grep -Fq -- "$text" "$path" || fail "$label missing expected text in $path: $text"
}

require_wrapper_restore_pointer() {
  local label="$1"
  local wrapper="$2"
  local restore_ref=""

  restore_ref="$(wrapper_value "$wrapper" restore)"
  [ "$restore_ref" = '$HOTDOG_STABLE_PMOS_BOOT_B' ] ||
    fail "$label restore pointer must be HOTDOG_STABLE_PMOS_BOOT_B, got: ${restore_ref:-missing}"
  log "$label restore pointer uses HOTDOG_STABLE_PMOS_BOOT_B"
}

historical_rgb_wrapper_path() {
  local name="$1"

  case "$name" in
    fbcon-only) printf '%s\n' "$HOTDOG_ROOT/scripts/test-lineage414-fbcon-only.sh" ;;
    r4-fbwait) printf '%s\n' "$HOTDOG_ROOT/scripts/test-lineage414-r4-verbose-fbwait.sh" ;;
    r4-ttykmsg) printf '%s\n' "$HOTDOG_ROOT/scripts/test-lineage414-r4-verbose-ttykmsg.sh" ;;
    splash-ttykmsg) printf '%s\n' "$HOTDOG_ROOT/scripts/test-lineage414-splash-ttykmsg.sh" ;;
    fbtest-pstore) printf '%s\n' "$HOTDOG_ROOT/scripts/test-next-lineage414-fbtest-pstore.sh" ;;
    simplefb-shell) printf '%s\n' "$HOTDOG_ROOT/scripts/test-next-lineage414-simplefb-shell.sh" ;;
    *)
      fail "unknown historical RGB control '$name'; expected one of: fbcon-only r4-fbwait r4-ttykmsg splash-ttykmsg fbtest-pstore simplefb-shell"
      ;;
  esac
}

image_dir_from_wrapper() {
  local wrapper="$1"
  local image_ref=""
  local image=""

  image_ref="$(wrapper_value "$wrapper" image)"
  image="$(expand_hotdog_path "$image_ref")"
  require_file "$image"
  dirname "$image"
}

require_rgb_capable_image() {
  local label="$1"
  local dir="$2"
  local helper="$dir/initramfs-tree/hotdog_fb_test.sh"

  require_file "$helper"
  if ! grep -Eq 'hotdog_fb_test_fill|red\)|green\)|blue\)' "$helper"; then
    fail "$label was expected to be RGB-capable, but no legacy fill/color code was found"
  fi
}

validate_historical_rgb_control() {
  local name="$1"
  local wrapper=""
  local dir=""

  [ -n "$name" ] || return 0
  wrapper="$(historical_rgb_wrapper_path "$name")"
  require_file "$wrapper"
  bash -n "$wrapper"
  require_text "$name wrapper requires historical RGB opt-in" "$wrapper" "HOTDOG_ALLOW_HISTORICAL_RGB"
  require_text "$name wrapper explains refusal" "$wrapper" "refusing to run a historical RGB-capable framebuffer test image"
  require_text "$name wrapper names legacy fill code" "$wrapper" "legacy /hotdog_fb_test.sh RGB fill code"
  require_text "$name wrapper points to no-paint bridge" "$wrapper" "test-lineage414-r5-kexec-bridge.sh"
  require_wrapper_restore_pointer "$name historical wrapper" "$wrapper"
  dir="$(image_dir_from_wrapper "$wrapper")"
  require_rgb_capable_image "$name historical image" "$dir"
  log "historical RGB control validated by explicit request: $name"
}

validate_r5_no_paint_framebuffer_helper() {
  local dir="$1"
  local helper="$dir/initramfs-tree/hotdog_fb_test.sh"
  local bad="$tmpdir/r5-rgb-fill-grep.txt"

  require_file "$helper"
  /bin/sh -n "$helper"
  require_text "r5 framebuffer helper is wait-only" "$helper" "wait-only mode"
  if grep -En 'hotdog_fb_test_fill|hotdog_fb_test_make_chunk|red\)|green\)|blue\)|white\)|painting .*color=|HOTDOG_FB_TEST_MODE|dd if="\$chunk"|> "\$dev"' "$helper" > "$bad"; then
    sed -n '1,120p' "$bad" >&2
    fail "r5 no-paint framebuffer helper contains RGB fill/color code"
  fi
  log "r5 framebuffer helper is wait-only and has no RGB fill/color code"
}

validate_kernel_prefix_tester_guards() {
  local telnet_body=""
  local dtbo_restore_body=""
  local ensure_bootloader_body=""
  local boot_b_tester="$HOTDOG_ROOT/scripts/test-boot-b-image.sh"
  local fastboot_tester="$HOTDOG_ROOT/scripts/test-fastboot-boot-image.sh"
  local ssh_flasher="$HOTDOG_ROOT/scripts/flash-boot-b-from-pmos-ssh.sh"
  local rescue_watcher="$HOTDOG_ROOT/scripts/rescue-boot-b-when-visible.sh"

  require_file "$boot_b_tester"
  require_file "$fastboot_tester"
  require_file "$ssh_flasher"
  require_file "$rescue_watcher"
  bash -n "$boot_b_tester" "$fastboot_tester" "$ssh_flasher" "$rescue_watcher"

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
  require_text "boot_b tester atomically binds strict identity and ACK" "$boot_b_tester" "pmos_ssh_probe_and_ack_strict"
  require_text "boot_b tester emits atomic identity ACK marker" "$boot_b_tester" "HOTDOG_ATOMIC_IDENTITY_ACK=ok"
  require_text "boot_b tester requires atomic ACK before strict success" "$boot_b_tester" 'PMOS_PROBE_ATOMIC_ACKED" -eq 1'
  require_text "boot_b tester rejects dirty policy without watcher" "$boot_b_tester" \
    "Dirty-survival policy requires --start-rescue-watcher before any phone access"
  telnet_body="$(sed -n '/^collect_pmos_telnet_logs()/,/^}/p' "$boot_b_tester")"
  if grep -Fq 'hotdog_rescue_watchdog.ok' <<< "$telnet_body"; then
    fail "telnet diagnostics still acknowledge the rescue watchdog"
  fi
  require_text "rescue watcher publishes readiness" "$rescue_watcher" "publish_ready"
  require_text "rescue watcher publishes restore hash" "$rescue_watcher" "restore_sha256="
  require_text "rescue watcher revalidates restore hash" "$rescue_watcher" "verify_restore_image_hash"
  require_text "rescue watcher publishes versioned contract" "$rescue_watcher" "contract_version=2"
  require_text "rescue watcher handles live contract challenges" "$rescue_watcher" "publish_contract_ack"
  require_text "rescue watcher supports explicit boot_b-only scope" "$rescue_watcher" "--boot-b-only"
  require_text "rescue watcher clears ambient dtbo image" "$rescue_watcher" 'RESTORE_DTBO_IMAGE=""'
  require_text "rescue watcher requires explicit dtbo SHA256" "$rescue_watcher" "--restore-dtbo-b-sha256"
  require_text "rescue watcher revalidates dtbo hash" "$rescue_watcher" "verify_restore_dtbo_hash"
  dtbo_restore_body="$(sed -n '/^restore_from_fastboot()/,/^}/p' "$rescue_watcher")"
  [ "$(grep -c 'verify_restore_dtbo_hash || return 1' <<< "$dtbo_restore_body")" -ge 3 ] ||
    fail "rescue watcher lacks startup/context/final DTBO hash boundaries"
  require_text "boot_b tester passes mandatory watcher contract" "$boot_b_tester" "--require-watcher-contract"
  require_text "boot_b tester pins watcher starttime" "$boot_b_tester" "--required-watcher-starttime"
  require_text "boot_b tester passes independent backup contract" "$boot_b_tester" "--required-watcher2-starttime"
  require_text "boot_b tester supervises fastboot transports" "$boot_b_tester" "run_guarded_fastboot_transport"
  require_text "boot_b tester guards restore flash transport" "$boot_b_tester" '"restore boot_b flash"'
  require_text "boot_b tester guards restored slot activation" "$boot_b_tester" '"restored slot-b activation"'
  require_text "boot_b tester guards restored reboot" "$boot_b_tester" '"restored fastboot system reboot"'
  ensure_bootloader_body="$(sed -n '/^ensure_bootloader_fastboot()/,/^}/p' "$boot_b_tester")"
  grep -Fq 'run_guarded_fastboot_transport "fastbootd bootloader reboot"' <<< "$ensure_bootloader_body" ||
    fail "boot_b tester does not guard the fastbootd-to-bootloader transport"
  [ "$(grep -c 'ensure_rescue_watcher_alive' <<< "$ensure_bootloader_body")" -ge 3 ] ||
    fail "boot_b tester does not reattest rescue around the fastbootd handoff"
  grep -Fq 'fastboot_do reboot bootloader' <<< "$ensure_bootloader_body" ||
    fail "boot_b tester lost the legacy no-watcher fastbootd route"
  require_text "SSH flasher pins device serial" "$ssh_flasher" "androidboot.serialno=\$expected_serial"
  require_text "SSH flasher pins hotdog project" "$ssh_flasher" "androidboot.prjname=19801"
  require_text "SSH flasher validates boot_b PARTNAME" "$ssh_flasher" 'partname" = "boot_b'
  require_text "SSH flasher freezes boot_b symlink target" "$ssh_flasher" 'part_link_now="$(readlink -f "$part"'
  require_text "SSH flasher writes resolved block device" "$ssh_flasher" 'of="$part_real"'
  require_text "SSH flasher reads resolved block device" "$ssh_flasher" 'dd if="$part_real"'
  require_text "SSH flasher challenges exact watcher contract" "$ssh_flasher" "challenge_required_watcher"
  require_text "SSH flasher validates watcher process starttime" "$ssh_flasher" "process_starttime"
  require_text "SSH flasher requires two-watcher quorum" "$ssh_flasher" "required_watcher_pair_static_valid"
  require_text "SSH flasher supervises transport process groups" "$ssh_flasher" "run_guarded_transport"
  require_text "SSH flasher verifies reboot dispatch proof" "$ssh_flasher" "HOTDOG_REBOOT_DISPATCH="

  require_text "fastboot tester documents kernel-prefix guard" "$fastboot_tester" "--expect-kernel-prefix PREFIX"
  require_text "fastboot tester parses kernel-prefix guard" "$fastboot_tester" "--expect-kernel-prefix)"
  require_text "fastboot tester checks expected kernel prefix" "$fastboot_tester" '"$ssh_kernel" != "$EXPECTED_KERNEL_PREFIX"*'
  require_text "fastboot tester classifies bridge recovery" "$fastboot_tester" "pmos-bridge-recovery"
  require_text "fastboot tester classifies unexpected kernel" "$fastboot_tester" "pmos-unexpected-kernel"
  require_text "fastboot tester returns nonzero for kernel guard failures" "$fastboot_tester" "return 5"

  log "generic kernel-prefix guards validated"
}

validate_d1_safety_offline() {
  local safety_test="$HOTDOG_ROOT/scripts/test-d1-safety-offline.sh"

  require_file "$safety_test"
  bash -n "$safety_test"
  bash "$safety_test"
  log "offline D1 safety regression suite validated"
}

validate_acm_collector() {
  local collector="$HOTDOG_ROOT/scripts/collect-mainline-acm-window.sh"
  local out="$tmpdir/acm-self-test.txt"

  require_file "$collector"
  bash -n "$collector"
  require_text "ACM collector documents self-test" "$collector" "--self-test-pty"
  require_text "ACM collector opens tty read-only" "$collector" "os.O_RDONLY | os.O_NOCTTY | os.O_NONBLOCK"
  require_text "ACM collector puts tty in raw mode" "$collector" "tty.setraw(fd, termios.TCSANOW)"
  require_text "ACM collector clears host echo" "$collector" "attrs[3] &= ~(termios.ECHO"
  require_text "ACM collector checks echo leak" "$collector" "echo leaked back to master"
  require_text "ACM collector dispatches self-test" "$collector" "python_tty_reader --self-test-pty"

  bash "$collector" --self-test-pty > "$out"
  grep -q '"pty_self_test": "ok"' "$out" || {
    sed -n '1,80p' "$out" >&2
    fail "ACM collector --self-test-pty did not report success"
  }
  log "ACM no-echo collector self-test OK"
}

validate_reproducible_builder_guards() {
  local direct_builder="$HOTDOG_ROOT/scripts/build-mainline-direct-bootimg.sh"
  local dtb_chain="$HOTDOG_ROOT/scripts/build-mainline-k1-dtb-chain.sh"

  require_file "$direct_builder"
  require_file "$dtb_chain"
  bash -n "$direct_builder" "$dtb_chain"
  require_text "direct builder rejects undersized FDT entries" "$direct_builder" "invalid FDT totalsize"
  require_text "direct builder bounds FDT entry size" "$direct_builder" "entry_size > remaining"
  require_text "direct builder pins source DTB pack" "$direct_builder" "components/source-dtb-pack"
  require_text "direct builder pins original DTB entry" "$direct_builder" "components/original-entry.dtb"
  require_text "K1 chain documents unpinned opt-in" "$dtb_chain" "--allow-unpinned-base"
  require_text "K1 chain rejects unpinned base by default" "$dtb_chain" "K1 base DTB hash mismatch"
  require_text "K1 chain normalizes relative output paths" "$dtb_chain" 'OUTDIR="$(readlink -m "$OUTDIR")"'
  log "direct-boot and K1 DTB builder guards validated"
}

validate_direct_d1_artifacts_and_launcher() {
  local d1_dir="$HOTDOG_ROOT/images/pmos-experiments/2026-07-11-150002-mainline617-direct-repro-clean-c"
  local d1_avb="$d1_dir/boot.img"
  local d1_raw="$d1_dir/boot-mainline617-direct-d1.img"
  local d1_manifest="$d1_dir/MANIFEST.md"
  local d1_sums="$d1_dir/SHA256SUMS"
  local d1_avb_info="$d1_dir/avb-info.txt"
  local stable_restore="$HOTDOG_ROOT/images/pmos-experiments/2026-07-11-130500-lineage414-r5-kexec-fbwait-nopaint-acm-rootwatchdog/boot-noefi-pmosdtb-watchdog-300s.img"
  local launcher="$HOTDOG_ROOT/scripts/test-mainline617-direct-d1.sh"
  local newc_extractor="$HOTDOG_ROOT/scripts/extract-last-newc-member.py"
  local effective_fb_probe=""

  check_sha "stable no-paint restore image" "$stable_restore" "23fa53d382425e9414a2e2a4b6e10f42d59ce1d6623b7fa1fbebf21ffe0c8a50"
  check_sha "D1 exact full AVB image" "$d1_avb" "f8e83ae15cb016612433b8a2d800d828b025d56c76640a2ebb41a3061baf8994"
  check_sha "D1 exact raw image" "$d1_raw" "8eee58ec96bcaaba5563e1aed9c3a00ac4c41ac495bc9ca728a45aa0bcd56ae0"
  check_size "D1 exact full AVB image" "$d1_avb" "100663296"
  check_size "D1 exact raw image" "$d1_raw" "50298880"
  require_text "D1 SHA256SUMS raw entry" "$d1_sums" "8eee58ec96bcaaba5563e1aed9c3a00ac4c41ac495bc9ca728a45aa0bcd56ae0  boot-mainline617-direct-d1.img"
  require_text "D1 SHA256SUMS AVB entry" "$d1_sums" "f8e83ae15cb016612433b8a2d800d828b025d56c76640a2ebb41a3061baf8994  boot.img"
  require_text "D1 manifest raw output" "$d1_manifest" "Raw image: \`images/pmos-experiments/2026-07-11-150002-mainline617-direct-repro-clean-c/boot-mainline617-direct-d1.img\`"
  require_text "D1 manifest AVB output" "$d1_manifest" "AVB image: \`images/pmos-experiments/2026-07-11-150002-mainline617-direct-repro-clean-c/boot.img\`"
  require_text "D1 AVB info partition size" "$d1_avb_info" "Image size:               100663296 bytes"
  require_text "D1 AVB info algorithm" "$d1_avb_info" "Algorithm:                NONE"
  require_text "D1 AVB info partition" "$d1_avb_info" "Partition Name:        boot"

  require_file "$launcher"
  bash -n "$launcher"
  require_text "D1 launcher pins AVB image" "$launcher" 'BOOT_IMAGE="$HOTDOG_ROOT/images/pmos-experiments/2026-07-11-150002-mainline617-direct-repro-clean-c/boot.img"'
  require_text "D1 launcher pins restore image" "$launcher" 'RESTORE_IMAGE="$HOTDOG_ROOT/images/pmos-experiments/2026-07-11-130500-lineage414-r5-kexec-fbwait-nopaint-acm-rootwatchdog/boot-noefi-pmosdtb-watchdog-300s.img"'
  require_text "D1 launcher pins boot wait default" "$launcher" 'BOOT_WAIT_SEC="${HOTDOG_D1_BOOT_WAIT_SEC:-540}"'
  require_text "D1 launcher enforces minimum wait" "$launcher" 'HOTDOG_D1_BOOT_WAIT_SEC must be at least 480'
  require_text "D1 launcher hash-checks AVB image" "$launcher" 'f8e83ae15cb016612433b8a2d800d828b025d56c76640a2ebb41a3061baf8994'
  require_text "D1 launcher hash-checks restore image" "$launcher" '23fa53d382425e9414a2e2a4b6e10f42d59ce1d6623b7fa1fbebf21ffe0c8a50'
  require_text "D1 launcher requires pmOS password" "$launcher" "hotdog_require_pmos_password"
  require_text "D1 launcher requires target serial" "$launcher" "hotdog_require_target_serial"
  require_text "D1 launcher rejects unsupported options" "$launcher" "Unsupported option for pinned D1 test"
  require_text "D1 launcher uses boot_b tester" "$launcher" 'exec "$HOTDOG_ROOT/scripts/test-boot-b-image.sh"'
  require_text "D1 launcher starts from pmOS SSH" "$launcher" "--from-pmos-ssh"
  require_text "D1 launcher prearms rescue watcher" "$launcher" "--start-rescue-watcher"
  require_text "D1 launcher pins expected products" "$launcher" '--expected-product "msmnile hotdog"'
  require_text "D1 launcher pins configured serial" "$launcher" '--serial "$HOTDOG_TARGET_SERIAL"'
  require_text "D1 launcher requires bridge source kernel" "$launcher" "--expect-source-kernel-prefix 4.14.357-openela-perf"
  require_text "D1 launcher requires source slot b" "$launcher" "--expect-source-cmdline-token androidboot.slot_suffix=_b"
  require_text "D1 launcher enforces mainline kernel prefix" "$launcher" "--expect-kernel-prefix 6.17.0-sm8150"
  require_text "D1 launcher requires unique wrapper marker" "$launcher" "--expect-cmdline-token rdinit=/hotdog-mainline-wrapper"
  require_text "D1 launcher requires target slot b" "$launcher" "--expect-cmdline-token androidboot.slot_suffix=_b"
  require_text "D1 launcher restores to system" "$launcher" "--restore-after system"
  require_file "$newc_extractor"
  effective_fb_probe="$(python3 "$newc_extractor" "$d1_dir/components/ramdisk" hotdog_fb_test.sh)"
  grep -Fq 'wait-only mode' <<< "$effective_fb_probe" || fail "D1 effective framebuffer probe is not wait-only"
  if grep -Eq 'hotdog_fb_test_fill|color=(red|green|blue|white)' <<< "$effective_fb_probe"; then
    fail "D1 effective framebuffer probe still contains RGB paint code"
  fi
  log "D1 direct artifacts and launcher validated"
}

validate_direct_d1_pack_artifacts_and_launcher() {
  local pack_dir="$HOTDOG_ROOT/images/pmos-experiments/2026-07-11-150010-mainline617-direct-pack-clean"
  local pack_avb="$pack_dir/boot.img"
  local pack_raw="$pack_dir/boot-mainline617-direct-d1-pack.img"
  local launcher="$HOTDOG_ROOT/scripts/test-mainline617-direct-d1-pack.sh"

  check_sha "D1-pack full AVB image" "$pack_avb" "2f3bf9b7cde3b2d48a3cf4d6fe2fb2f92e210e1a6b1249505fa15be10c26b754"
  check_sha "D1-pack raw validation image" "$pack_raw" "f72e8eab80d07fe265bfe5520228b3ff758d47980a2f0204f774b14d5314b1ac"
  check_size "D1-pack full AVB image" "$pack_avb" "100663296"
  check_size "D1-pack raw validation image" "$pack_raw" "59924480"
  require_text "D1-pack manifest mode" "$pack_dir/MANIFEST.md" 'DTB mode: `pack-entry-12`'
  require_file "$launcher"
  bash -n "$launcher"
  require_text "D1-pack launcher pins AVB image" "$launcher" 'BOOT_IMAGE="$HOTDOG_ROOT/images/pmos-experiments/2026-07-11-150010-mainline617-direct-pack-clean/boot.img"'
  require_text "D1-pack launcher pins raw image" "$launcher" 'RAW_IMAGE="$HOTDOG_ROOT/images/pmos-experiments/2026-07-11-150010-mainline617-direct-pack-clean/boot-mainline617-direct-d1-pack.img"'
  require_text "D1-pack launcher rejects overrides" "$launcher" "Unsupported option for pinned D1-pack test"
  require_text "D1-pack launcher pins configured serial" "$launcher" '--serial "$HOTDOG_TARGET_SERIAL"'
  require_text "D1-pack launcher requires bridge source" "$launcher" "--expect-source-kernel-prefix 4.14.357-openela-perf"
  require_text "D1-pack launcher requires target wrapper" "$launcher" "--expect-cmdline-token rdinit=/hotdog-mainline-wrapper"
  require_text "D1-pack launcher uses AVB image only" "$launcher" '--image "$BOOT_IMAGE"'
  log "D1-pack artifacts and launcher validated"
}

validate_dtb_entry12() {
  local label="$1"
  local dtb="$2"
  local require_nomap="${3:-no}"
  local out

  require_file "$dtb"
  out="$("$HOTDOG_ROOT/scripts/inspect-dtb-pack-simplefb.sh" --dtb "$dtb" --entry 12)"
  printf '%s\n' "$out" > "$tmpdir/${label}-dtb-entry12.txt"
  for key in chosen_node chosen_ranges stdout_path linux_stdout_path simplefb_node simplefb_compatible display0_alias; do
    if ! grep -q "^${key}=yes$" "$tmpdir/${label}-dtb-entry12.txt"; then
      sed -n '1,120p' "$tmpdir/${label}-dtb-entry12.txt" >&2
      fail "$label DTB entry12 missing ${key}=yes"
    fi
  done
  if [ "$require_nomap" = "yes" ]; then
    for key in cont_splash_nomap disp_rdump_nomap; do
      if ! grep -q "^${key}=yes$" "$tmpdir/${label}-dtb-entry12.txt"; then
        sed -n '1,140p' "$tmpdir/${label}-dtb-entry12.txt" >&2
        fail "$label DTB entry12 missing ${key}=yes"
      fi
    done
  fi
  log "$label DTB entry12 simplefb wiring OK"
}

extract_embedded_visible_shell() {
  local postmount="$1"
  local out="$2"

  awk '
    /cat > "\$bin" <<'\''EOF'\''/ {
      in_script = 1
      next
    }
    in_script && /^EOF$/ {
      exit
    }
    in_script {
      print
    }
  ' "$postmount" > "$out"
  [ -s "$out" ] || fail "could not extract embedded hotdog-visible-tty-shell from $postmount"
}

validate_candidate_dir() {
  local label="$1"
  local image="$2"
  local require_buttons="$3"
  local dir="$4"
  local expected_watchdog="${5:-}"
  local expected_autocycle="${6:-}"
  local expected_acm="${7:-no}"
  local expected_fbdev="${8:-no}"
  local expected_nomap="${9:-no}"
  local expected_strip_drm="${10:-no}"
  local cmdline="$dir/cmdline-watchdog.txt"
  local dtb="$dir/components/dtb"
  local postmount="$dir/initramfs-tree/hotdog_rootfs_postmount.sh"
  local tty_kmsg="$dir/initramfs-tree/hotdog_tty_kmsg_console.sh"
  local fbdev_helper="$dir/initramfs-tree/hotdog_fbdev_console_start.sh"
  local watchdog="$dir/initramfs-tree/hotdog_rescue_watchdog.sh"
  local acm_helper="$dir/initramfs-tree/hotdog_usb_acm_getty.sh"
  local visible_shell="$tmpdir/${label}-hotdog-visible-tty-shell.sh"

  require_file "$image"
  require_file "$cmdline"
  require_file "$dtb"
  log "$label image: $image"
  sha256sum "$image" "$dir/components/kernel" "$dtb" "$dir/components/initramfs-watchdog.gz" \
    | sed "s/^/[validate-current-candidates] ${label} sha256 /"

  validate_dtb_entry12 "$label" "$dtb" "$expected_nomap"

  if [ -f "$postmount" ]; then
    /bin/sh -n "$postmount"
    if grep -q 'cat > "$bin" <<'\''EOF'\''' "$postmount"; then
      extract_embedded_visible_shell "$postmount" "$visible_shell"
      /bin/sh -n "$visible_shell"
      log "$label generated visible tty shell syntax OK"
    elif [ "$require_buttons" = "yes" ]; then
      fail "$label requires embedded hotdog-visible-tty-shell but none was found"
    else
      log "$label rootfs postmount syntax OK"
    fi
  elif [ "$require_buttons" = "yes" ]; then
    fail "$label requires $postmount"
  else
    log "$label has no rootfs postmount helper"
  fi

  if [ -f "$tty_kmsg" ]; then
    /bin/sh -n "$tty_kmsg"
    log "$label tty-kmsg helper syntax OK"
  else
    log "$label has no tty-kmsg helper"
  fi

  if [ "$require_buttons" = "yes" ]; then
    grep -q 'buttons: Vol+ full status' "$visible_shell" || fail "$label visible shell missing button help text"
    grep -q 'monitor_input_device' "$visible_shell" || fail "$label visible shell missing input monitor"
    if [ -n "$expected_autocycle" ]; then
      grep -q "autocycle=\"$expected_autocycle\"" "$visible_shell" || fail "$label visible shell autocycle is not $expected_autocycle"
    fi
    if [ "$expected_autocycle" = "1" ]; then
      grep -q 'auto-cycle every 12s' "$visible_shell" || fail "$label visible shell missing auto-cycle status text"
      grep -q 'pause_marker="/tmp/hotdog-visible-tty-autocycle.pause"' "$visible_shell" || fail "$label visible shell missing auto-cycle pause marker"
      grep -q 'toggle_autocycle_pause' "$visible_shell" || fail "$label visible shell missing Power pause/resume action"
    else
      grep -q 'status follower every 20s' "$visible_shell" || fail "$label visible shell missing prompt-first status follower"
    fi
    grep -q "PS1='screen# '" "$visible_shell" || fail "$label visible shell missing screen prompt"
    grep -q 'chvt "${tty#tty}"' "$visible_shell" || fail "$label visible shell does not switch to its tty"
    grep -q 'stty sane echo icanon isig' "$visible_shell" || fail "$label visible shell does not reset tty line discipline"
    grep -q 'usb/watchdog' "$visible_shell" || fail "$label visible shell missing USB/watchdog status block"
    if [ "$expected_strip_drm" = "yes" ]; then
      grep -q 'strip_rootfs_drm_console' "$postmount" || fail "$label rootfs postmount does not strip persistent DRM console"
      grep -q 'hotdog-drm-console.start' "$postmount" || fail "$label strip hook does not remove hotdog-drm-console.start"
      grep -q 'pidfile=/run/hotdog-visible-tty-shell.pid' "$postmount" || fail "$label visible shell local.d hook lacks pidfile guard"
    fi
    if [ "$expected_acm" = "yes" ]; then
      require_file "$acm_helper"
      /bin/sh -n "$acm_helper"
      grep -q 'setup_usb_acm_configfs' "$acm_helper" || fail "$label ACM helper does not call setup_usb_acm_configfs"
      grep -q 'run_getty ttyGS0' "$acm_helper" || fail "$label ACM helper does not use ttyGS0 getty"
      grep -q 'hotdog-usb-acm-getty.start' "$postmount" || fail "$label rootfs postmount missing USB ACM getty local.d hook"
      grep -q 'hotdog-rootfs-usb-acm' "$postmount" || fail "$label rootfs USB ACM log tag missing"
      log "$label USB ACM getty helper syntax OK"
    fi
    if [ "$expected_fbdev" = "yes" ]; then
      require_file "$fbdev_helper"
      /bin/sh -n "$fbdev_helper"
      grep -q -- '--fbdev /dev/fb0' "$fbdev_helper" || fail "$label fbdev helper does not use /dev/fb0"
      grep -q 'hotdog-fbdev-console.in' "$fbdev_helper" || fail "$label fbdev helper missing fbdev command FIFO"
      grep -q 'HOTDOG_FOLLOWER_PID' "$fbdev_helper" || fail "$label fbdev helper missing follower pid export"
      grep -q 'Power stops the follower' "$fbdev_helper" || fail "$label fbdev helper missing Power quiet prompt hint"
      grep -q 'hotdog_fbdev_console_start initramfs' "$dir/initramfs-tree/init_2nd.sh" || fail "$label init_2nd does not start fbdev console"
      grep -q 'hotdog_fbdev_console_stop' "$dir/initramfs-tree/init_2nd.sh" || fail "$label init_2nd does not stop fbdev console before switch_root"
      grep -q '^usr/bin/hotdog-drm-console$' "$dir/initramfs-watchdog-contents.txt" || fail "$label initramfs missing console helper binary"
      log "$label fbdev console helper syntax OK"
    fi
    if [ "$expected_watchdog" = "usb" ]; then
      grep -q 'hotdog-usb-watchdog.start' "$postmount" || fail "$label rootfs postmount missing USB watchdog local.d hook"
      grep -q 'hotdog-rootfs-usb-watchdog' "$postmount" || fail "$label rootfs USB watchdog log tag missing"
    fi
    if [ -f "$tty_kmsg" ]; then
      grep -q 'hotdog_tty_kmsg_console_stop' "$tty_kmsg" || fail "$label tty-kmsg helper cannot stop before switch_root"
      grep -q 'hotdog_tty_kmsg_console_stop' "$dir/initramfs-tree/init_2nd.sh" || fail "$label init_2nd does not stop tty-kmsg before switch_root"
    elif [ "$expected_fbdev" != "yes" ] && [ "$expected_nomap" != "yes" ]; then
      fail "$label requires tty-kmsg helper or expected fbdev console"
    elif [ "$expected_nomap" = "yes" ]; then
      log "$label uses direct simplefb/fbcon output; no tty-kmsg or fbdev helper required"
    fi
    grep -q 'hotdog_rescue_watchdog_start switch-root' "$dir/initramfs-tree/init_2nd.sh" || fail "$label init_2nd does not rearm watchdog after killall sh"
    grep -q 'fbcon=vc:1-1' "$cmdline" || fail "$label cmdline missing fbcon=vc:1-1"
    require_file "$watchdog"
    /bin/sh -n "$watchdog"
    if [ "$label" = "next" ]; then
      grep -q 'HOTDOG_RESCUE_DIRECT_DEBUG_SHELL="0"' "$watchdog" || fail "$label still enables direct debug shell"
    fi
    if [ -n "$expected_watchdog" ]; then
      grep -q "HOTDOG_RESCUE_WATCHDOG_SUCCESS_MODE=\"$expected_watchdog\"" "$watchdog" || fail "$label watchdog is not $expected_watchdog-success mode"
    fi
    grep -q 'hotdog_rescue_watchdog.pid' "$watchdog" || fail "$label watchdog does not persist a pidfile"
    grep -q 'stale watchdog marker' "$watchdog" || fail "$label watchdog cannot rearm after stale pid"
    grep -q 'triggering sysrq reboot' "$watchdog" || fail "$label watchdog does not use sysrq reboot first"
    grep -q '/carrier' "$watchdog" || fail "$label watchdog does not require carrier/up USB network state"
    if grep -Fq '/sys/class/udc/*' "$watchdog"; then
      fail "$label watchdog treats a bare UDC controller as USB success"
    fi
    if grep -Fq '/sys/kernel/config/usb_gadget/g1/UDC' "$watchdog"; then
      fail "$label watchdog treats a configfs UDC bind as USB success"
    fi
    if grep -Fq '/sys/class/net/eth*' "$watchdog"; then
      fail "$label watchdog treats generic eth* as USB success"
    fi
  fi
}

main() {
  local current_wrapper="$HOTDOG_ROOT/scripts/test-lineage414-r5-kexec-bridge.sh"
  local image
  local restore
  local restore_ref
  local dir
  local cmdline

  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/hotdog-validate-candidates.XXXXXX")"
  trap 'rm -rf "$tmpdir"' EXIT

  require_file "$current_wrapper"
  bash -n "$current_wrapper"
  image="$(expand_hotdog_path "$(wrapper_value "$current_wrapper" image)")"
  restore_ref="$(wrapper_value "$current_wrapper" restore)"
  restore="$(expand_hotdog_path "$restore_ref")"
  require_file "$image"
  require_file "$restore"
  require_wrapper_restore_pointer "current r5 wrapper" "$current_wrapper"
  check_sha "current r5 no-paint image" "$image" "23fa53d382425e9414a2e2a4b6e10f42d59ce1d6623b7fa1fbebf21ffe0c8a50"
  check_sha "current r5 restore image" "$restore" "23fa53d382425e9414a2e2a4b6e10f42d59ce1d6623b7fa1fbebf21ffe0c8a50"
  require_text "current r5 wrapper pins expected SHA256" "$current_wrapper" 'expected_sha256="23fa53d382425e9414a2e2a4b6e10f42d59ce1d6623b7fa1fbebf21ffe0c8a50"'
  require_text "current r5 wrapper passes pinned image SHA256" "$current_wrapper" '--image-sha256 "$expected_sha256"'
  require_text "current r5 wrapper passes pinned restore SHA256" "$current_wrapper" '--restore-boot-b-sha256 "$expected_sha256"'
  require_text "current r5 wrapper rejects command-line options" "$current_wrapper" 'accepts no command-line options'
  require_text "current r5 wrapper validates source mode" "$current_wrapper" 'HOTDOG_FROM_PMOS_SSH must be exactly 0 or 1'
  require_text "current r5 wrapper pins expected products" "$current_wrapper" '--expected-product "msmnile hotdog"'
  require_text "current r5 wrapper pins boot wait" "$current_wrapper" '--boot-wait 420'
  require_text "current r5 wrapper pins observation poll" "$current_wrapper" '--poll 2'
  require_text "current r5 wrapper pins rescue timeout" "$current_wrapper" '--rescue-watch-timeout 21600'
  require_text "current r5 wrapper pins canonical SSH helper" "$current_wrapper" 'export HOTDOG_FLASH_BOOT_B_SSH_HELPER="$HOTDOG_ROOT/scripts/flash-boot-b-from-pmos-ssh.sh"'
  require_text "current r5 wrapper pins canonical rescue helper" "$current_wrapper" 'export HOTDOG_RESCUE_WATCHER_HELPER="$HOTDOG_ROOT/scripts/rescue-boot-b-when-visible.sh"'
  require_text "current r5 wrapper uses canonical target serial" "$current_wrapper" 'serial="$HOTDOG_TARGET_SERIAL"'
  require_text "shared serial guard rejects divergent identities" "$HOTDOG_ROOT/scripts/env.sh" 'differs from HOTDOG_TARGET_SERIAL'
  if grep -Fq '"$@"' "$current_wrapper"; then
    fail "current r5 wrapper still forwards arbitrary caller options"
  fi
  dir="$(dirname "$image")"
  cmdline="$dir/cmdline-watchdog.txt"
  log "current r5 wrapper: $current_wrapper"
  log "current r5 image: $image"
  log "restore image: $restore"

  check_cmdline_word "$(cat "$cmdline")" "console=tty0"
  check_cmdline_word "$(cat "$cmdline")" "ignore_loglevel"
  check_cmdline_word "$(cat "$cmdline")" "loglevel=8"
  check_cmdline_word "$(cat "$cmdline")" "fbcon=map:0"
  check_cmdline_word "$(cat "$cmdline")" "fbcon=font:VGA8x16"
  check_cmdline_word "$(cat "$cmdline")" "fbcon=vc:1-1"
  check_cmdline_word "$(cat "$cmdline")" "printk.devkmsg=on"
  validate_candidate_dir current_r5 "$image" yes "$dir" root 0 yes no no yes
  validate_r5_no_paint_framebuffer_helper "$dir"
  validate_historical_rgb_control "$historical_rgb_control"

  validate_direct_d1_artifacts_and_launcher
  validate_direct_d1_pack_artifacts_and_launcher
  validate_kernel_prefix_tester_guards
  validate_d1_safety_offline
  validate_acm_collector
  validate_reproducible_builder_guards

  log "all current candidates validated"
}

tmpdir=""
main "$@"
