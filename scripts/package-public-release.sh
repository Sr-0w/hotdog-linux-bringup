#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
	cat <<'USAGE'
Usage: package-public-release.sh --version VERSION --boot IMAGE --dtbo IMAGE \
  --rootfs IMAGE --apk APK --outdir DIR

Validate and package a matching OnePlus 7T Pro postmarketOS release set.
The boot image, filtered DTBO and rootfs are an atomic set: this script rejects
mismatched pmOS UUIDs, non-AVB boot/DTBO images, or APK kernel/DTB payloads that
do not match the boot image. It compresses the rootfs and splits an archive
only when it is too large for a conservative GitHub release asset limit.
USAGE
}

die() {
	printf '[public-release] ERROR: %s\n' "$*" >&2
	exit 1
}

note() {
	printf '[public-release] %s\n' "$*"
}

version=""
boot=""
dtbo=""
rootfs=""
apk=""
outdir=""

while [ "$#" -gt 0 ]; do
	case "$1" in
		--version) version="${2:-}"; shift ;;
		--boot) boot="${2:-}"; shift ;;
		--dtbo) dtbo="${2:-}"; shift ;;
		--rootfs) rootfs="${2:-}"; shift ;;
		--apk) apk="${2:-}"; shift ;;
		--outdir) outdir="${2:-}"; shift ;;
		-h|--help) usage; exit 0 ;;
		*) usage >&2; die "unknown argument: $1" ;;
	esac
	shift
done

[[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-(alpha|beta)\.[0-9]+$ ]] ||
	die "version must use vMAJOR.MINOR.PATCH-alpha.N or -beta.N"
for tool in avbtool blkid cmp e2fsck losetup partprobe sha256sum sgdisk stat tar unpack_bootimg zstd; do
	command -v "$tool" >/dev/null 2>&1 || die "missing required command: $tool"
done
for input in "$boot" "$dtbo" "$rootfs" "$apk"; do
	[ -f "$input" ] || die "missing input: $input"
	[ -s "$input" ] || die "empty input: $input"
done
[ -n "$outdir" ] || die "--outdir is required"
[ ! -e "$outdir" ] || die "output directory already exists: $outdir"

boot="$(realpath "$boot")"
dtbo="$(realpath "$dtbo")"
rootfs="$(realpath "$rootfs")"
apk="$(realpath "$apk")"
mkdir -p "$outdir/reports"

loop_dev=""
unpack_dir="$(mktemp -d "${TMPDIR:-/tmp}/hotdog-release-unpack.XXXXXX")"
apk_dir="$(mktemp -d "${TMPDIR:-/tmp}/hotdog-release-apk.XXXXXX")"
cleanup() {
	local status=$?
	trap - EXIT INT TERM
	[ -z "$loop_dev" ] || losetup --detach "$loop_dev" >/dev/null 2>&1 || true
	rm -rf "$unpack_dir" "$apk_dir"
	exit "$status"
}
trap cleanup EXIT INT TERM

avbtool verify_image --image "$boot" > "$outdir/reports/avbtool-verify.txt"
dtbo_size="$(stat -c '%s' "$dtbo")"
[ "$dtbo_size" -eq 25165824 ] ||
	die "DTBO image must fill the 24 MiB HD1913 dtbo partition"
avbtool verify_image --image "$dtbo" > "$outdir/reports/avbtool-verify-dtbo.txt"
avbtool info_image --image "$dtbo" > "$outdir/reports/avbtool-info-dtbo.txt"
grep -Eq '^[[:space:]]+Partition Name:[[:space:]]+dtbo$' \
	"$outdir/reports/avbtool-info-dtbo.txt" ||
	die "DTBO AVB descriptor does not name the dtbo partition"
unpack_bootimg --boot_img "$boot" --out "$unpack_dir" > "$outdir/reports/unpack_bootimg.txt"
cmdline="$(sed -n 's/^command line args: //p' "$outdir/reports/unpack_bootimg.txt")"
boot_uuid="$(printf '%s\n' "$cmdline" | tr ' ' '\n' | sed -n 's/^pmos_boot_uuid=//p')"
root_uuid="$(printf '%s\n' "$cmdline" | tr ' ' '\n' | sed -n 's/^pmos_root_uuid=//p')"
[[ "$boot_uuid" =~ ^[0-9a-f-]{36}$ ]] || die "boot image lacks a valid pmos_boot_uuid"
[[ "$root_uuid" =~ ^[0-9a-f-]{36}$ ]] || die "boot image lacks a valid pmos_root_uuid"

rootfs_size="$(stat -c '%s' "$rootfs")"
[ "$rootfs_size" -le 15032385536 ] ||
	die "rootfs image is larger than the validated HD1913 super partition"
loop_dev="$(losetup --read-only --find --show --sector-size 4096 "$rootfs")"
partprobe "$loop_dev" 2>/dev/null || true
part_prefix="$loop_dev"
[[ "$loop_dev" =~ [0-9]$ ]] && part_prefix="${loop_dev}p"
for partition in "${part_prefix}1" "${part_prefix}2"; do
	for _ in 1 2 3 4 5; do
		[ -b "$partition" ] && break
		sleep 1
	done
	[ -b "$partition" ] || die "partition did not appear: $partition"
