#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source "$(dirname "$0")/env.sh"

v33_dir="$HOTDOG_ROOT/images/pmos-experiments/2026-08-03-200000-clearstaff616-direct-entry-v33-ufs-dma32"
v36_dir="$HOTDOG_ROOT/images/pmos-experiments/2026-08-03-213000-clearstaff616-direct-entry-v36-staged-usb"
kernel_build="$HOTDOG_ROOT/build/clearstaff-v37-usb-bind-trace"
kernel="$kernel_build/arch/arm64/boot/Image"
vmlinux="$kernel_build/vmlinux"
config="$kernel_build/.config"
dtb="$v33_dir/components/dtb"
ramdisk="$v36_dir/components/ramdisk"
cmdline="$v36_dir/components/cmdline.txt"
kernel_sha=52c01b9ec3a4421e2de30e4e157d7143cdf4c73da4b82d39aa7a8d82940e451e
vmlinux_sha=e4282924b42a376ec704f98061a01ae26187d4d4ca44770d32fc721381f7510a
config_sha=86103671ddc29cebef9c10f493c6b583e46af090f26dfad0eb859f2e5a30cf20
dtb_sha=1d41e88dbcbfee960eebaf9e2c306b22e43ab05c09eee2f3e5f28106b326bbd4
ramdisk_sha=fd45c3902bdfec6b122608e77efa00a4894a3b4502218922e593910c36c4d6f0
cmdline_sha=902b55b27a157cc6ff14ce5acd155e4b118b1754a9ba8a0707117593071df8f6
stamp="${HOTDOG_BUILD_STAMP:-$(date +%F-%H%M%S)}"
build_dir="$HOTDOG_ROOT/build/experiments/$stamp-clearstaff616-v37-usb-bind-trace"
outdir="$HOTDOG_ROOT/images/pmos-experiments/$stamp-clearstaff616-direct-entry-v37-usb-bind-trace"

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
check_sha vmlinux "$vmlinux" "$vmlinux_sha"
check_sha config "$config" "$config_sha"
check_sha "V33 validated DTB" "$dtb" "$dtb_sha"
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

for marker in \
	HOTDOG_V37_CONFIGFS_REGISTER_BEGIN \
	HOTDOG_V37_NCM_BIND_RETURN=0 \
	HOTDOG_V37_UDC_START_BEGIN \
	HOTDOG_V37_PULLUP_ENTRY \
	HOTDOG_V37_SOFT_CONNECT_RESET_BEGIN \
	HOTDOG_V37_DWC3_EP0_OUT_START_BEGIN \
	HOTDOG_V37_RUN_STOP_DCTL_WRITE_BEGIN \
	HOTDOG_V37_TRB_POOL; do
	grep -aFq "$marker" "$kernel" || die "missing V37 marker: $marker"
done

mkdir -p "$build_dir"
sha256sum "$kernel" "$vmlinux" "$config" "$dtb" "$ramdisk" "$cmdline" \
	> "$build_dir/SHA256SUMS"
cat > "$build_dir/change.txt" <<'EOF'
Kernel: V35 SM8150 DWC3 32-bit DMA baseline plus diagnostic-only markers
        spanning NCM bind, configfs, UDC core, DWC3 startup, EP0, and RUN/STOP.
Diagnostics: print every DWC3 endpoint TRB-pool DMA address and both sides of
             each call or MMIO transition between configfs bind and pull-up.
DTB: byte-identical to the hardware-validated V33 artifact.
Initramfs and command line: byte-identical to V36 staged USB.
Functional USB sequencing: unchanged from V36.
Automatic reboot, watchdog, and recovery actions: none.
EOF

"$HOTDOG_ROOT/scripts/build-mainline-direct-bootimg.sh" \
	--kernel "$kernel" \
	--dtb "$dtb" \
	--ramdisk "$ramdisk" \
	--cmdline-file "$cmdline" \
	--outdir "$outdir" \
	--name boot-clearstaff616-direct-entry-v37-usb-bind-trace \
	--partition-size 100663296

cp "$build_dir/change.txt" "$outdir/components/"
sha256sum "$outdir/components/change.txt" >> "$outdir/SHA256SUMS"
cat >> "$outdir/MANIFEST.md" <<EOF

## V37 USB bind trace contract

- Kernel Image: \`$kernel_sha\`.
- DTB: byte-identical to V33 (\`$dtb_sha\`).
- Initramfs: byte-identical to V36 (\`$ramdisk_sha\`).
- Functional delta from V36: none; kernel diagnostics only.
- Diagnostic span: NCM bind through DWC3 DCTL RUN/STOP write and halt poll.
- Reset behavior: entirely manual.
EOF

printf 'Build directory: %s\nArtifact directory: %s\n' "$build_dir" "$outdir"
