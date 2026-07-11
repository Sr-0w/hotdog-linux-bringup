#!/usr/bin/env bash
set -euo pipefail

usage() {
	cat <<'EOF'
Usage: build-pmos-android-kernel-header-experiment.sh [--prepare-only|--build-kernel|--install] [--keep-overlay]

Prepare an experimental pmaports overlay for oneplus-hotdog where the SM8150
kernel uses an Android/Lineage-style ARM64 Image entry layout:

  - CONFIG_EFI=n, resolved through upstream Kconfig
  - no EFI stub/MZ signature
  - branch-to-entry in code0 and a zero code1 word
  - ARM64 Image text_offset advertised as 0x80000
  - strict no-argument prototypes when the source includes the downstream FTS driver

No adb, fastboot, scrcpy, or other phone command is used.

The copied legacy DTS patch is checked and its new-file hunk length is
normalized before checksums are generated. The source snapshot currently
declares 379 lines while carrying 389, which otherwise truncates the DTS.

Modes:
  --prepare-only  Create/update the overlay and checksums only. This is default.
  --build-kernel  Also build linux-postmarketos-sm8150-staging from the overlay.
  --install       Also run pmbootstrap install/export and copy the boot artifacts.
                  This step may use the network to repopulate a zapped rootfs.
  --keep-overlay  Reuse the existing experimental overlay instead of recreating it.
EOF
}

mode="prepare"
fresh_overlay=1
force_kernel_build=0

while [ "$#" -gt 0 ]; do
	case "$1" in
		--prepare-only)
			mode="prepare"
			;;
		--build-kernel)
			mode="build-kernel"
			force_kernel_build=1
			;;
		--install)
			mode="install"
			;;
		--keep-overlay)
			fresh_overlay=0
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

source "$(dirname "$0")/env.sh"

pkg_rel="device/testing/linux-postmarketos-sm8150-staging"
orig_pkg="$HOTDOG_PMAPORTS_SM8150/$pkg_rel"
experiment_root="$HOTDOG_ROOT/experiments/pmos-android-kernel-header"
experiment_pmaports="$experiment_root/pmaports-sm8150"
experiment_pkg="$experiment_pmaports/$pkg_rel"
experiment_logs="$experiment_root/logs"
experiment_images="$experiment_root/images"
header_patch_src="$HOTDOG_ROOT/patches/experimental-android-kernel-entry-layout.patch"
header_patch_name="0002-arm64-head-use-android-entry-layout.patch"
fts_patch_src="$HOTDOG_ROOT/patches/mainline-fts-strict-prototypes.patch"
fts_patch_name="0003-input-fts-use-strict-prototypes.patch"

pmb=(
	"$HOTDOG_BIN_ROOT/pmbootstrap"
	-c "$HOTDOG_PMBOOTSTRAP_CONFIG"
	-p "$experiment_pmaports"
	-w "$HOTDOG_PMBOOTSTRAP_WORK"
	-y
)

read_apkbuild_var() {
	local name="$1"
	local file="$2"
	sed -n "s/^${name}=//p" "$file" | head -n 1 | tr -d '"'
}

require_file() {
	local path="$1"
	if [ ! -f "$path" ]; then
		echo "Missing required file: $path" >&2
		exit 1
	fi
}

require_dir() {
	local path="$1"
	if [ ! -d "$path" ]; then
		echo "Missing required directory: $path" >&2
		exit 1
	fi
}

normalize_hotdog_dts_patch() {
	local patch_path="$1"
	python3 - "$patch_path" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
lines = path.read_text().splitlines()
marker = "diff --git a/arch/arm64/boot/dts/qcom/sm8150-oneplus-hotdog.dts b/arch/arm64/boot/dts/qcom/sm8150-oneplus-hotdog.dts"

try:
    diff_start = lines.index(marker)
except ValueError as exc:
    raise SystemExit(f"missing hotdog DTS diff in {path}") from exc

hunk_index = next(
    (index for index in range(diff_start + 1, len(lines)) if lines[index].startswith("@@ ")),
    None,
)
if hunk_index is None:
    raise SystemExit(f"missing hotdog DTS hunk in {path}")

match = re.fullmatch(r"@@ -0,0 \+1,(\d+) @@", lines[hunk_index])
if match is None:
    raise SystemExit(f"unexpected hotdog DTS hunk header: {lines[hunk_index]}")

diff_end = next(
    (index for index in range(hunk_index + 1, len(lines)) if lines[index].startswith("diff --git ")),
    len(lines),
)
hunk_lines = lines[hunk_index + 1:diff_end]
if not hunk_lines or any(not line.startswith("+") for line in hunk_lines):
    raise SystemExit("hotdog DTS new-file hunk contains non-addition lines")

actual_count = len(hunk_lines)
declared_count = int(match.group(1))
if declared_count != actual_count:
    lines[hunk_index] = f"@@ -0,0 +1,{actual_count} @@"
    path.write_text("\n".join(lines) + "\n")
    print(f"normalized hotdog DTS hunk length: {declared_count} -> {actual_count}")
else:
    print(f"hotdog DTS hunk length already correct: {actual_count}")
PY
}

