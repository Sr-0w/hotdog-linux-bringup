#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/env.sh"

status=0
AUTOPILOT=0

usage() {
  cat <<'USAGE'
Usage: check-host-tools.sh [options]

Check host tools and local hotdog workspace prerequisites.

Options:
  --autopilot  Treat the full automated dump/flash/SSH path as required.
  -h, --help   Show this help.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --autopilot)
      AUTOPILOT=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

check_cmd() {
  local cmd="$1"
  if command -v "$cmd" >/dev/null 2>&1; then
    printf "%-24s OK   %s\n" "$cmd" "$(command -v "$cmd")"
  else
    printf "%-24s MISS\n" "$cmd"
    status=1
  fi
}

check_optional() {
  local cmd="$1"
  if command -v "$cmd" >/dev/null 2>&1; then
    printf "%-24s OK   %s\n" "$cmd" "$(command -v "$cmd")"
  else
    printf "%-24s optional-missing\n" "$cmd"
  fi
}

check_readable() {
  local label="$1"
  local path="$2"
  if [ -r "$path" ]; then
    printf "%-24s OK   %s\n" "$label" "$path"
  else
    printf "%-24s MISS %s\n" "$label" "$path"
    status=1
  fi
}

check_executable_path() {
  local label="$1"
  local path="$2"
  if [ -x "$path" ]; then
    printf "%-24s OK   %s\n" "$label" "$path"
  else
    printf "%-24s MISS %s\n" "$label" "$path"
    status=1
  fi
}

check_sha256_file() {
  local label="$1"
  local dir="$2"

  if [ ! -s "$dir/SHA256SUMS" ]; then
    printf "%-24s MISS %s\n" "$label" "$dir/SHA256SUMS"
    status=1
    return 0
  fi

  if ( cd "$dir" && sha256sum -c SHA256SUMS >/dev/null 2>&1 ); then
    printf "%-24s OK   %s\n" "$label" "$dir/SHA256SUMS"
  else
    printf "%-24s FAIL %s\n" "$label" "$dir/SHA256SUMS"
    status=1
  fi
}

check_git_send_email() {
  if [ -x /usr/libexec/git-core/git-send-email ]; then
    printf "%-24s OK   %s\n" "git send-email" "/usr/libexec/git-core/git-send-email"
  elif git help -a 2>/dev/null | grep -q 'send-email'; then
    printf "%-24s OK   %s\n" "git send-email" "git subcommand"
  else
    printf "%-24s MISS\n" "git send-email"
    status=1
  fi
}

echo "== Paths =="
printf "HOTDOG_ROOT=%s\n" "$HOTDOG_ROOT"
printf "HOTDOG_SRC_ROOT=%s\n" "$HOTDOG_SRC_ROOT"
printf "HOTDOG_BIN_ROOT=%s\n" "$HOTDOG_BIN_ROOT"
printf "HOTDOG_PMBOOTSTRAP_CONFIG=%s\n" "$HOTDOG_PMBOOTSTRAP_CONFIG"
printf "HOTDOG_PMBOOTSTRAP_WORK=%s\n" "$HOTDOG_PMBOOTSTRAP_WORK"
echo

echo "== Required host tools =="
for cmd in git adb fastboot dtc make bc bison flex openssl rsync cpio xz python3 losetup kpartx; do
  check_cmd "$cmd"
done
echo

echo "== Android image helpers =="
for cmd in mkbootimg unpack_bootimg repack_bootimg avbtool mkdtboimg lpunpack simg2img img2simg; do
  check_cmd "$cmd"
done
echo

echo "== Kernel/upstream helpers =="
for cmd in clang b4; do
  check_cmd "$cmd"
done
check_git_send_email
check_optional aarch64-linux-gnu-gcc
check_optional payload-dumper-go
if [ -x "$HOTDOG_BIN_ROOT/payload-dumper-go" ]; then
  printf "%-24s OK   %s\n" "payload-dumper-go-local" "$HOTDOG_BIN_ROOT/payload-dumper-go"
fi
if [ -x "$HOTDOG_BIN_ROOT/pmbootstrap" ]; then
  printf "%-24s OK   %s\n" "pmbootstrap-local" "$HOTDOG_BIN_ROOT/pmbootstrap"
  "$HOTDOG_BIN_ROOT/pmbootstrap" \
    -c "$HOTDOG_PMBOOTSTRAP_CONFIG" \
    -p "$HOTDOG_PMAPORTS_SM8150" \
    -w "$HOTDOG_PMBOOTSTRAP_WORK" \
    status || status=1
else
  printf "%-24s optional-missing\n" "pmbootstrap-local"
fi
echo

echo "== Phone rescue/first-boot helpers =="
check_optional scrcpy
check_optional sshpass
check_optional picocom
check_optional minicom
check_optional tcpdump
check_optional nmap
if [ -x "$HOTDOG_BIN_ROOT/edl" ]; then
  printf "%-24s OK   %s\n" "edl-local" "$HOTDOG_BIN_ROOT/edl"
else
  printf "%-24s optional-missing\n" "edl-local"
fi
if [ -x "$HOTDOG_BIN_ROOT/fhloaderparse" ]; then
  printf "%-24s OK   %s\n" "fhloaderparse-local" "$HOTDOG_BIN_ROOT/fhloaderparse"
