#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source "$(dirname "$0")/env.sh"

kernel_repo="$HOTDOG_SRC_ROOT/kernel/linux-clearstaff-hotdog"
base_commit=403b56c33e2ccdda25d90378970a5e5b928dee19
patch_dir="$HOTDOG_ROOT/patches/clearstaff"
v42_dir="$HOTDOG_ROOT/images/pmos-experiments/2026-08-03-201500-clearstaff616-direct-entry-v42-clean-console"
base_config="$HOTDOG_ROOT/build/clearstaff-v42-clean-console/.config"
dtb="$v42_dir/components/dtb"
ramdisk="$v42_dir/components/ramdisk"
cmdline="$HOTDOG_ROOT/configs/clearstaff-hotdog-translated-iommu-font.cmdline"
base_config_sha=ebcc2e27899ebdc1d620a988fbd8a08c1384a214dd5528fd4b01667f60e22f97
dtb_sha=cbc56da2741ae9c3b83a04c4111c9bfc31d5ca5985264fbd3434aa0597856d92
ramdisk_sha=fd45c3902bdfec6b122608e77efa00a4894a3b4502218922e593910c36c4d6f0
cmdline_sha=de6f08f3690798e6ec3b20f5ca3b4683fd9efc15dd76ea5c970366afe2aeb4b3
stamp="${HOTDOG_BUILD_STAMP:-$(date +%F-%H%M%S)}"
source_tree="${HOTDOG_V43_SOURCE_TREE:-$HOTDOG_ROOT/build/clearstaff-v43-public-source}"
kernel_build="${HOTDOG_V43_KERNEL_BUILD:-$HOTDOG_ROOT/build/clearstaff-v43-upstream-dwc3}"
build_dir="$HOTDOG_ROOT/build/experiments/$stamp-clearstaff616-v43-upstream-dwc3"
outdir="$HOTDOG_ROOT/images/pmos-experiments/$stamp-clearstaff616-direct-entry-v43-upstream-dwc3"
jobs="${JOBS:-$(nproc)}"

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

check_sha() {
	local label="$1" path="$2" expected="$3" actual
	[ -s "$path" ] || die "missing $label: $path"
	actual="$(sha256sum "$path" | awk '{print $1}')"
	[ "$actual" = "$expected" ] ||
		die "$label hash mismatch: expected $expected, got $actual"
}

for command in awk avbtool fastboot git grep llvm-nm make nproc python3 sha256sum; do
	command -v "$command" >/dev/null 2>&1 || die "missing command: $command"
done
case "$jobs" in
	''|*[!0-9]*|0) die "JOBS must be a positive integer" ;;
esac

[ "$(git -C "$kernel_repo" rev-parse HEAD)" = "$base_commit" ] ||
	die "ClearStaff repository is not at pinned commit $base_commit"
check_sha "V42 config" "$base_config" "$base_config_sha"
check_sha "V42 translated-IOMMU DTB" "$dtb" "$dtb_sha"
check_sha "V42 initramfs" "$ramdisk" "$ramdisk_sha"
check_sha "V42 command line" "$cmdline" "$cmdline_sha"
[ ! -e "$source_tree" ] || die "refusing to reuse source worktree: $source_tree"
[ ! -e "$kernel_build" ] || die "refusing to reuse kernel build: $kernel_build"
[ ! -e "$build_dir" ] || die "refusing to reuse build directory: $build_dir"
[ ! -e "$outdir" ] || die "refusing to reuse artifact directory: $outdir"