prepare_overlay() {
	require_dir "$HOTDOG_PMAPORTS_SM8150"
	require_dir "$orig_pkg"
	require_file "$orig_pkg/APKBUILD"
	require_file "$orig_pkg/config-sm8150.aarch64"
	require_file "$header_patch_src"
	require_file "$fts_patch_src"

	mkdir -p "$experiment_root" "$experiment_logs" "$experiment_images"

	if [ "$fresh_overlay" -eq 1 ]; then
		rm -rf "$experiment_pmaports"
	fi

	if [ ! -d "$experiment_pmaports" ]; then
		mkdir -p "$experiment_pmaports"
		cp -a "$HOTDOG_PMAPORTS_SM8150/." "$experiment_pmaports/"
	fi

	require_dir "$experiment_pkg"
	require_file "$experiment_pkg/APKBUILD"
	require_file "$experiment_pkg/0001-arm64-dts-qcom-add-oneplus-hotdog.patch"
	normalize_hotdog_dts_patch "$experiment_pkg/0001-arm64-dts-qcom-add-oneplus-hotdog.patch"

	local apkbuild="$experiment_pkg/APKBUILD"
	local pkgname
	local repository
	local commit
	local use_fts_patch=0
	pkgname="$(read_apkbuild_var pkgname "$apkbuild")"
	repository="$(read_apkbuild_var _repository "$apkbuild")"
	commit="$(read_apkbuild_var _commit "$apkbuild")"

	local distfile="$HOTDOG_PMBOOTSTRAP_WORK/cache_distfiles/${pkgname}-${commit}.tar.gz"
	require_file "$distfile"

	local src_tmp
	local cfg_tmp
	src_tmp="$(mktemp -d)"
	cfg_tmp="$(mktemp -d)"

	tar -xf "$distfile" -C "$src_tmp"
	local clean_src="$src_tmp/${repository}-${commit}"
	require_dir "$clean_src"
	if [ -f "$clean_src/drivers/input/touchscreen/fts_touch/fts_lib/ftsIO.c" ]; then
		use_fts_patch=1
	fi

	cp "$orig_pkg/config-sm8150.aarch64" "$cfg_tmp/.config"
	"$clean_src/scripts/config" --file "$cfg_tmp/.config" -d EFI -d EFI_STUB
	make -s -C "$clean_src" O="$cfg_tmp" ARCH=arm64 olddefconfig
	cp "$cfg_tmp/.config" "$experiment_pkg/config-sm8150.aarch64"
	rm -rf "$src_tmp" "$cfg_tmp"

	cp "$header_patch_src" "$experiment_pkg/$header_patch_name"
	if [ "$use_fts_patch" -eq 1 ]; then
		cp "$fts_patch_src" "$experiment_pkg/$fts_patch_name"
	else
		rm -f "$experiment_pkg/$fts_patch_name"
		sed -i "\\|$fts_patch_name|d" "$apkbuild"
	fi

	if ! grep -q "^pkgrel=2$" "$apkbuild"; then
		sed -i 's/^pkgrel=.*/pkgrel=2/' "$apkbuild"
	fi

	if ! grep -q "$header_patch_name" "$apkbuild"; then
		awk -v patch="$header_patch_name" '
			{ print }
			/0001-arm64-dts-qcom-add-oneplus-hotdog.patch/ { print "\t" patch }
		' "$apkbuild" > "$apkbuild.tmp"
		mv "$apkbuild.tmp" "$apkbuild"
	fi

	if [ "$use_fts_patch" -eq 1 ] && ! grep -q "$fts_patch_name" "$apkbuild"; then
		awk -v anchor="$header_patch_name" -v patch="$fts_patch_name" '
			{ print }
			index($0, anchor) { print "\t" patch }
		' "$apkbuild" > "$apkbuild.tmp"
		mv "$apkbuild.tmp" "$apkbuild"
	fi

	if ! grep -q 'olddefconfig' "$apkbuild"; then
		awk '
			{ print }
			/cp "\$srcdir\/config-sm8150.\$arch" \.config/ { print "\tmake ARCH=\"$_carch\" olddefconfig" }
		' "$apkbuild" > "$apkbuild.tmp"
		mv "$apkbuild.tmp" "$apkbuild"
	fi

	"${pmb[@]}" checksum "$pkgname"

	{
		printf 'Experimental overlay: %s\n' "$experiment_pmaports"
		printf 'Kernel package: %s\n' "$pkgname"
		printf 'Kernel pkgrel: 2\n'
		printf 'Config changes of interest:\n'
		diff -u "$orig_pkg/config-sm8150.aarch64" "$experiment_pkg/config-sm8150.aarch64" \
			| grep -E 'CONFIG_(EFI|EFI_STUB|EFI_GENERIC_STUB|EFI_PARAMS_FROM_FDT|EFI_RUNTIME_WRAPPERS|EFI_ARMSTUB_DTB_LOADER|EFI_ESRT|EFI_VARS_PSTORE|EFI_SOFT_RESERVE|EFI_CAPSULE_LOADER|EFI_EARLYCON|EFI_CUSTOM_SSDT_OVERLAYS|EFIVAR_FS|FB_EFI|DMI|DMIID|UCS2_STRING|ACPI|ACPI_.*|UEFI_CPER|UEFI_CPER_ARM)' \
			|| true
	} | tee "$experiment_logs/prepare-summary.txt"
}

