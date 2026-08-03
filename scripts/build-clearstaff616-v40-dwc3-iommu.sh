#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source "$(dirname "$0")/env.sh"

v33_dir="$HOTDOG_ROOT/images/pmos-experiments/2026-08-03-200000-clearstaff616-direct-entry-v33-ufs-dma32"
v36_dir="$HOTDOG_ROOT/images/pmos-experiments/2026-08-03-213000-clearstaff616-direct-entry-v36-staged-usb"
kernel_build="$HOTDOG_ROOT/build/clearstaff-v39-ep0-iommu-trace"
kernel="$kernel_build/arch/arm64/boot/Image"
vmlinux="$kernel_build/vmlinux"
config="$kernel_build/.config"
base_dtb="$v33_dir/components/dtb"
overlay_source="$HOTDOG_ROOT/configs/clearstaff-hotdog-dwc3-iommu-overlay.dts"
d7_overlay="$HOTDOG_ROOT/images/pmos-experiments/2026-07-31-014429-d7-mainline-native-ufs/components/filtered-entry5.dtbo"
ramdisk="$v36_dir/components/ramdisk"
cmdline="$v36_dir/components/cmdline.txt"
kernel_sha=268f2ae209ab11f0840c18c69a8f2a9f11c09108f9b332ebcae599b97466cc5e
vmlinux_sha=810c751f1fd1497f0b71014db1a3a1ce4f357ae346cf23c5059fe35d068c152a
config_sha=86103671ddc29cebef9c10f493c6b583e46af090f26dfad0eb859f2e5a30cf20
base_dtb_sha=1d41e88dbcbfee960eebaf9e2c306b22e43ab05c09eee2f3e5f28106b326bbd4
overlay_source_sha=74e7fc915f839c9d9a44030b3de4ea63d023d6f098c12f04451a28f5e3d8bfdd
d7_overlay_sha=f667f356ec70b5cb3950615a13a3e66dd58eebf86046239c6e476c117a6821aa
ramdisk_sha=fd45c3902bdfec6b122608e77efa00a4894a3b4502218922e593910c36c4d6f0
cmdline_sha=902b55b27a157cc6ff14ce5acd155e4b118b1754a9ba8a0707117593071df8f6
stamp="${HOTDOG_BUILD_STAMP:-$(date +%F-%H%M%S)}"
build_dir="$HOTDOG_ROOT/build/experiments/$stamp-clearstaff616-v40-dwc3-iommu"
outdir="$HOTDOG_ROOT/images/pmos-experiments/$stamp-clearstaff616-direct-entry-v40-dwc3-iommu"
overlay="$build_dir/hotdog-dwc3-iommu.dtbo"
dtb="$build_dir/hotdog-v40-dwc3-iommu.dtb"
effective_dtb="$build_dir/hotdog-v40-dwc3-iommu-d7-effective.dtb"
dwc3=/soc@0/usb@a6f8800/usb@a600000
ufs=/soc@0/ufshc@1d84000
apps_smmu=/soc@0/iommu@15000000

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

for command in awk dtc fdtget fdtoverlay grep llvm-nm python3 sha256sum; do
	command -v "$command" >/dev/null 2>&1 || die "missing command: $command"
done

check_sha kernel "$kernel" "$kernel_sha"
check_sha vmlinux "$vmlinux" "$vmlinux_sha"
check_sha config "$config" "$config_sha"
check_sha "V33 validated DTB" "$base_dtb" "$base_dtb_sha"
check_sha "DWC3 IOMMU overlay source" "$overlay_source" "$overlay_source_sha"
check_sha "D7 filtered bootloader overlay" "$d7_overlay" "$d7_overlay_sha"
check_sha "V36 staged-USB initramfs" "$ramdisk" "$ramdisk_sha"
check_sha "V36 kernel command line" "$cmdline" "$cmdline_sha"
[ ! -e "$build_dir" ] || die "refusing to reuse build directory: $build_dir"
[ ! -e "$outdir" ] || die "refusing to reuse output directory: $outdir"

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
PY

