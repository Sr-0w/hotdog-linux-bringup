#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source "$(dirname "$0")/env.sh"

source_dir="$HOTDOG_SRC_ROOT/kernel/linux-clearstaff-hotdog"
base_build="$HOTDOG_ROOT/build/clearstaff-v39-ep0-iommu-trace"
v41_dir="$HOTDOG_ROOT/images/pmos-experiments/2026-08-03-235000-clearstaff616-direct-entry-v41-translated-dwc3-iommu"
base_config="$base_build/.config"
dtb="$v41_dir/components/dtb"
ramdisk="$v41_dir/components/ramdisk"
v41_cmdline="$HOTDOG_ROOT/configs/clearstaff-hotdog-translated-iommu.cmdline"
cmdline="$HOTDOG_ROOT/configs/clearstaff-hotdog-translated-iommu-font.cmdline"
base_config_sha=86103671ddc29cebef9c10f493c6b583e46af090f26dfad0eb859f2e5a30cf20
dtb_sha=cbc56da2741ae9c3b83a04c4111c9bfc31d5ca5985264fbd3434aa0597856d92
ramdisk_sha=fd45c3902bdfec6b122608e77efa00a4894a3b4502218922e593910c36c4d6f0
v41_cmdline_sha=7c88a4d3054577b7203f827950286c684759b229cce3c174e1d476320cf18f80
cmdline_sha=de6f08f3690798e6ec3b20f5ca3b4683fd9efc15dd76ea5c970366afe2aeb4b3
stamp="${HOTDOG_BUILD_STAMP:-$(date +%F-%H%M%S)}"
kernel_build="${HOTDOG_V42_KERNEL_BUILD:-$HOTDOG_ROOT/build/clearstaff-v42-clean-console}"
build_dir="$HOTDOG_ROOT/build/experiments/$stamp-clearstaff616-v42-clean-console"
outdir="$HOTDOG_ROOT/images/pmos-experiments/$stamp-clearstaff616-direct-entry-v42-clean-console"
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

for command in awk git grep llvm-nm make nproc python3 sha256sum; do
	command -v "$command" >/dev/null 2>&1 || die "missing command: $command"
done
case "$jobs" in
	''|*[!0-9]*|0) die "JOBS must be a positive integer" ;;
esac

check_sha "V39 base config" "$base_config" "$base_config_sha"
check_sha "V41 translated-IOMMU DTB" "$dtb" "$dtb_sha"
check_sha "V41 staged-USB initramfs" "$ramdisk" "$ramdisk_sha"
check_sha "V41 command line" "$v41_cmdline" "$v41_cmdline_sha"
check_sha "V42 large-font command line" "$cmdline" "$cmdline_sha"
[ ! -e "$kernel_build" ] || die "refusing to reuse kernel build: $kernel_build"
[ ! -e "$build_dir" ] || die "refusing to reuse build directory: $build_dir"
[ ! -e "$outdir" ] || die "refusing to reuse artifact directory: $outdir"

if grep -Fq HOTDOG_V39 "$source_dir/drivers/usb/dwc3/ep0.c" ||
	grep -Fq HOTDOG_V39 "$source_dir/drivers/usb/dwc3/gadget.c"; then
	die "high-frequency V39 EP0 diagnostics remain in the source"
fi
git -C "$source_dir" diff --check

mkdir -p "$kernel_build"
cp "$base_config" "$kernel_build/.config"
"$source_dir/scripts/config" --file "$kernel_build/.config" \
	--enable FONTS \
	--keep-case \
	--enable FONT_TER16x32
make -C "$source_dir" O="$kernel_build" ARCH=arm64 LLVM=1 LLVM_IAS=1 olddefconfig
grep -qx 'CONFIG_FONTS=y' "$kernel_build/.config" ||
	die "compiled-in font selection was not enabled"
grep -qx 'CONFIG_FONT_TER16x32=y' "$kernel_build/.config" ||
	die "Terminus 16x32 font was not enabled"

make -C "$source_dir" O="$kernel_build" ARCH=arm64 LLVM=1 LLVM_IAS=1 \
	-j "$jobs" Image

kernel="$kernel_build/arch/arm64/boot/Image"
vmlinux="$kernel_build/vmlinux"
python3 - "$kernel" "$vmlinux" "$v41_cmdline" "$cmdline" <<'PY'
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

source = pathlib.Path(sys.argv[3]).read_text().strip().split()
candidate = pathlib.Path(sys.argv[4]).read_text().strip().split()
expected = source.copy()
expected.insert(expected.index("fbcon=vc:1-1"), "fbcon=font:TER16x32")
if candidate != expected:
    raise SystemExit("V42 command line changes more than the fbcon font")
PY

grep -aFq TER16x32 "$kernel" || die "Terminus 16x32 font is absent from Image"
if grep -aFq HOTDOG_V39_EP0 "$kernel" ||
	grep -aFq HOTDOG_V39_EP_CMD "$kernel"; then
	die "V39 EP0 diagnostics remain in Image"
fi

mkdir -p "$build_dir"
git -C "$source_dir" diff --binary > "$build_dir/kernel-source.patch"
sha256sum "$kernel" "$vmlinux" "$kernel_build/.config" "$dtb" \
	"$ramdisk" "$v41_cmdline" "$cmdline" "$build_dir/kernel-source.patch" \
	> "$build_dir/SHA256SUMS"
cat > "$build_dir/change.txt" <<'EOF'
Kernel behavior: V41 with high-frequency EP0 command diagnostics removed.
Console: built-in Terminus 16x32 font selected with fbcon=font:TER16x32.
DTB, initramfs, and translated DWC3 IOMMU setup: byte-identical to V41.
Automatic reboot, watchdog, and recovery actions: none.
EOF

"$HOTDOG_ROOT/scripts/build-mainline-direct-bootimg.sh" \
	--kernel "$kernel" \
	--dtb "$dtb" \
	--ramdisk "$ramdisk" \
	--cmdline-file "$cmdline" \
	--outdir "$outdir" \
	--name boot-clearstaff616-direct-entry-v42-clean-console \
	--partition-size 100663296

cp "$kernel_build/.config" "$outdir/components/kernel.config"
cp "$build_dir/kernel-source.patch" "$outdir/components/"
cp "$build_dir/change.txt" "$outdir/components/"
sha256sum "$outdir/components/kernel.config" \
	"$outdir/components/kernel-source.patch" \
	"$outdir/components/change.txt" >> "$outdir/SHA256SUMS"
cat >> "$outdir/MANIFEST.md" <<EOF

## V42 clean console contract

- DTB and initramfs: byte-identical to hardware-validated V41.
- IOMMU: translated domain retained for DWC3 stream ID \`0x140\`.
- Kernel: V39 EP0 tracing removed; USB behavior unchanged.
- Console font: built-in \`TER16x32\`, selected on the command line.
- Direct-entry linked window: still exactly \`0x1ad0000\`.
- Reset behavior: entirely manual.
EOF

printf 'Kernel build: %s\nArtifact directory: %s\n' "$kernel_build" "$outdir"
sha256sum "$outdir"/boot-*.img