extract_kernel_from_apk() {
	local pkgname="$1"
	local apk
	apk="$(find "$HOTDOG_PMBOOTSTRAP_WORK/packages/edge/aarch64" -maxdepth 1 -type f -name "${pkgname}-*-r2.apk" | sort | tail -n 1)"
	if [ -z "$apk" ]; then
		echo "No r2 kernel APK found for $pkgname" >&2
		return 1
	fi

	local out_kernel="$experiment_root/vmlinuz-from-${pkgname}-r2"
	tar -xOf "$apk" boot/vmlinuz > "$out_kernel"
	printf 'Kernel APK: %s\n' "$apk"
	printf 'Extracted kernel: %s\n' "$out_kernel"
	printf 'First 64 bytes of extracted kernel:\n'
	od -An -tx1 -N64 "$out_kernel"
}

kernel_apk_exists() {
	local pkgname="$1"
	find "$HOTDOG_PMBOOTSTRAP_WORK/packages/edge/aarch64" -maxdepth 1 -type f -name "${pkgname}-*-r2.apk" | grep -q .
}

build_kernel() {
	local pkgname
	pkgname="$(read_apkbuild_var pkgname "$experiment_pkg/APKBUILD")"
	if [ "$force_kernel_build" -eq 1 ] || ! kernel_apk_exists "$pkgname"; then
		"${pmb[@]}" -o --details-to-stdout build --arch=aarch64 --force "$pkgname"
	else
		printf 'Using existing r2 kernel APK for %s\n' "$pkgname"
	fi
	extract_kernel_from_apk "$pkgname" | tee "$experiment_logs/kernel-build-summary.txt"
}

install_image() {
	local stamp
	stamp="$(date +%Y-%m-%d-%H%M%S)"
	local outdir="$experiment_images/$stamp"
	local summary="$experiment_logs/install-summary-$stamp.txt"
	local install_password="${PMOS_INSTALL_PASSWORD:-}"

	[ -n "$install_password" ] || {
		printf 'Set PMOS_INSTALL_PASSWORD before using --install.\n' >&2
		return 2
	}
	"${pmb[@]}" --details-to-stdout install --zap --password "$install_password"
	"${pmb[@]}" export

	mkdir -p "$outdir"
	printf 'Exported artifacts: %s\n' "$outdir" | tee "$summary"
	for exported in /tmp/postmarketOS-export/*; do
		[ -e "$exported" ] || [ -L "$exported" ] || continue
		if [ -e "$exported" ]; then
			cp -aL "$exported" "$outdir/"
		else
			printf 'Skipping missing export target: %s -> %s\n' \
				"$exported" "$(readlink "$exported")" | tee -a "$summary"
		fi
	done

	if [ -f "$outdir/boot.img" ]; then
		unpack_bootimg --boot_img "$outdir/boot.img" --out "$experiment_root/unpack-$stamp" \
			| tee -a "$summary"
		printf 'First 64 bytes of boot.img kernel payload:\n' | tee -a "$summary"
		od -An -tx1 -N64 "$experiment_root/unpack-$stamp/kernel" \
			| tee -a "$summary"
	fi
}

prepare_overlay

case "$mode" in
	prepare)
		;;
	build-kernel)
		build_kernel
		;;
	install)
		build_kernel
		install_image
		;;
esac
