#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source "$(dirname "$0")/env.sh"

v30_dir="$HOTDOG_ROOT/images/pmos-experiments/2026-08-03-190000-clearstaff616-direct-entry-v30-dynamic-pps"
kernel_build="$HOTDOG_ROOT/build/clearstaff-v32-ufs-ordering-diag"
kernel_source="$HOTDOG_ROOT/src/kernel/linux-clearstaff-hotdog"
kernel="$kernel_build/arch/arm64/boot/Image"
vmlinux="$kernel_build/vmlinux"
config="$kernel_build/.config"
ufs_source="$kernel_source/drivers/ufs/core/ufshcd.c"
dtb="$v30_dir/components/dtb"
ramdisk="$v30_dir/components/ramdisk"
cmdline="$v30_dir/components/cmdline.txt"
kernel_sha=39d25cea1c00de32d3efc9b10194558b7a45939618a6693e4f28330f631ba272
dtb_sha=1d41e88dbcbfee960eebaf9e2c306b22e43ab05c09eee2f3e5f28106b326bbd4
ramdisk_sha=e4c563fcfc6f2a3533fd16539dd22a3fc578bf858e450a9ae7f66d212ae49ec3
cmdline_sha=902b55b27a157cc6ff14ce5acd155e4b118b1754a9ba8a0707117593071df8f6
stamp="${HOTDOG_BUILD_STAMP:-$(date +%F-%H%M%S)}"
build_dir="$HOTDOG_ROOT/build/experiments/$stamp-clearstaff616-v32-ufs-ordering-diag"
outdir="$HOTDOG_ROOT/images/pmos-experiments/$stamp-clearstaff616-direct-entry-v32-ufs-ordering-diag"

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
check_sha "V30 native-panel DTB" "$dtb" "$dtb_sha"
check_sha "V30 diagnostic initramfs" "$ramdisk" "$ramdisk_sha"
check_sha "V30 kernel command line" "$cmdline" "$cmdline_sha"
[ -s "$vmlinux" ] || die "missing vmlinux: $vmlinux"
[ -s "$config" ] || die "missing kernel config: $config"
[ -s "$ufs_source" ] || die "missing UFS core source: $ufs_source"
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

grep -aFq 'V32 NOP timeout:' "$kernel" || die "V32 timeout marker is absent from Image"
grep -Fq 'dma_wmb();' "$ufs_source" || die "UFS descriptor DMA barrier is missing"
grep -Fq 'atomic_cmpxchg(&dev_cmd_timeout_dump_pending, 1, 0)' "$ufs_source" ||
	die "one-shot UFS timeout diagnostic is missing"
grep -Fq 'Match the downstream ordering before enabling UTRL and UTMRL.' "$ufs_source" ||
	die "UTRL base-address barrier is missing"

mkdir -p "$build_dir"
sha256sum "$kernel" "$vmlinux" "$config" "$ufs_source" "$dtb" "$ramdisk" "$cmdline" \
	> "$build_dir/SHA256SUMS"
cat > "$build_dir/change.txt" <<'EOF'
Kernel: V30 ClearStaff Linux 6.16 native-display baseline plus downstream-style
        UFS DMA/MMIO ordering around UTRL setup and command submission.
Diagnostics: before clearing the first timed-out NOP OUT, print controller,
             interrupt, UTRL, UIC, transfer descriptor, request UPIU, and
             response UPIU state exactly once.
DTB, initramfs, command line: byte-identical to the visually validated V30.
Automatic reboot, watchdog, and USB recovery actions: none.
EOF

"$HOTDOG_ROOT/scripts/build-mainline-direct-bootimg.sh" \
	--kernel "$kernel" \
	--dtb "$dtb" \
	--ramdisk "$ramdisk" \
	--cmdline-file "$cmdline" \
	--outdir "$outdir" \
	--name boot-clearstaff616-direct-entry-v32-ufs-ordering-diag \
	--partition-size 100663296

cp "$build_dir/change.txt" "$outdir/components/"
sha256sum "$outdir/components/change.txt" >> "$outdir/SHA256SUMS"
cat >> "$outdir/MANIFEST.md" <<EOF

## V32 UFS ordering and timeout diagnostic contract

- Kernel Image: \`$kernel_sha\`
- DTB: byte-identical to V30 native panel + TE graph (\`$dtb_sha\`)
- Initramfs: byte-identical to V30 passive diagnostic userspace (\`$ramdisk_sha\`)
- Command line: byte-identical to V30 verbose passive command line (\`$cmdline_sha\`)
- Functional delta: downstream-style UFS ordering barriers only.
- Diagnostic delta: one pre-clear dump for the first timed-out NOP OUT only.
- Reset behavior: entirely manual.
EOF

printf 'Build directory: %s\nArtifact directory: %s\n' "$build_dir" "$outdir"
