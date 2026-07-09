#!/usr/bin/env bash
set -euo pipefail

usage() {
	cat <<'EOF'
Usage: build-appenddtb-header0-bootimg.sh --kernel Image --dtb file.dtb --ramdisk initramfs.gz --cmdline-file file --outdir DIR [options]

Build an Android boot image header v0 candidate where the kernel payload is:

  Image + DTB

No adb, fastboot, scrcpy, USB reset, or phone command is used.

Options:
  --kernel FILE          ARM64 Image payload.
  --dtb FILE             DTB appended to the Image payload.
  --ramdisk FILE         Ramdisk payload.
  --cmdline-file FILE    Kernel cmdline text file.
  --outdir DIR           New artifact directory below images/pmos-experiments/.
  --name NAME            Output basename. Default: boot-appenddtb-header0.
  --partition-size BYTES AVB boot partition size. Default: 100663296.
  -h, --help             Show this help.
EOF
}

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

note() {
	printf '[build-appenddtb-header0] %s\n' "$*"
}

require_file() {
	local path="$1"
	[ -f "$path" ] || die "missing required file: $path"
}

require_cmd() {
	local cmd="$1"
	command -v "$cmd" >/dev/null 2>&1 || die "missing required command: $cmd"
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/env.sh"

kernel=""
dtb=""
ramdisk=""
cmdline_file=""
outdir=""
name="boot-appenddtb-header0"
partition_size="100663296"

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

case "$partition_size" in
	""|*[!0-9]*)
		die "--partition-size must be a positive integer"
		;;
esac
[ "$partition_size" -gt 0 ] || die "--partition-size must be greater than zero"

artifact_root="$HOTDOG_ROOT/images/pmos-experiments"
case "$outdir" in
	"$artifact_root"/*)
		;;
	*)
		die "--outdir must be below $artifact_root"
		;;
esac
[ ! -e "$outdir" ] || die "refusing to reuse existing artifact directory: $outdir"

for cmd in avbtool cp dd mkdir sha256sum unpack_bootimg; do
	require_cmd "$cmd"
done
require_file "$HOTDOG_BIN_ROOT/pmbootstrap"
require_file "$HOTDOG_PMBOOTSTRAP_CONFIG"
[ -d "$HOTDOG_PMAPORTS_SM8150" ] || die "missing pmaports directory: $HOTDOG_PMAPORTS_SM8150"
[ -d "$HOTDOG_PMBOOTSTRAP_WORK" ] || die "missing pmbootstrap work directory: $HOTDOG_PMBOOTSTRAP_WORK"

components_dir="$outdir/components"
verify_dir="$outdir/verify-unpack"
verify_avb_dir="$outdir/verify-avb-unpack"
mkdir -p "$components_dir" "$verify_dir" "$verify_avb_dir"

append_payload="$components_dir/${name}-payload"
raw_img="$outdir/${name}.img"
avb_img="$outdir/${name}-stockos-avb.img"
cmdline="$outdir/cmdline.txt"

cp "$kernel" "$components_dir/kernel"
cp "$dtb" "$components_dir/dtb"
cp "$ramdisk" "$components_dir/ramdisk"
cp "$cmdline_file" "$cmdline"
cp "$kernel" "$append_payload"
dd if="$dtb" of="$append_payload" bs=1M oflag=append conv=notrunc status=none

pmb=(
	"$HOTDOG_BIN_ROOT/pmbootstrap"
	-c "$HOTDOG_PMBOOTSTRAP_CONFIG"
	-p "$HOTDOG_PMAPORTS_SM8150"
	-w "$HOTDOG_PMBOOTSTRAP_WORK"
	-y
)

note "building header v0 boot image"
exec {kernel_fd}<"$append_payload"
exec {ramdisk_fd}<"$components_dir/ramdisk"
exec {raw_fd}>"$raw_img"
"${pmb[@]}" chroot --output stdout -- mkbootimg \
	--kernel "/proc/$$/fd/$kernel_fd" \
	--ramdisk "/proc/$$/fd/$ramdisk_fd" \
	--cmdline "$(cat "$cmdline")" \
	--base 0x00000000 \
	--kernel_offset 0x00008000 \
	--ramdisk_offset 0x01000000 \
	--second_offset 0x00000000 \
	--tags_offset 0x00000100 \
	--pagesize 4096 \
	--header_version 0 \
	--output "/proc/$$/fd/$raw_fd" \
	> "$outdir/pmbootstrap-chroot-mkbootimg.out" 2>&1
exec {kernel_fd}<&-
exec {ramdisk_fd}<&-
exec {raw_fd}>&-

note "adding AVB hash footer"
cp "$raw_img" "$avb_img"
avbtool add_hash_footer \
	--image "$avb_img" \
	--partition_name boot \
	--partition_size "$partition_size" \
	--algorithm NONE \
	> "$outdir/avb-add-hash-footer.out" 2>&1

note "verifying boot images"
unpack_bootimg --boot_img "$raw_img" --out "$verify_dir" > "$outdir/unpack.txt"
unpack_bootimg --boot_img "$avb_img" --out "$verify_avb_dir" > "$outdir/unpack-avb.txt"
avbtool info_image --image "$avb_img" > "$outdir/avb-info.txt"

{
	printf '# hotdog append-DTB header0 boot image candidate\n\n'
	printf 'Date: %s\n\n' "$(date -Iseconds)"
	printf 'No adb, fastboot, scrcpy, USB reset, or phone command was used by this script.\n\n'
	printf '## Inputs\n\n'
	printf -- '- Kernel: `%s`\n' "$kernel"
	printf -- '- DTB: `%s`\n' "$dtb"
	printf -- '- Ramdisk: `%s`\n' "$ramdisk"
	printf -- '- Cmdline file: `%s`\n' "$cmdline_file"
	printf -- '- Partition size: `%s`\n\n' "$partition_size"
	printf '## Outputs\n\n'
	printf -- '- Raw boot image: `%s`\n' "$raw_img"
	printf -- '- AVB boot image: `%s`\n' "$avb_img"
	printf -- '- Appended payload: `%s`\n\n' "$append_payload"
	printf '## Build command\n\n'
	printf '```bash\n'
	printf '%q --kernel %q --dtb %q --ramdisk %q --cmdline-file %q --outdir %q --name %q --partition-size %q\n' \
		"$0" "$kernel" "$dtb" "$ramdisk" "$cmdline_file" "$outdir" "$name" "$partition_size"
	printf '```\n'
} > "$outdir/MANIFEST.md"

sha256sum \
	"$components_dir/kernel" \
	"$components_dir/dtb" \
	"$components_dir/ramdisk" \
	"$append_payload" \
	"$raw_img" \
	"$avb_img" \
	"$outdir/unpack.txt" \
	"$outdir/unpack-avb.txt" \
	"$outdir/avb-info.txt" \
	> "$outdir/SHA256SUMS"

note "done"
printf 'Artifact directory: %s\n' "$outdir"
printf 'Candidate boot image: %s\n' "$avb_img"