git -C "$kernel_repo" worktree add --detach "$source_tree" "$base_commit"
for patch in "$patch_dir"/*.patch; do
	printf 'Applying %s\n' "$(basename "$patch")"
	git -C "$source_tree" apply --index "$patch"
done
git -C "$source_tree" diff --cached --check
if [ -n "$(git -C "$source_tree" status --porcelain -- drivers/usb drivers/iommu)" ]; then
	die "public source series unexpectedly modifies generic USB or IOMMU code"
fi

mkdir -p "$kernel_build"
cp "$base_config" "$kernel_build/.config"
make -C "$source_tree" O="$kernel_build" ARCH=arm64 LLVM=1 LLVM_IAS=1 olddefconfig
grep -qx 'CONFIG_DRM_PANEL_SAMSUNG_ONEPLUS_DSC=y' "$kernel_build/.config" ||
	die "OnePlus DSC panel is not built in"
grep -qx 'CONFIG_FONT_TER16x32=y' "$kernel_build/.config" ||
	die "Terminus 16x32 font is not built in"
make -C "$source_tree" O="$kernel_build" ARCH=arm64 LLVM=1 LLVM_IAS=1 \
	-j "$jobs" Image

kernel="$kernel_build/arch/arm64/boot/Image"
vmlinux="$kernel_build/vmlinux"
python3 - "$kernel" "$vmlinux" <<'PY'
import pathlib
import struct
import subprocess
import sys

image = pathlib.Path(sys.argv[1]).read_bytes()
load_offset, image_size = struct.unpack_from("<QQ", image, 8)
magic = struct.unpack_from("<I", image, 56)[0]
if load_offset != 0x80000 or image_size != 0x1AD0000:
    raise SystemExit(
        f"direct-boot window changed: load={load_offset:#x} size={image_size:#x}"
    )
if len(image) > image_size or magic != 0x644D5241:
    raise SystemExit(
        f"kernel no longer fits the validated window: payload={len(image):#x}"
    )

symbols = {}
for line in subprocess.check_output(["llvm-nm", "-n", sys.argv[2]], text=True).splitlines():
    fields = line.split()
    if len(fields) == 3 and fields[2] in {"_text", "_end"}:
        symbols[fields[2]] = int(fields[0], 16)
if symbols.get("_end", 0) - symbols.get("_text", 0) != image_size:
    raise SystemExit("linked kernel exceeds the validated 0x1ad0000 window")
PY

if grep -aEq 'HOTDOG_V3(5|7|8|9)' "$kernel"; then
	die "staged USB diagnostics or first-connect quirk remain in Image"
fi

mkdir -p "$build_dir"
git -C "$source_tree" diff --cached --binary > "$build_dir/public-kernel-series.patch"
sha256sum "$patch_dir"/*.patch > "$build_dir/PATCH-SHA256SUMS"
sha256sum "$kernel" "$vmlinux" "$kernel_build/.config" "$dtb" \
	"$ramdisk" "$cmdline" "$build_dir/public-kernel-series.patch" \
	> "$build_dir/SHA256SUMS"
cat > "$build_dir/change.txt" <<'EOF'
Kernel source: pinned ClearStaff base plus the public patch series only.
Generic DWC3, USB gadget, and IOMMU source: unmodified from the pinned base.
DTB, initramfs, translated DWC3 IOMMU setup, font, and command line: V42 exact.
Automatic reboot, watchdog, and recovery actions: none.
EOF

"$HOTDOG_ROOT/scripts/build-mainline-direct-bootimg.sh" \
	--kernel "$kernel" \
	--dtb "$dtb" \
	--ramdisk "$ramdisk" \
	--cmdline-file "$cmdline" \
	--outdir "$outdir" \
	--name boot-clearstaff616-direct-entry-v43-upstream-dwc3 \
	--partition-size 100663296

cp "$kernel_build/.config" "$outdir/components/kernel.config"
cp "$build_dir/public-kernel-series.patch" "$outdir/components/"
cp "$build_dir/PATCH-SHA256SUMS" "$outdir/components/"
cp "$build_dir/change.txt" "$outdir/components/"
sha256sum "$outdir/components/kernel.config" \
	"$outdir/components/public-kernel-series.patch" \
	"$outdir/components/PATCH-SHA256SUMS" \
	"$outdir/components/change.txt" >> "$outdir/SHA256SUMS"
cat >> "$outdir/MANIFEST.md" <<'EOF'

## V43 upstream-DWC3 contract

- Kernel source: pinned ClearStaff commit plus the public patch series only.
- Generic DWC3, gadget, and IOMMU code: unmodified.
- DTB, initramfs, command line, and translated DWC3 domain: V42 exact.
- Console: built-in Terminus 16x32 font.
- Direct-entry linked window: exactly `0x1ad0000`.
- Reset behavior: entirely manual.
EOF

printf 'Source worktree: %s\nKernel build: %s\nArtifact directory: %s\n' \
	"$source_tree" "$kernel_build" "$outdir"
sha256sum "$outdir"/boot-*.img