done
sgdisk --verify "$loop_dev" > "$outdir/reports/gpt-verify.txt"
sgdisk --print "$loop_dev" > "$outdir/reports/gpt.txt"
boot_label="$(blkid -p -s LABEL -o value "${part_prefix}1")"
root_label="$(blkid -p -s LABEL -o value "${part_prefix}2")"
actual_boot_uuid="$(blkid -p -s UUID -o value "${part_prefix}1")"
actual_root_uuid="$(blkid -p -s UUID -o value "${part_prefix}2")"
[ "$boot_label" = "pmOS_boot" ] || die "partition 1 is not labelled pmOS_boot"
[ "$root_label" = "pmOS_root" ] || die "partition 2 is not labelled pmOS_root"
[ "$actual_boot_uuid" = "$boot_uuid" ] || die "boot UUID does not match boot command line"
[ "$actual_root_uuid" = "$root_uuid" ] || die "root UUID does not match boot command line"
e2fsck -fn "${part_prefix}1" > "$outdir/reports/e2fsck-pmOS_boot.txt" || {
	status=$?
	[ "$status" -eq 1 ] || die "pmOS_boot filesystem check failed"
}
e2fsck -fn "${part_prefix}2" > "$outdir/reports/e2fsck-pmOS_root.txt" || {
	status=$?
	[ "$status" -eq 1 ] || die "pmOS_root filesystem check failed"
}
losetup --detach "$loop_dev"
loop_dev=""

tar --warning=no-unknown-keyword -xf "$apk" -C "$apk_dir" \
	boot/vmlinuz boot/dtbs/qcom/sm8150-oneplus-hotdog.dtb .PKGINFO
apk_version="$(sed -n 's/^pkgver = //p' "$apk_dir/.PKGINFO")"
[[ "$apk_version" =~ ^6\.16\.0-r[0-9]+$ ]] || die "unexpected kernel APK version: ${apk_version:-missing}"
cmp -s "$unpack_dir/kernel" "$apk_dir/boot/vmlinuz" || die "APK kernel does not match boot image"
cmp -s "$unpack_dir/dtb" "$apk_dir/boot/dtbs/qcom/sm8150-oneplus-hotdog.dtb" ||
	die "APK hotdog DTB does not match boot image"

prefix="oneplus-7t-pro-hotdog-${version}"
boot_asset="$outdir/${prefix}-boot.img"
dtbo_asset="$outdir/${prefix}-dtbo.img"
apk_asset="$outdir/${prefix}-kernel-${apk_version}.apk"
install -m 0644 "$boot" "$boot_asset"
install -m 0644 "$dtbo" "$dtbo_asset"
install -m 0644 "$apk" "$apk_asset"
root_archive="$outdir/${prefix}-rootfs.img.zst"
note "compressing rootfs image"
zstd --no-progress --threads=0 --long=27 -19 --force -o "$root_archive" "$rootfs"

max_asset_size=$((1900 * 1024 * 1024))
split_rootfs=0
if [ "$(stat -c '%s' "$root_archive")" -gt "$max_asset_size" ]; then
	note "rootfs archive exceeds the conservative GitHub asset limit; creating parts"
	split --bytes="$max_asset_size" --numeric-suffixes=1 --suffix-length=3 \
		"$root_archive" "${root_archive}.part"
	split_rootfs=1
fi

{
	for file in "$boot_asset" "$dtbo_asset" "$apk_asset"; do
		[ -e "$file" ] || continue
		(cd "$outdir" && sha256sum "$(basename "$file")")
	done
	if [ "$split_rootfs" -eq 1 ]; then
		for file in "$root_archive".part*; do
			(cd "$outdir" && sha256sum "$(basename "$file")")
		done
	else
		(cd "$outdir" && sha256sum "$(basename "$root_archive")")
	fi
} > "$outdir/SHA256SUMS"

boot_kernel_sha="$(sha256sum "$unpack_dir/kernel" | awk '{print $1}')"
boot_dtb_sha="$(sha256sum "$unpack_dir/dtb" | awk '{print $1}')"
boot_sha="$(sha256sum "$boot_asset" | awk '{print $1}')"
dtbo_sha="$(sha256sum "$dtbo_asset" | awk '{print $1}')"
root_sha="$(sha256sum "$rootfs" | awk '{print $1}')"
cat > "$outdir/MANIFEST.md" <<EOF
# ${version} release manifest

This is an experimental postmarketOS release for the OnePlus 7T Pro HD1913
(\`hotdog\`) only. The boot image, filtered DTBO and rootfs image are an atomic
set and must not be mixed with another release.

| Property | Value |
|---|---|
| Kernel APK | \`${apk_version}\` |
| Boot image SHA-256 | \`${boot_sha}\` |
| Filtered DTBO SHA-256 | \`${dtbo_sha}\` |
| Filtered DTBO size | \`${dtbo_size}\` bytes |
| Kernel SHA-256 | \`${boot_kernel_sha}\` |
| DTB SHA-256 | \`${boot_dtb_sha}\` |
| Rootfs raw SHA-256 | \`${root_sha}\` |
| Rootfs raw size | \`${rootfs_size}\` bytes |
| pmOS_boot UUID | \`${boot_uuid}\` |
| pmOS_root UUID | \`${root_uuid}\` |

Run \`sha256sum -c SHA256SUMS\` before flashing. If the rootfs archive is split,
reassemble the parts in numeric order before decompressing it. See
\`docs/release-install.md\` in the matching source tag for the full procedure.
EOF

note "release assets prepared in $outdir"