fi
if [ -x "$HOTDOG_BIN_ROOT/qdl" ]; then
  printf "%-24s OK   %s\n" "qdl-local" "$HOTDOG_BIN_ROOT/qdl"
  if [ -d "$HOTDOG_ROOT/src/qualcomm/qdl/.git" ]; then
    printf "%-24s OK   %s\n" "qdl-source-rev" "$(git -C "$HOTDOG_ROOT/src/qualcomm/qdl" rev-parse --short HEAD 2>/dev/null || true)"
  fi
else
  printf "%-24s optional-missing\n" "qdl-local"
fi
if [ -r "$HOTDOG_ROOT/src/qualcomm/edl/Loaders/oneplus/000a50e100514985_2acf3a85fde334e2_fhprg_op7t.bin" ]; then
  printf "%-24s OK   %s\n" "op7t-edl-loader" "$HOTDOG_ROOT/src/qualcomm/edl/Loaders/oneplus/000a50e100514985_2acf3a85fde334e2_fhprg_op7t.bin"
else
  printf "%-24s optional-missing\n" "op7t-edl-loader"
fi
echo

if [ "$AUTOPILOT" -eq 1 ]; then
  echo "== Autopilot hard requirements =="
  for cmd in adb fastboot lsusb udevadm ssh sshpass ping ip scrcpy pgrep timeout sha256sum cmp; do
    check_cmd "$cmd"
  done
  check_executable_path edl-local "$HOTDOG_BIN_ROOT/edl"
  check_readable op7t-edl-loader "$HOTDOG_ROOT/src/qualcomm/edl/Loaders/oneplus/000a50e100514985_2acf3a85fde334e2_fhprg_op7t.bin"
  check_readable sideload-zip "$HOTDOG_ROOT/tools/recovery-zips/build/hotdog-reboot-bootloader.zip"
  check_readable recovery-adb-img "$HOTDOG_ROOT/images/lineage/hotdog-20260703/recovery-adb-unsecure.img"
  check_readable host-adbkey-pub "$HOME/.android/adbkey.pub"
  check_readable recovery-adbkey-pub "$HOTDOG_ROOT/images/lineage/hotdog-20260703/patch-magiskboot-strong/host-adbkey.pub"
  if [ -s "$HOME/.android/adbkey.pub" ] && [ -s "$HOTDOG_ROOT/images/lineage/hotdog-20260703/patch-magiskboot-strong/host-adbkey.pub" ]; then
    if cmp -s "$HOME/.android/adbkey.pub" "$HOTDOG_ROOT/images/lineage/hotdog-20260703/patch-magiskboot-strong/host-adbkey.pub"; then
      printf "%-24s OK   %s\n" "adbkey-match" "$(sha256sum "$HOME/.android/adbkey.pub" | awk '{ print $1 }')"
    else
      printf "%-24s FAIL host key differs from recovery key\n" "adbkey-match"
      status=1
    fi
  fi
  check_readable pmos-boot-img "$HOTDOG_ROOT/images/pmos/2026-07-08-070531-console-uncompressed-ramoops/boot.img"
  check_readable pmos-rootfs-img "$HOTDOG_ROOT/images/pmos/2026-07-08-070531-console-uncompressed-ramoops/oneplus-hotdog.img"
  check_readable pmos-dtb "$HOTDOG_ROOT/images/pmos/2026-07-08-070531-console-uncompressed-ramoops/dtbs/sm8150-oneplus-hotdog.dtb"
  check_sha256_file pmos-sha256 "$HOTDOG_ROOT/images/pmos/2026-07-08-070531-console-uncompressed-ramoops"
  check_executable_path validate-dump "$HOTDOG_ROOT/scripts/validate-stock-dump.sh"
  check_executable_path start-watchers "$HOTDOG_ROOT/scripts/start-autopilot-watchers.sh"
  check_executable_path stop-watchers "$HOTDOG_ROOT/scripts/stop-autopilot-watchers.sh"
  echo
fi

echo "== Versions =="
adb version | sed -n '1,4p' || true
fastboot --version 2>&1 | sed -n '1,4p' || true
b4 --version 2>&1 | sed -n '1,4p' || true
clang --version | sed -n '1,2p' || true
"$HOTDOG_BIN_ROOT/edl" -h 2>/dev/null | sed -n '1,2p' || true
"$HOTDOG_BIN_ROOT/qdl" --help 2>/dev/null | sed -n '1,2p' || true
echo

echo "== User and USB permissions =="
id -nG "$USER" || true
getent group android || true
if id -nG "$USER" | tr ' ' '\n' | grep -qx android; then
  echo "android group: OK"
else
  echo "android group: MISS - reconnect session after adding group"
  status=1
fi
find /etc/udev/rules.d /lib/udev/rules.d /usr/lib/udev/rules.d \
  -maxdepth 1 \( -iname '*android*' -o -iname '*adb*' \) -type f 2>/dev/null | sort
find /etc/udev/rules.d /lib/udev/rules.d /usr/lib/udev/rules.d \
  -maxdepth 1 \( -iname '*edl*' -o -iname '*hotdog*' \) -type f 2>/dev/null | sort
echo

echo "== Storage =="
df -h "$HOTDOG_ROOT" /home /tmp 2>/dev/null || true
echo

echo "== Connected devices =="
adb devices -l || true
fastboot devices || true

exit "$status"
