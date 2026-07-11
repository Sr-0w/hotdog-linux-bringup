#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/env.sh"

usage() {
	cat <<'USAGE'
Usage: build-mainline-direct-bootimg.sh [options]

Build an Android boot header v2 image from an already validated mainline
Image, DTB, initramfs, and command line. This script is offline-only: it never
runs adb, fastboot, SSH, or any other phone command.

Required options:
  --kernel FILE          Raw arm64 Linux Image.
  --dtb FILE             Mainline device tree to pass to the kernel.
  --ramdisk FILE         Initramfs accepted by the kernel.
  --cmdline-file FILE    One-line kernel command line.
  --outdir DIR           New directory below images/pmos-experiments/.

Optional DTB-pack mode:
  --source-dtb-pack FILE Replace one FDT in a concatenated Android DTB pack.
  --dtb-entry N          Zero-based entry to replace. Default: 12.

Other options:
  --name NAME            Output basename. Default: boot-mainline-direct.
  --partition-size N     AVB boot partition size. Default: 100663296, as
                         observed on the tested HD1913. Verify before reuse.
  -h, --help             Show this help.

The raw NAME.img is intended for an explicit temporary `fastboot boot` test.
boot.img is a partition-sized copy with an AVB hash footer using algorithm
NONE and a filename that `avbtool verify_image` can resolve. Building either
file does not write the phone.
USAGE
}

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

note() {
	printf '[build-mainline-direct-bootimg] %s\n' "$*"
}

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

require_file() {
	[ -s "$1" ] || die "missing or empty file: $1"
}

