#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source "$(dirname "$0")/env.sh"

v33_dir="$HOTDOG_ROOT/images/pmos-experiments/2026-08-03-200000-clearstaff616-direct-entry-v33-ufs-dma32"
v34_dir="$HOTDOG_ROOT/images/pmos-experiments/2026-08-03-203000-clearstaff616-direct-entry-v34-active-usb"
kernel_build="$HOTDOG_ROOT/build/clearstaff-v35-dwc3-dma32"
kernel_source="$HOTDOG_ROOT/src/kernel/linux-clearstaff-hotdog"
kernel="$kernel_build/arch/arm64/boot/Image"
vmlinux="$kernel_build/vmlinux"
config="$kernel_build/.config"
dwc3_core_source="$kernel_source/drivers/usb/dwc3/core.c"
dwc3_gadget_source="$kernel_source/drivers/usb/dwc3/gadget.c"
dtb="$v33_dir/components/dtb"
ramdisk="$v34_dir/components/ramdisk"
cmdline="$v34_dir/components/cmdline.txt"
kernel_sha=ebd7d558483e9ba4c9a99099898020f3318ca80cb95e573142cbb278a489cf83
dtb_sha=1d41e88dbcbfee960eebaf9e2c306b22e43ab05c09eee2f3e5f28106b326bbd4
ramdisk_sha=61df0f48215412774bbbaa87fdc19ad64ca6c062f3724b74d1cbc508eb1df443
cmdline_sha=902b55b27a157cc6ff14ce5acd155e4b118b1754a9ba8a0707117593071df8f6
stamp="${HOTDOG_BUILD_STAMP:-$(date +%F-%H%M%S)}"
build_dir="$HOTDOG_ROOT/build/experiments/$stamp-clearstaff616-v35-dwc3-dma32"
outdir="$HOTDOG_ROOT/images/pmos-experiments/$stamp-clearstaff616-direct-entry-v35-dwc3-dma32"

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

for command in awk grep llvm-nm python3 sha256sum; do
	command -v "$command" >/dev/null 2>&1 || die "missing command: $command"
done

check_sha kernel "$kernel" "$kernel_sha"
check_sha "V33 validated DTB" "$dtb" "$dtb_sha"
check_sha "V34 active-USB initramfs" "$ramdisk" "$ramdisk_sha"
check_sha "V34 kernel command line" "$cmdline" "$cmdline_sha"
[ -s "$vmlinux" ] || die "missing vmlinux: $vmlinux"
[ -s "$config" ] || die "missing kernel config: $config"
[ ! -e "$build_dir" ] || die "refusing to reuse build directory: $build_dir"
[ ! -e "$outdir" ] || die "refusing to reuse output directory: $outdir"

python3 - "$kernel" "$vmlinux" <<'PY'
import pathlib
import struct
import subprocess
import sys

image = pathlib.Path(sys.argv[1]).read_bytes()
if len(image) < 64:
    raise SystemExit("arm64 Image is shorter than its header")
load_offset, image_size = struct.unpack_from("<QQ", image, 8)
magic = struct.unpack_from("<I", image, 56)[0]
if load_offset != 0x80000:
    raise SystemExit(f"unexpected arm64 load offset: {load_offset:#x}")
if image_size != 0x1AD0000:
    raise SystemExit(f"unexpected arm64 image size: {image_size:#x}")
if len(image) > image_size:
    raise SystemExit(f"kernel exceeds declared image window: {len(image)} > {image_size}")
if magic != 0x644D5241:
    raise SystemExit(f"bad arm64 Image magic: {magic:#x}")

symbols = {}
for line in subprocess.check_output(["llvm-nm", "-n", sys.argv[2]], text=True).splitlines():
    fields = line.split()
    if len(fields) == 3 and fields[2] in {"_text", "_end"}:
        symbols[fields[2]] = int(fields[0], 16)
linked_size = symbols.get("_end", 0) - symbols.get("_text", 0)
if linked_size != image_size:
    raise SystemExit(
        f"linked image window {linked_size:#x} does not match header {image_size:#x}"
    )
PY

grep -aFq 'V33 UFS DMA mask forced to 32-bit' "$kernel" ||
	die "validated V33 UFS DMA fix is absent"
grep -aFq 'V35 DWC3 DMA mask forced to 32-bit' "$kernel" ||
	die "V35 DWC3 DMA-mask marker is absent"
grep -aFq 'V35 DWC3 event buffer DMA=' "$kernel" ||
	die "V35 event-buffer marker is absent"
grep -aFq 'V35 DWC3 gadget DMA ep0=' "$kernel" ||
	die "V35 gadget-buffer marker is absent"
grep -Fq 'of_device_is_compatible(parent, "qcom,sm8150-dwc3")' "$dwc3_core_source" ||
	die "SM8150 parent guard is absent"
grep -Fq '!dwc->dev->of_node' "$dwc3_core_source" ||
	die "DWC3 OF-node guard is absent"

mkdir -p "$build_dir"
sha256sum "$kernel" "$vmlinux" "$config" "$dwc3_core_source" \
	"$dwc3_gadget_source" "$dtb" "$ramdisk" "$cmdline" > "$build_dir/SHA256SUMS"
cat > "$build_dir/change.txt" <<'EOF'
Kernel: hardware-validated V33 direct-mainline rootfs baseline plus a narrowly
        scoped 32-bit coherent DMA mask for the SM8150 DWC3 child only when
        the temporary bring-up DT has no iommus property.
Diagnostics: print DWC3 event, EP0, and bounce coherent DMA addresses.
DTB: byte-identical to the hardware-validated V33 artifact.
Initramfs and command line: byte-identical to V34 bounded active USB.
Automatic reboot, watchdog, and recovery actions: none.
EOF

"$HOTDOG_ROOT/scripts/build-mainline-direct-bootimg.sh" \
	--kernel "$kernel" \
	--dtb "$dtb" \
	--ramdisk "$ramdisk" \
	--cmdline-file "$cmdline" \
	--outdir "$outdir" \
	--name boot-clearstaff616-direct-entry-v35-dwc3-dma32 \
	--partition-size 100663296

cp "$build_dir/change.txt" "$outdir/components/"
sha256sum "$outdir/components/change.txt" >> "$outdir/SHA256SUMS"
cat >> "$outdir/MANIFEST.md" <<EOF

## V35 SM8150 DWC3 SMMU-bypass DMA contract

- Kernel Image: \`$kernel_sha\`.
- DTB: byte-identical to V33 (\`$dtb_sha\`).
- Initramfs: byte-identical to V34 bounded active USB (\`$ramdisk_sha\`).
- Command line: byte-identical to V34 (\`$cmdline_sha\`).
- Functional delta: force 32-bit coherent DMA for the SM8150 DWC3 child without \`iommus\`.
- Diagnostic delta: print allocated event, EP0, and bounce DMA addresses.
- Reset behavior: entirely manual.
EOF

printf 'Build directory: %s\nArtifact directory: %s\n' "$build_dir" "$outdir"