grep -aFq HOTDOG_V39_EP_CMD_FIRST_POLL "$kernel" ||
	die "V39 EP0 diagnostic kernel is missing"
grep -aFq HOTDOG_V39_IOMMU_DEVICE_PROBE_FAIL "$kernel" ||
	die "V39 IOMMU diagnostic kernel is missing"
if fdtget "$base_dtb" "$dwc3" iommus >/dev/null 2>&1; then
	die "V33 base unexpectedly already contains DWC3 iommus"
fi
if fdtget "$base_dtb" "$ufs" iommus >/dev/null 2>&1; then
	die "V33 base unexpectedly contains UFS iommus"
fi

mkdir -p "$build_dir"
dtc -@ -I dts -O dtb -o "$overlay" "$overlay_source"
fdtoverlay -i "$base_dtb" -o "$dtb" "$overlay"
fdtoverlay -i "$dtb" -o "$effective_dtb" "$d7_overlay"

for tree in "$dtb" "$effective_dtb"; do
	[ "$(fdtget -t x "$tree" "$apps_smmu" phandle)" = 2b ] ||
		die "Apps SMMU phandle changed in $tree"
	[ "$(fdtget -t x "$tree" "$dwc3" iommus)" = "2b 140 0" ] ||
		die "DWC3 stream 0x140 is not attached to Apps SMMU in $tree"
	if fdtget "$tree" "$ufs" iommus >/dev/null 2>&1; then
		die "UFS must remain on the validated V33 DMA32 path in $tree"
	fi
done

sha256sum "$kernel" "$vmlinux" "$config" "$base_dtb" "$overlay_source" \
	"$overlay" "$dtb" "$d7_overlay" "$effective_dtb" "$ramdisk" "$cmdline" \
	> "$build_dir/SHA256SUMS"
cat > "$build_dir/change.txt" <<'EOF'
Kernel, initramfs, and command line: byte-identical to V39.
DTB: V33 hardware-validated graph plus the upstream SM8150 DWC3 IOMMU binding,
     iommus = <&apps_smmu 0x140 0>.
D7 bootloader overlay: replayed offline; the USB binding remains intact.
UFS: deliberately remains on the V33 no-iommus DMA32 path.
Purpose: test whether the EP0 STARTTRANSFER crash is an unmapped USB DMA stream.
Automatic reboot, watchdog, and recovery actions: none.
EOF

"$HOTDOG_ROOT/scripts/build-mainline-direct-bootimg.sh" \
	--kernel "$kernel" \
	--dtb "$dtb" \
	--ramdisk "$ramdisk" \
	--cmdline-file "$cmdline" \
	--outdir "$outdir" \
	--name boot-clearstaff616-direct-entry-v40-dwc3-iommu \
	--partition-size 100663296

cp "$overlay_source" "$overlay" "$effective_dtb" "$build_dir/change.txt" \
	"$outdir/components/"
sha256sum \
	"$outdir/components/$(basename "$overlay_source")" \
	"$outdir/components/$(basename "$overlay")" \
	"$outdir/components/$(basename "$effective_dtb")" \
	"$outdir/components/change.txt" >> "$outdir/SHA256SUMS"
cat >> "$outdir/MANIFEST.md" <<EOF

## V40 DWC3 IOMMU contract

- Kernel Image: byte-identical to V39 (\`$kernel_sha\`).
- Base DTB: byte-identical to V33 (\`$base_dtb_sha\`).
- DWC3 stream: Apps SMMU stream ID \`0x140\`, flags \`0\`.
- Effective DTB: D7 overlay replayed and checked offline.
- UFS: unchanged no-\`iommus\` V33 DMA32 path.
- Functional delta from V39: restore only the upstream DWC3 \`iommus\` property.
- Reset behavior: entirely manual.
EOF

printf 'Build directory: %s\nArtifact directory: %s\n' "$build_dir" "$outdir"
