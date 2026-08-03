#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source "$(dirname "$0")/env.sh"

v40_dir="$HOTDOG_ROOT/images/pmos-experiments/2026-08-03-233000-clearstaff616-direct-entry-v40-dwc3-iommu"
kernel_build="$HOTDOG_ROOT/build/clearstaff-v39-ep0-iommu-trace"
kernel="$kernel_build/arch/arm64/boot/Image"
vmlinux="$kernel_build/vmlinux"
config="$kernel_build/.config"
dtb="$v40_dir/components/dtb"
ramdisk="$v40_dir/components/ramdisk"
source_cmdline="$v40_dir/components/cmdline.txt"
cmdline="$HOTDOG_ROOT/configs/clearstaff-hotdog-translated-iommu.cmdline"
kernel_sha=268f2ae209ab11f0840c18c69a8f2a9f11c09108f9b332ebcae599b97466cc5e
vmlinux_sha=810c751f1fd1497f0b71014db1a3a1ce4f357ae346cf23c5059fe35d068c152a
config_sha=86103671ddc29cebef9c10f493c6b583e46af090f26dfad0eb859f2e5a30cf20
dtb_sha=cbc56da2741ae9c3b83a04c4111c9bfc31d5ca5985264fbd3434aa0597856d92
ramdisk_sha=fd45c3902bdfec6b122608e77efa00a4894a3b4502218922e593910c36c4d6f0
source_cmdline_sha=902b55b27a157cc6ff14ce5acd155e4b118b1754a9ba8a0707117593071df8f6
cmdline_sha=7c88a4d3054577b7203f827950286c684759b229cce3c174e1d476320cf18f80
stamp="${HOTDOG_BUILD_STAMP:-$(date +%F-%H%M%S)}"
build_dir="$HOTDOG_ROOT/build/experiments/$stamp-clearstaff616-v41-translated-dwc3-iommu"
outdir="$HOTDOG_ROOT/images/pmos-experiments/$stamp-clearstaff616-direct-entry-v41-translated-dwc3-iommu"
dwc3=/soc@0/usb@a6f8800/usb@a600000

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

for command in awk fdtget grep llvm-nm python3 sha256sum; do
	command -v "$command" >/dev/null 2>&1 || die "missing command: $command"
done

check_sha kernel "$kernel" "$kernel_sha"
check_sha vmlinux "$vmlinux" "$vmlinux_sha"
check_sha config "$config" "$config_sha"
check_sha "V40 DWC3-IOMMU DTB" "$dtb" "$dtb_sha"
check_sha "V40 staged-USB initramfs" "$ramdisk" "$ramdisk_sha"
check_sha "V40 passthrough command line" "$source_cmdline" "$source_cmdline_sha"
check_sha "V41 translated-IOMMU command line" "$cmdline" "$cmdline_sha"
[ ! -e "$build_dir" ] || die "refusing to reuse build directory: $build_dir"
[ ! -e "$outdir" ] || die "refusing to reuse output directory: $outdir"

python3 - "$kernel" "$vmlinux" "$source_cmdline" "$cmdline" <<'PY'
import pathlib
import struct
import subprocess
import sys

image = pathlib.Path(sys.argv[1]).read_bytes()
load_offset, image_size = struct.unpack_from("<QQ", image, 8)
magic = struct.unpack_from("<I", image, 56)[0]
if load_offset != 0x80000 or image_size != 0x1AD0000:
    raise SystemExit(
        f"unexpected arm64 window: load={load_offset:#x} size={image_size:#x}"
    )
if len(image) > image_size or magic != 0x644D5241:
    raise SystemExit("invalid arm64 Image header or payload size")

symbols = {}
for line in subprocess.check_output(["llvm-nm", "-n", sys.argv[2]], text=True).splitlines():
    fields = line.split()
    if len(fields) == 3 and fields[2] in {"_text", "_end"}:
        symbols[fields[2]] = int(fields[0], 16)
if symbols.get("_end", 0) - symbols.get("_text", 0) != image_size:
    raise SystemExit("linked vmlinux window does not match the Image header")

source = pathlib.Path(sys.argv[3]).read_bytes()
translated = pathlib.Path(sys.argv[4]).read_bytes()
expected = source.replace(b"iommu.passthrough=1", b"iommu.passthrough=0")
if source.count(b"iommu.passthrough=1") != 1 or translated != expected:
    raise SystemExit("V41 command line changes more than the IOMMU domain type")
PY

[ "$(fdtget -t x "$dtb" "$dwc3" iommus)" = "2b 140 0" ] ||
	die "V40 DWC3 Apps SMMU stream is missing"
grep -qw 'iommu.passthrough=0' "$cmdline" || die "translated-IOMMU token is absent"
if grep -qw 'iommu.passthrough=1' "$cmdline"; then
	die "passthrough-IOMMU token remains present"
fi

mkdir -p "$build_dir"
sha256sum "$kernel" "$vmlinux" "$config" "$dtb" "$ramdisk" \
	"$source_cmdline" "$cmdline" > "$build_dir/SHA256SUMS"
cat > "$build_dir/change.txt" <<'EOF'
Kernel, DTB, and initramfs: byte-identical to V40.
Command line: byte-identical to V40 except iommu.passthrough changes from 1 to 0.
DWC3: remains attached to Apps SMMU stream 0x140.
UFS: remains outside the SMMU on the validated V33 DMA32 path.
Purpose: give the USB stream a translated DMA domain so event-ring writes reach RAM.
Automatic reboot, watchdog, and recovery actions: none.
EOF

"$HOTDOG_ROOT/scripts/build-mainline-direct-bootimg.sh" \
	--kernel "$kernel" \
	--dtb "$dtb" \
	--ramdisk "$ramdisk" \
	--cmdline-file "$cmdline" \
	--outdir "$outdir" \
	--name boot-clearstaff616-direct-entry-v41-translated-dwc3-iommu \
	--partition-size 100663296

cp "$source_cmdline" "$outdir/components/cmdline-v40-passthrough.txt"
cp "$build_dir/change.txt" "$outdir/components/"
sha256sum "$outdir/components/cmdline-v40-passthrough.txt" \
	"$outdir/components/change.txt" >> "$outdir/SHA256SUMS"
cat >> "$outdir/MANIFEST.md" <<EOF

## V41 translated DWC3 IOMMU contract

- Kernel Image: byte-identical to V40/V39 (\`$kernel_sha\`).
- DTB: byte-identical to V40 (\`$dtb_sha\`).
- Initramfs: byte-identical to V40/V36 (\`$ramdisk_sha\`).
- DWC3 stream: Apps SMMU stream ID \`0x140\`, flags \`0\`.
- Functional delta from V40: \`iommu.passthrough=1\` becomes \`0\`.
- Reset behavior: entirely manual.
EOF

printf 'Build directory: %s\nArtifact directory: %s\n' "$build_dir" "$outdir"