manifest_path() {
	local path
	path="$(realpath -m "$1")"
	case "$path" in
		"$HOTDOG_ROOT"/*) printf '%s\n' "${path#"$HOTDOG_ROOT"/}" ;;
		*) printf '<external>/%s\n' "$(basename "$path")" ;;
	esac
}

kernel=""
dtb=""
ramdisk=""
cmdline_file=""
outdir=""
source_dtb_pack=""
dtb_entry=12
name="boot-mainline-direct"
partition_size=100663296

while [ "$#" -gt 0 ]; do
	case "$1" in
		--kernel)
			[ "$#" -ge 2 ] || die "--kernel requires a value"
			kernel="$2"
			shift
			;;
		--dtb)
			[ "$#" -ge 2 ] || die "--dtb requires a value"
			dtb="$2"
			shift
			;;
		--ramdisk)
			[ "$#" -ge 2 ] || die "--ramdisk requires a value"
			ramdisk="$2"
			shift
			;;
		--cmdline-file)
			[ "$#" -ge 2 ] || die "--cmdline-file requires a value"
			cmdline_file="$2"
			shift
			;;
		--outdir)
			[ "$#" -ge 2 ] || die "--outdir requires a value"
			outdir="$2"
			shift
			;;
		--source-dtb-pack)
			[ "$#" -ge 2 ] || die "--source-dtb-pack requires a value"
			source_dtb_pack="$2"
			shift
			;;
		--dtb-entry)
			[ "$#" -ge 2 ] || die "--dtb-entry requires a value"
			dtb_entry="$2"
			shift
			;;
		--name)
			[ "$#" -ge 2 ] || die "--name requires a value"
			name="$2"
			shift
			;;
		--partition-size)
			[ "$#" -ge 2 ] || die "--partition-size requires a value"
			partition_size="$2"
			shift
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			usage >&2
			die "unknown argument: $1"
			;;
	esac
	shift
done

[ -n "$kernel" ] || die "--kernel is required"
[ -n "$dtb" ] || die "--dtb is required"
[ -n "$ramdisk" ] || die "--ramdisk is required"
[ -n "$cmdline_file" ] || die "--cmdline-file is required"
[ -n "$outdir" ] || die "--outdir is required"
require_file "$kernel"
require_file "$dtb"
require_file "$ramdisk"
require_file "$cmdline_file"
if [ -n "$source_dtb_pack" ]; then
	require_file "$source_dtb_pack"
fi

case "$dtb_entry" in
	''|*[!0-9]*) die "--dtb-entry must be a non-negative integer" ;;
esac
case "$partition_size" in
	''|*[!0-9]*) die "--partition-size must be a positive integer" ;;
esac
[ "$partition_size" -gt 0 ] || die "--partition-size must be greater than zero"
case "$name" in
	''|*[!A-Za-z0-9._-]*) die "--name may contain only A-Z, a-z, 0-9, dot, underscore, and dash" ;;
esac

for command in avbtool awk cmp cp file grep python3 realpath sha256sum stat tr unpack_bootimg wc; do
	require_cmd "$command"
done
require_file "$HOTDOG_BIN_ROOT/pmbootstrap"
require_file "$HOTDOG_PMBOOTSTRAP_CONFIG"
[ -d "$HOTDOG_PMAPORTS_SM8150" ] || die "missing pmaports tree: $HOTDOG_PMAPORTS_SM8150"

artifact_root="$HOTDOG_ROOT/images/pmos-experiments"
mkdir -p "$artifact_root"
artifact_root="$(realpath -m "$artifact_root")"
outdir="$(realpath -m "$outdir")"
case "$outdir" in
	"$artifact_root"/*) ;;
	*) die "--outdir must be below $artifact_root" ;;
esac
[ ! -e "$outdir" ] || die "refusing to reuse output directory: $outdir"

cmdline="$(tr '\n' ' ' < "$cmdline_file" | awk '{$1=$1; print}')"
[ -n "$cmdline" ] || die "kernel command line is empty"
cmdline_size="$(printf '%s' "$cmdline" | wc -c | tr -d ' ')"
[ "$cmdline_size" -le 1536 ] || die "kernel command line is $cmdline_size bytes; header v2 allows 1536"

components_dir="$outdir/components"
verify_dir="$outdir/verify-unpack"
mkdir -p "$components_dir" "$verify_dir"
cp "$kernel" "$components_dir/kernel"
cp "$ramdisk" "$components_dir/ramdisk"
cp "$dtb" "$components_dir/replacement.dtb"
printf '%s\n' "$cmdline" > "$components_dir/cmdline.txt"

dtb_mode="single"
if [ -n "$source_dtb_pack" ]; then
	dtb_mode="pack-entry-$dtb_entry"
	note "replacing DTB pack entry $dtb_entry"
	python3 - "$source_dtb_pack" "$components_dir/replacement.dtb" "$components_dir/dtb" "$components_dir/original-entry.dtb" "$dtb_entry" > "$outdir/dtb-pack.txt" <<'PY'
import pathlib
import struct
import sys

source_path = pathlib.Path(sys.argv[1])
replacement_path = pathlib.Path(sys.argv[2])
output_path = pathlib.Path(sys.argv[3])
original_path = pathlib.Path(sys.argv[4])
entry_index = int(sys.argv[5])

magic = 0xD00DFEED
source = source_path.read_bytes()
replacement = replacement_path.read_bytes()

if len(replacement) < 8:
    raise SystemExit("replacement DTB is too small")
replacement_magic, replacement_size = struct.unpack(">II", replacement[:8])
if replacement_magic != magic or replacement_size != len(replacement):
    raise SystemExit("replacement is not one complete FDT")

entries = []
offset = 0
while offset < len(source):
    if offset + 8 > len(source):
        raise SystemExit(f"trailing data at offset {offset:#x}")
    entry_magic, entry_size = struct.unpack(">II", source[offset:offset + 8])
    if entry_magic != magic:
        raise SystemExit(f"bad FDT magic at offset {offset:#x}: {entry_magic:#x}")
    end = offset + entry_size
    if end > len(source):
        raise SystemExit(f"FDT at offset {offset:#x} exceeds source pack")
    entries.append(source[offset:end])
    offset = end

if entry_index >= len(entries):
    raise SystemExit(f"entry {entry_index} does not exist; pack contains {len(entries)} entries")

original_path.write_bytes(entries[entry_index])
entries[entry_index] = replacement
output_path.write_bytes(b"".join(entries))
print(f"entries={len(entries)}")
print(f"replaced_entry={entry_index}")
print(f"source_size={len(source)}")
print(f"replacement_size={len(replacement)}")
print(f"output_size={output_path.stat().st_size}")
PY
else
	cp "$components_dir/replacement.dtb" "$components_dir/dtb"
fi

raw_image="$outdir/$name.img"
avb_image="$outdir/boot.img"
pmb=(
	"$HOTDOG_BIN_ROOT/pmbootstrap"
	-c "$HOTDOG_PMBOOTSTRAP_CONFIG"
	-p "$HOTDOG_PMAPORTS_SM8150"
	-w "$HOTDOG_PMBOOTSTRAP_WORK"
	-y
)

note "ensuring mkbootimg-osm0sis is available in the native chroot"
"${pmb[@]}" chroot --add mkbootimg-osm0sis --output stdout -- true > "$outdir/pmbootstrap-mkbootimg-install.txt" 2>&1

note "building Android boot header v2 image"
host_pid="$$"
exec {kernel_fd}<"$components_dir/kernel"
exec {ramdisk_fd}<"$components_dir/ramdisk"
exec {dtb_fd}<"$components_dir/dtb"
exec {output_fd}>"$raw_image"
if ! "${pmb[@]}" chroot --output stdout -- mkbootimg-osm0sis \
	--kernel "/proc/$host_pid/fd/$kernel_fd" \
	--ramdisk "/proc/$host_pid/fd/$ramdisk_fd" \
	--cmdline "$cmdline" \
	--base 0x00000000 \
	--kernel_offset 0x00008000 \
	--ramdisk_offset 0x01000000 \
	--second_offset 0x00000000 \
	--tags_offset 0x00000100 \
	--pagesize 4096 \
	--header_version 2 \
	--dtb "/proc/$host_pid/fd/$dtb_fd" \
	--dtb_offset 0x01f00000 \
	--output "/proc/$host_pid/fd/$output_fd" \
	> "$outdir/mkbootimg.txt" 2>&1; then
	exec {kernel_fd}<&- || true
	exec {ramdisk_fd}<&- || true
	exec {dtb_fd}<&- || true
	exec {output_fd}>&- || true
	sed -n '1,200p' "$outdir/mkbootimg.txt" >&2 || true
	die "mkbootimg-osm0sis failed"
fi
exec {kernel_fd}<&-
exec {ramdisk_fd}<&-
exec {dtb_fd}<&-
exec {output_fd}>&-
require_file "$raw_image"

note "verifying extracted payloads"
unpack_bootimg --boot_img "$raw_image" --out "$verify_dir" > "$outdir/unpack.txt"
grep -q '^boot image header version: 2$' "$outdir/unpack.txt" || die "output is not boot header v2"
grep -q '^page size: 4096$' "$outdir/unpack.txt" || die "unexpected boot image page size"
grep -q '^kernel load address: 0x00008000$' "$outdir/unpack.txt" || die "unexpected kernel address"
grep -q '^ramdisk load address: 0x01000000$' "$outdir/unpack.txt" || die "unexpected ramdisk address"
grep -q '^dtb address: 0x0000000001f00000$' "$outdir/unpack.txt" || die "unexpected DTB address"
cmp "$components_dir/kernel" "$verify_dir/kernel" || die "extracted kernel differs from input"
cmp "$components_dir/ramdisk" "$verify_dir/ramdisk" || die "extracted ramdisk differs from input"
cmp "$components_dir/dtb" "$verify_dir/dtb" || die "extracted DTB differs from built payload"

note "adding AVB hash footer to partition-sized copy"
raw_sha="$(sha256sum "$raw_image" | awk '{ print $1 }')"
cp "$raw_image" "$avb_image"
avbtool add_hash_footer \
	--image "$avb_image" \
	--partition_name boot \
	--partition_size "$partition_size" \
	--algorithm NONE \
	--salt "$raw_sha"
avbtool info_image --image "$avb_image" > "$outdir/avb-info.txt"
[ "$(stat -c '%s' "$avb_image")" -eq "$partition_size" ] || die "AVB output size does not match partition size"
(
	cd "$outdir"
	avbtool verify_image --image boot.img > avb-verify.txt
)

(
	cd "$outdir"
	sha256sum \
		components/kernel \
		components/ramdisk \
		components/replacement.dtb \
		components/dtb \
		"$name.img" \
		boot.img \
		> SHA256SUMS
	file "$name.img" boot.img > file-summary.txt
)
kernel_manifest="$(manifest_path "$kernel")"
dtb_manifest="$(manifest_path "$dtb")"
ramdisk_manifest="$(manifest_path "$ramdisk")"
cmdline_manifest="$(manifest_path "$cmdline_file")"
outdir_manifest="$(manifest_path "$outdir")"
if [ -n "$source_dtb_pack" ]; then
	source_dtb_pack_manifest="$(manifest_path "$source_dtb_pack")"
else
	source_dtb_pack_manifest=""
fi
{
	printf '# Mainline direct-boot candidate\n\n'
	printf -- '- Phone operations: `none`\n'
	printf -- '- Boot header: `2`\n'
	printf -- '- DTB mode: `%s`\n' "$dtb_mode"
	if [ -n "$source_dtb_pack" ]; then
		printf -- '- DTB entry: `%s`\n' "$dtb_entry"
	fi
	printf -- '- Command-line bytes: `%s`\n' "$cmdline_size"
	printf -- '- Partition size: `%s`\n\n' "$partition_size"
	printf -- '- Deterministic AVB salt: `%s`\n\n' "$raw_sha"
	printf 'The raw image is the temporary-test artifact. The AVB image is not\n'
	printf 'flashed by this builder and requires a separate, explicit operation.\n\n'
	printf '## Inputs\n\n'
	printf -- '- Kernel: `%s`\n' "$kernel_manifest"
	printf -- '- DTB: `%s`\n' "$dtb_manifest"
	printf -- '- Ramdisk: `%s`\n' "$ramdisk_manifest"
	printf -- '- Cmdline: `%s`\n' "$cmdline_manifest"
	if [ -n "$source_dtb_pack" ]; then
		printf -- '- Source DTB pack: `%s`\n' "$source_dtb_pack_manifest"
	fi
	printf '\n## Outputs\n\n'
	printf -- '- Raw image: `%s/%s.img`\n' "$outdir_manifest" "$name"
	printf -- '- AVB image: `%s/boot.img`\n' "$outdir_manifest"
	printf -- '- Hashes: `%s/SHA256SUMS`\n' "$outdir_manifest"
} > "$outdir/MANIFEST.md"
{
	printf './scripts/build-mainline-direct-bootimg.sh '
	printf -- '--kernel %q ' "$kernel_manifest"
	printf -- '--dtb %q ' "$dtb_manifest"
	printf -- '--ramdisk %q ' "$ramdisk_manifest"
	printf -- '--cmdline-file %q ' "$cmdline_manifest"
	printf -- '--outdir %q ' "$outdir_manifest"
	if [ -n "$source_dtb_pack" ]; then
		printf -- '--source-dtb-pack %q --dtb-entry %q ' "$source_dtb_pack_manifest" "$dtb_entry"
	fi
	printf -- '--name %q --partition-size %q\n' "$name" "$partition_size"
} > "$outdir/build-command.sh"

note "done"
printf 'Raw image: %s\n' "$raw_image"
printf 'AVB image: %s\n' "$avb_image"
printf 'Manifest: %s\n' "$outdir/MANIFEST.md"
