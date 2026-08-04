#!/usr/bin/env bash
set -Eeuo pipefail

export LC_ALL=C

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"

log() {
	printf '[public-tree] %s\n' "$*"
}

die() {
	printf '[public-tree] ERROR: %s\n' "$*" >&2
	exit 1
}

require_command() {
	command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

validate_shell_scripts() {
	local -a shell_scripts=()
	local shell_script

	mapfile -d '' -t shell_scripts < <(
		find scripts -maxdepth 1 -type f -name '*.sh' -print0 | sort -z
	)
	[ "${#shell_scripts[@]}" -gt 0 ] || die "no scripts/*.sh files found"

	log "bash -n (${#shell_scripts[@]} scripts)"
	for shell_script in "${shell_scripts[@]}"; do
		bash -n "$shell_script"
	done

	log "ShellCheck severity=warning (${#shell_scripts[@]} scripts)"
	shellcheck --severity=warning -- "${shell_scripts[@]}"
}

validate_python_syntax() {
	local -a python_files=()

	mapfile -d '' -t python_files < <(git ls-files -z -- '*.py')
	if [ "${#python_files[@]}" -eq 0 ]; then
		log "Python syntax: no tracked Python files"
		return
	fi

	log "Python syntax (${#python_files[@]} files, no bytecode writes)"
	python3 - "${python_files[@]}" <<'PY'
from pathlib import Path
import sys
import tokenize

for raw_path in sys.argv[1:]:
    path = Path(raw_path)
    with tokenize.open(path) as source_file:
        source = source_file.read()
    compile(source, str(path), "exec", dont_inherit=True)
PY
}

validate_markdown_links() {
	local -a markdown_files=()

	mapfile -d '' -t markdown_files < <(git ls-files -z -- '*.md')
	if [ "${#markdown_files[@]}" -eq 0 ]; then
		log "Markdown links: no tracked Markdown files"
		return
	fi

	log "local Markdown links (${#markdown_files[@]} files)"
	python3 - "$REPO_ROOT" "${markdown_files[@]}" <<'PY'
from pathlib import Path
import os
import re
import sys
from urllib.parse import unquote, urlsplit

root = Path(sys.argv[1]).resolve()
inline_link = re.compile(r"!?\[[^\]\n]*\]\(([^)\n]+)\)")
reference_link = re.compile(r"^\s{0,3}\[[^\]\n]+\]:\s*(.+?)\s*$")
fence_marker = re.compile(r"^\s{0,3}(`{3,}|~{3,})")
inline_code = re.compile(r"`[^`]*`")
errors = []


def visible_lines(text):
    fence = None
    for line_number, line in enumerate(text.splitlines(), 1):
        marker = fence_marker.match(line)
        if marker:
            marker_type = marker.group(1)[0]
            if fence is None:
                fence = marker_type
            elif fence == marker_type:
                fence = None
            continue
        if fence is None:
            yield line_number, inline_code.sub("", line)


def destination(raw):
    raw = raw.strip()
    if raw.startswith("<"):
        end = raw.find(">", 1)
        return raw[1:end] if end != -1 else raw
    return raw.split(None, 1)[0] if raw else ""


def check_target(markdown_path, line_number, raw_target):
    target = destination(raw_target)
    if not target or target.startswith(("#", "//")):
        return

    parsed = urlsplit(target)
    if parsed.scheme:
        return

    local_path = unquote(parsed.path)
    if not local_path:
        return

    if local_path.startswith("/"):
        candidate = root / local_path.lstrip("/")
    else:
        candidate = markdown_path.parent / local_path
    candidate = candidate.resolve()

    try:
        inside_root = os.path.commonpath((root, candidate)) == str(root)
    except ValueError:
        inside_root = False
    if not inside_root:
        errors.append(
            f"{markdown_path.relative_to(root)}:{line_number}: "
            f"local link escapes repository: {target}"
        )
    elif not candidate.exists():
        errors.append(
            f"{markdown_path.relative_to(root)}:{line_number}: "
            f"missing local link target: {target}"
        )


for relative_path in sys.argv[2:]:
    markdown_path = (root / relative_path).resolve()
    text = markdown_path.read_text(encoding="utf-8")
    for line_number, line in visible_lines(text):
        for match in inline_link.finditer(line):
            check_target(markdown_path, line_number, match.group(1))
        reference = reference_link.match(line)
        if reference:
            check_target(markdown_path, line_number, reference.group(1))

if errors:
    print("\n".join(errors), file=sys.stderr)
    raise SystemExit(1)
PY
}

check_forbidden_pattern() {
	local label="$1"
	local pattern="$2"
	local matches
	local status

	if matches="$(git grep -I -n -E -e "$pattern" -- .)"; then
		printf '%s\n' "$matches" >&2
		die "forbidden $label found in tracked files"
	else
		status=$?
		[ "$status" -eq 1 ] || die "git grep failed while checking $label"
	fi
}

validate_public_markers() {
	local workstation_path
	local device_identifier
	local fake_email_pattern

	workstation_path='/home/'srobin
	device_identifier='b6bd''2252'
	fake_email_pattern='[[:alnum:]._%+-]+@([[:alnum:].-]+[.]invalid|example[.](com|org|net))'

	log "public-tree private marker scan"
	check_forbidden_pattern "workstation path" "$workstation_path"
	check_forbidden_pattern "device identifier" "$device_identifier"
	check_forbidden_pattern "placeholder email" "$fake_email_pattern"
}

assert_identical() {
	local canonical="$1"
	local copy="$2"

	[ -f "$canonical" ] || die "missing canonical K1 patch: $canonical"
	[ -f "$copy" ] || die "missing duplicated K1 patch: $copy"
	cmp -s -- "$canonical" "$copy" || die "K1 patch copies differ: $canonical != $copy"
}

validate_k1_patch_copies() {
	local aport_dir="aports/device/testing/linux-oneplus-hotdog-mainline617-k1"

	log "K1 duplicated patch identity"
	assert_identical \
		"patches/experimental-android-kernel-entry-layout.patch" \
		"$aport_dir/0001-arm64-hotdog-use-android-entry-layout.patch"
	assert_identical \
		"patches/mainline-fts-strict-prototypes.patch" \
		"$aport_dir/0002-input-fts-fix-strict-prototypes.patch"
	assert_identical \
		"patches/mainline-hotdog-k1-dts.patch" \
		"$aport_dir/0004-arm64-dts-qcom-add-oneplus-hotdog.patch"
}

verify_sha512() {
	local expected="$1"
	local file="$2"
	local actual

	actual="$(sha512sum -- "$file")"
	actual="${actual%% *}"
	[ "$actual" = "$expected" ] || die "SHA512 mismatch for $file: expected $expected, got $actual"
}

validate_k1_aport_inputs() {
	local aport_dir="aports/device/testing/linux-oneplus-hotdog-mainline617-k1"
	local apkbuild="$aport_dir/APKBUILD"
	local transform="$aport_dir/transform-k1-dtb.sh"
	local line
	local expected
	local filename
	local checksum_count=0
	local local_count=0
	local source_count=0
	local tar_count=0
	local in_source=0

	[ -f "$apkbuild" ] || die "missing K1 APKBUILD: $apkbuild"
	log "K1 aport SHA512 inputs"
	[ -x "$transform" ] || die "missing executable K1 DTB transform: $transform"
	sh -n "$transform"
	shellcheck --severity=warning --shell=sh -- "$transform"

	while IFS= read -r line || [ -n "$line" ]; do
		if [ "$in_source" -eq 0 ]; then
			[[ "$line" =~ ^source=\"[[:space:]]*$ ]] && in_source=1
			continue
		fi
		[[ "$line" =~ ^[[:space:]]*\"[[:space:]]*$ ]] && break
		[[ "$line" =~ ^[[:space:]]*$ ]] || ((source_count += 1))
	done < "$apkbuild"
	[ "$source_count" -gt 0 ] || die "could not parse K1 source entries from $apkbuild"

	while IFS= read -r line || [ -n "$line" ]; do
		if [[ "$line" =~ ^([0-9a-f]{128})[[:space:]]+([^[:space:]]+)$ ]]; then
			expected="${BASH_REMATCH[1]}"
			filename="${BASH_REMATCH[2]}"
			((checksum_count += 1))

			if [[ "$filename" == *.tar.bz2 ]]; then
				((tar_count += 1))
				if [ -f "$aport_dir/$filename" ]; then
					verify_sha512 "$expected" "$aport_dir/$filename"
				else
					log "skip absent remote source tarball: $filename"
				fi
				continue
			fi

			((local_count += 1))
			[ -f "$aport_dir/$filename" ] || die "missing local K1 aport input: $aport_dir/$filename"
			verify_sha512 "$expected" "$aport_dir/$filename"
		fi
	done < "$apkbuild"

	[ "$checksum_count" -eq "$source_count" ] || die \
		"expected one K1 SHA512 entry per source ($source_count), found $checksum_count"
	[ "$tar_count" -eq 1 ] || die "expected one K1 remote source tarball entry, found $tar_count"
	[ "$local_count" -eq $((source_count - tar_count)) ] || die \
		"expected $((source_count - tar_count)) K1 local inputs, found $local_count"
}

validate_mainline616_aport_inputs() {
	local aport_dir="aports/device/testing/linux-oneplus-hotdog-mainline616"
	local apkbuild="$aport_dir/APKBUILD"
	local validator="$aport_dir/validate-mainline616-build.sh"
	local line
	local expected
	local filename
	local checksum_count=0
	local local_count=0
	local source_count=0
	local tar_count=0
	local in_source=0

	[ -f "$apkbuild" ] || die "missing mainline 6.16 APKBUILD: $apkbuild"
	[ -f "$validator" ] || die "missing mainline 6.16 validator: $validator"
	log "mainline 6.16 aport SHA512 inputs"
	sh -n "$validator"
	shellcheck --severity=warning --shell=sh -- "$validator"

	while IFS= read -r line || [ -n "$line" ]; do
		if [ "$in_source" -eq 0 ]; then
			[[ "$line" =~ ^source=\"[[:space:]]*$ ]] && in_source=1
			continue
		fi
		[[ "$line" =~ ^[[:space:]]*\"[[:space:]]*$ ]] && break
		[[ "$line" =~ ^[[:space:]]*$ ]] || ((source_count += 1))
	done < "$apkbuild"
	[ "$source_count" -gt 0 ] || die "could not parse mainline 6.16 sources from $apkbuild"

	while IFS= read -r line || [ -n "$line" ]; do
		if [[ "$line" =~ ^([0-9a-f]{128})[[:space:]]+([^[:space:]]+)$ ]]; then
			expected="${BASH_REMATCH[1]}"
			filename="${BASH_REMATCH[2]}"
			((checksum_count += 1))

			if [[ "$filename" == *.tar.gz ]]; then
				((tar_count += 1))
				if [ -f "$aport_dir/$filename" ]; then
					verify_sha512 "$expected" "$aport_dir/$filename"
				else
					log "skip absent mainline 6.16 source tarball: $filename"
				fi
				continue
			fi

			((local_count += 1))
			[ -f "$aport_dir/$filename" ] ||
				die "missing local mainline 6.16 aport input: $aport_dir/$filename"
			verify_sha512 "$expected" "$aport_dir/$filename"
		fi
	done < "$apkbuild"

	[ "$checksum_count" -eq "$source_count" ] || die \
		"expected one mainline 6.16 SHA512 entry per source ($source_count), found $checksum_count"
	[ "$tar_count" -eq 1 ] || die \
		"expected one mainline 6.16 remote source tarball entry, found $tar_count"
	[ "$local_count" -eq $((source_count - tar_count)) ] || die \
		"expected $((source_count - tar_count)) mainline 6.16 local inputs, found $local_count"
}

validate_hotdog_wifi_package_contract() {
	local device_apkbuild="aports/device/testing/device-oneplus-hotdog/APKBUILD"
	local firmware_apkbuild="aports/device/testing/firmware-oneplus-hotdog/APKBUILD"

	log "hotdog WCN3990 package contract"
	grep -q 'firmware-oneplus-hotdog-wlan' "$device_apkbuild" ||
		die "device firmware package does not depend on WLAN firmware"
	grep -q 'firmware-oneplus-hotdog-modem' "$device_apkbuild" ||
		die "device firmware package does not depend on MPSS firmware"
	grep -q '^[[:space:]]*rmtfs$' "$device_apkbuild" ||
		die "device firmware package does not depend on RMTFS"
	grep -q '^[[:space:]]*rmtfs-openrc$' "$device_apkbuild" ||
		die "device firmware package does not depend on the RMTFS OpenRC service"
	grep -q '^rc-update add rmtfs boot$' \
		"aports/device/testing/device-oneplus-hotdog/device-oneplus-hotdog-nonfree-firmware.post-install" ||
		die "device firmware package does not enable RMTFS at boot"
	grep -q '"$builddir"/board-2.bin' "$firmware_apkbuild" ||
		die "WLAN package does not install board-2.bin"
	grep -q '"$builddir"/firmware-5.bin' "$firmware_apkbuild" ||
		die "WLAN package does not install firmware-5.bin"
	grep -q '"$builddir"/wlanmdsp.mbn' "$firmware_apkbuild" ||
		die "WLAN package does not install wlanmdsp.mbn"
	grep -q '"$builddir"/modem.mbn' "$firmware_apkbuild" ||
		die "modem package does not install modem.mbn"
}

validate_hotdog_plasma_apps_contract() {
	local device_apkbuild="aports/device/testing/device-oneplus-hotdog/APKBUILD"
	local package=""

	log "hotdog Plasma Mobile application contract"
	grep -q '\$pkgname-plasma-mobile-apps:plasma_mobile_apps' "$device_apkbuild" ||
		die "device package lacks the Plasma Mobile application subpackage"
	grep -q 'install_if="\$pkgname=\$pkgver-r\$pkgrel postmarketos-ui-plasma-mobile"' \
		"$device_apkbuild" || die "mobile applications are not gated on Plasma Mobile"
	for package in \
		angelfish discover discover-backend-flatpak dolphin flatpak kalk kclock \
		koko konsole kweather megapixels merkuro okular-mobile plasma-dialer \
		polkit-elogind spacebar xdg-user-dirs; do
		grep -q "^[[:space:]]*$package$" "$device_apkbuild" ||
			die "missing Plasma Mobile application dependency: $package"
	done
}

validate_rescue_supervisor_source() {
	local source="helpers/hotdog-rescue-supervisor.c"
	local builder="scripts/build-hotdog-rescue-supervisor.sh"
	local initramfs_builder="scripts/build-mainline-pmos-wrapper-initramfs.sh"
	local dtb_builder="scripts/build-mainline-pmos-boot-dtb.sh"

	[ -f "$source" ] || die "missing rescue supervisor source: $source"
	[ -x "$builder" ] || die "missing executable rescue supervisor builder: $builder"
	[ -x "$initramfs_builder" ] ||
		die "missing executable initramfs builder: $initramfs_builder"
	[ -x "$dtb_builder" ] ||
		die "missing executable mainline boot DTB builder: $dtb_builder"

	log "static rescue supervisor source contract"
	cc -std=c11 -Wall -Wextra -Werror -fsyntax-only "$source"
	grep -q 'HOTDOG_RESCUE_SUPERVISOR_V1' "$source" ||
		die "rescue supervisor identity marker is missing"
	grep -q 'CLOCK_MONOTONIC' "$source" ||
		die "rescue supervisor does not use a monotonic clock"
	grep -q 'LINUX_REBOOT_CMD_RESTART2' "$source" ||
		die "rescue supervisor lacks RESTART2"
	grep -q 'RESTART_REASON_BOOTLOADER' "$source" ||
		die "rescue supervisor lacks the bootloader restart reason"
	grep -q 'WDT_TIMEOUT_SEC 32U' "$source" ||
		die "rescue supervisor APSS fallback is not bounded to 32 seconds"
	grep -q 'WATCHDOG_PATH "/dev/watchdog0"' "$source" ||
		die "rescue supervisor does not prefer the Linux watchdog device"
	grep -q 'WDIOC_SETTIMEOUT' "$source" ||
		die "rescue supervisor does not bound the Linux watchdog timeout"
	if grep -Eq '(^|[^[:alnum:]_])sync[[:space:]]*\(' "$source"; then
		die "rescue supervisor deadline path must not block in sync()"
	fi

	grep -q 'zig cc -target aarch64-linux-musl -static' "$builder" ||
		die "rescue supervisor builder does not pin a static AArch64 target"
	grep -q 'qemu-aarch64 "$OUTPUT" --self-test' "$builder" ||
		die "rescue supervisor builder lacks its QEMU self-test"
	grep -q -- '--rescue-supervisor FILE' "$initramfs_builder" ||
		die "initramfs builder does not document --rescue-supervisor"
	grep -q 'hotdog-rescue-supervisor' "$initramfs_builder" ||
		die "initramfs builder does not package the rescue supervisor"
	grep -q 'mode-bootloader 2' "$dtb_builder" ||
		die "mainline boot DTB builder lacks the PM8150 Fastboot mode"
	grep -q 'mode-recovery 1' "$dtb_builder" ||
		die "mainline boot DTB builder lacks the PM8150 recovery mode"
}

validate_bounded_exec_source() {
	local source="helpers/hotdog-bounded-exec.c"
	local builder="scripts/build-hotdog-bounded-exec.sh"
	local initramfs_builder="scripts/build-mainline-pmos-wrapper-initramfs.sh"

	[ -f "$source" ] || die "missing bounded exec source: $source"
	[ -x "$builder" ] || die "missing executable bounded exec builder: $builder"
	[ -x "$initramfs_builder" ] ||
		die "missing executable initramfs builder: $initramfs_builder"

	log "static bounded exec source contract"
	cc -std=c11 -Wall -Wextra -Werror -fsyntax-only "$source"
	grep -q 'HOTDOG_BOUNDED_EXEC_V1' "$source" ||
		die "bounded exec identity marker is missing"
	grep -q 'CLOCK_MONOTONIC' "$source" ||
		die "bounded exec does not use a monotonic clock"
	grep -q 'pid = fork()' "$source" ||
		die "bounded exec does not use fork"
	if grep -Eq '(^|[^[:alnum:]_])vfork[[:space:]]*\(' "$source"; then
		die "bounded exec must not use vfork"
	fi
	grep -q 'execvp(command\[0\], command)' "$source" ||
		die "bounded exec does not execute the requested command"
	grep -q 'kill(-pid, SIGTERM)' "$source" ||
		die "bounded exec does not terminate the child process group"
	grep -q 'kill(-pid, SIGKILL)' "$source" ||
		die "bounded exec lacks its forced termination fallback"
	grep -q 'return 124' "$source" ||
		die "bounded exec lacks the timeout status contract"

	grep -q 'zig cc -target aarch64-linux-musl -static' "$builder" ||
		die "bounded exec builder does not pin a static AArch64 target"
	grep -q 'qemu-aarch64 "$OUTPUT" --self-test' "$builder" ||
		die "bounded exec builder lacks its QEMU self-test"
	grep -q 'expect_status 0 --timeout 2 -- /bin/true' "$builder" ||
		die "bounded exec builder does not test command success"
	grep -q 'expect_status 37 --timeout 2 -- /bin/sh' "$builder" ||
		die "bounded exec builder does not test exit propagation"
	grep -q 'expect_status 124 --timeout 1 -- /bin/sleep 30' "$builder" ||
		die "bounded exec builder does not test a real timeout"
	grep -q -- '--bounded-exec-helper FILE' "$initramfs_builder" ||
		die "initramfs builder does not document --bounded-exec-helper"
	grep -q 'file /hotdog-bounded-exec' "$initramfs_builder" ||
		die "initramfs builder does not package bounded exec"
	grep -q '/hotdog-bounded-exec --timeout 15 -- "$@"' "$initramfs_builder" ||
		die "bounded udev does not invoke the static helper"
	grep -q 'udev-skip' "$initramfs_builder" ||
		die "initramfs builder lacks the diagnostic udev bypass"
	grep -q 'usb-probe' "$initramfs_builder" ||
		die "initramfs builder lacks USB prerequisite tracing"
	grep -q 'dwc3-probe' "$initramfs_builder" ||
		die "initramfs builder lacks DWC3 binding tracing"
	grep -q 'profile retained setup_udev' "$initramfs_builder" ||
		die "diagnostic udev bypass lacks its negative setup_udev guard"
}

validate_disabled_r6_ufs_probe() {
	local source="helpers/r6-ufs-regdump/hotdog_r6_ufs_regdump.c"
	local readme="helpers/r6-ufs-regdump/README.md"

	[ -f "$source" ] || die "missing disabled R6 UFS probe source: $source"
	[ -f "$readme" ] || die "missing disabled R6 UFS probe documentation: $readme"

	log "disabled R6 UFS live-probe contract"
	grep -q 'HOTDOG_R6_UFS_REGDUMP_DISABLED' "$source" ||
		die "R6 UFS probe lacks its disabled marker"
	grep -q 'return -EPERM;' "$source" ||
		die "R6 UFS probe does not fail closed"
	if grep -Eq 'ufshcd_hold[[:space:]]*\(|ufshcd_dme_get[[:space:]]*\(|readl(_relaxed)?[[:space:]]*\(' "$source"; then
		die "R6 UFS probe source contains a live controller access"
	fi
	grep -q '2100b2c93190fdbfbdb61b8ef2d77b5dfc5b6378c13eacc898591fb1ce00396f' "$readme" ||
		die "R6 UFS probe documentation lacks the unsafe binary identity"
}

validate_ramoops_extractor() {
	local extractor="scripts/extract-ramoops-console.py"

	[ -x "$extractor" ] || die "missing executable ramoops extractor: $extractor"
	log "mixed-size ramoops extraction"
	python3 - "$extractor" <<'PY'
import pathlib
import struct
import subprocess
import sys
import tempfile

extractor = pathlib.Path(sys.argv[1]).resolve()
signature = 0x43474244
header_size = 12
zone_size = 0x1000
capacity = zone_size - header_size
reservation = bytearray(0x5000)

stored = b"ABCDE" + b"K" * (capacity - 5)
reservation[0x3000:0x3000 + header_size] = struct.pack(
    "<III", signature, 5, capacity
)
reservation[0x3000 + header_size:0x4000] = stored

pmsg = b"stage-two-pmsg\n"
reservation[0x4000:0x4000 + header_size] = struct.pack(
    "<III", signature, 0, len(pmsg)
)
reservation[0x4000 + header_size:0x4000 + header_size + len(pmsg)] = pmsg

with tempfile.NamedTemporaryFile() as image:
    image.write(reservation)
    image.flush()
    result = subprocess.run(
        [
            sys.executable,
            str(extractor),
            "--ddr-phys-base", "0",
            "--reservation-phys", "0",
            "--reservation-size", hex(len(reservation)),
            "--scan-reservation",
            image.name,
        ],
        check=True,
        stdout=subprocess.PIPE,
    )

expected_ring = stored[5:] + stored[:5]
assert b"RAMOOPS_ZONE offset=0x3000 bytes=4084" in result.stdout
assert expected_ring in result.stdout
assert b"RAMOOPS_ZONE offset=0x4000 bytes=15" in result.stdout
assert pmsg in result.stdout
PY
}

main() {
	local command_name

	for command_name in bash cc cmp find git python3 sha512sum shellcheck sort; do
		require_command "$command_name"
	done

	cd -- "$REPO_ROOT"
	git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a Git work tree: $REPO_ROOT"

	validate_shell_scripts
	validate_python_syntax
	validate_markdown_links
	validate_public_markers
	validate_k1_patch_copies
	validate_k1_aport_inputs
	validate_mainline616_aport_inputs
	validate_hotdog_wifi_package_contract
	validate_hotdog_plasma_apps_contract
	validate_rescue_supervisor_source
	validate_bounded_exec_source
	validate_disabled_r6_ufs_probe
	validate_ramoops_extractor

	log "all checks passed"
}

main "$@"
