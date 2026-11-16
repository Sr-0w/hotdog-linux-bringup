#!/bin/sh
set -eu

# boot-deploy passes the generated initramfs path to this hook. The Android
# boot image lives beside it and must fill the physical 96 MiB boot partition.
initramfs_path="${1:?missing generated initramfs path}"
work_dir="${initramfs_path%/*}"
boot_image="$work_dir/boot.img"
partition_size=100663296
info_file="$boot_image.avb-info.$$"

cleanup() {
	rm -f "$info_file"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

[ "$work_dir" != "$initramfs_path" ] || {
	echo "hotdog AVB: initramfs path has no parent directory" >&2
	exit 1
}
[ -s "$boot_image" ] || {
	echo "hotdog AVB: generated boot image is missing: $boot_image" >&2
	exit 1
}

original_size="$(stat -c '%s' "$boot_image")"
[ "$original_size" -lt "$partition_size" ] || {
	echo "hotdog AVB: raw boot image does not fit the boot partition" >&2
	exit 1
}

raw_sha="$(sha256sum "$boot_image")"
raw_sha="${raw_sha%% *}"
printf '%s\n' "$raw_sha" | grep -Eq '^[0-9a-f]{64}$' || {
	echo "hotdog AVB: invalid raw boot-image digest" >&2
	exit 1
}

avbtool add_hash_footer \
	--image "$boot_image" \
	--partition_name boot \
	--partition_size "$partition_size" \
	--algorithm NONE \
	--salt "$raw_sha"

[ "$(stat -c '%s' "$boot_image")" -eq "$partition_size" ] || {
	echo "hotdog AVB: generated image has the wrong partition size" >&2
	exit 1
}

avbtool info_image --image "$boot_image" > "$info_file"
avbtool verify_image --image "$boot_image" >/dev/null
grep -Eq '^Algorithm:[[:space:]]+NONE$' "$info_file"
grep -Eq '^[[:space:]]+Partition Name:[[:space:]]+boot$' "$info_file"
grep -Eq "^[[:space:]]+Salt:[[:space:]]+$raw_sha$" "$info_file"
grep -Eq "^Original image size:[[:space:]]+$original_size bytes$" "$info_file"

echo "hotdog AVB: wrapped $original_size-byte boot image for 96 MiB partition"
