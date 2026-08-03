#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
	cat <<'USAGE'
Usage: assemble-pmaports-subpartition-image.sh [options]

Assemble exact split postmarketOS boot and root filesystem images into a
deterministic two-partition GPT image. The resulting image is suitable for
postmarketOS initramfs subpartition discovery on the OnePlus 7T Pro.

Options:
  --boot-image FILE   Split pmOS_boot filesystem image.
  --root-image FILE   Split pmOS_root filesystem image.
  --outdir DIR        New output directory. It must not already exist.
  --sector-size N     Logical sector size (default: 4096).
  -h, --help          Show this help.

This is an offline assembler. It never accesses or writes a phone.
USAGE
}

die() {
	printf '[pmaports-gpt] ERROR: %s\n' "$*" >&2
	exit 1
}

note() {
	printf '[pmaports-gpt] %s\n' "$*"
}

require_command() {
	command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

guid_from_hex() {
	local value="${1:0:32}"

	[ "${#value}" -eq 32 ] || die "internal error: GUID seed is too short"
	printf '%s-%s-%s-%s-%s\n' \
		"${value:0:8}" "${value:8:4}" "${value:12:4}" \
		"${value:16:4}" "${value:20:12}"
}

boot_image=""
root_image=""
outdir=""
sector_size=4096
leading_mib=8
trailing_mib=8
loop_dev=""

cleanup() {
	local status=$?

	trap - EXIT INT TERM
	if [ -n "$loop_dev" ]; then
		sudo -n blockdev --flushbufs "$loop_dev" >/dev/null 2>&1 || true
		sudo -n losetup --detach "$loop_dev" >/dev/null 2>&1 || true
	fi
	exit "$status"
}
trap cleanup EXIT INT TERM

while [ "$#" -gt 0 ]; do
	case "$1" in
		--boot-image)
			[ "$#" -ge 2 ] || die "--boot-image requires a value"
			boot_image="$2"
			shift
			;;
		--root-image)
			[ "$#" -ge 2 ] || die "--root-image requires a value"
			root_image="$2"
			shift
			;;
		--outdir)
			[ "$#" -ge 2 ] || die "--outdir requires a value"
			outdir="$2"
			shift
			;;
		--sector-size)
			[ "$#" -ge 2 ] || die "--sector-size requires a value"
			sector_size="$2"
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

[ -n "$boot_image" ] || die "--boot-image is required"
[ -n "$root_image" ] || die "--root-image is required"
[ -n "$outdir" ] || die "--outdir is required"
[[ "$sector_size" =~ ^[0-9]+$ ]] || die "sector size must be a positive integer"
[ "$sector_size" -gt 0 ] || die "sector size must be greater than zero"

for command_name in \
	blkid blockdev dd grep losetup mkdir partprobe readlink realpath \
	sgdisk sha256sum stat sudo sync tee truncate udevadm; do
	require_command "$command_name"
done
sudo -n true >/dev/null 2>&1 || die "passwordless sudo is required for loop setup"

boot_image="$(realpath -- "$boot_image")"
root_image="$(realpath -- "$root_image")"
outdir="$(realpath -m -- "$outdir")"
[ -f "$boot_image" ] || die "boot image not found: $boot_image"
[ -s "$boot_image" ] || die "boot image is empty: $boot_image"
[ -f "$root_image" ] || die "root image not found: $root_image"
[ -s "$root_image" ] || die "root image is empty: $root_image"
[ ! -e "$outdir" ] || die "output path already exists: $outdir"

boot_type="$(blkid -p -s TYPE -o value "$boot_image" 2>/dev/null || true)"
boot_label="$(blkid -p -s LABEL -o value "$boot_image" 2>/dev/null || true)"
boot_uuid="$(blkid -p -s UUID -o value "$boot_image" 2>/dev/null || true)"
root_type="$(blkid -p -s TYPE -o value "$root_image" 2>/dev/null || true)"
root_label="$(blkid -p -s LABEL -o value "$root_image" 2>/dev/null || true)"
root_uuid="$(blkid -p -s UUID -o value "$root_image" 2>/dev/null || true)"

case "$boot_type" in
	ext2|ext3|ext4) ;;
	*) die "pmOS_boot must be an ext filesystem, got: ${boot_type:-unknown}" ;;
esac
[ "$boot_label" = "pmOS_boot" ] || die "unexpected boot label: ${boot_label:-missing}"
[ "$root_type" = "ext4" ] || die "pmOS_root must be ext4, got: ${root_type:-unknown}"
[ "$root_label" = "pmOS_root" ] || die "unexpected root label: ${root_label:-missing}"
[[ "$boot_uuid" =~ ^[0-9a-f-]{36}$ ]] || die "malformed boot filesystem UUID"
[[ "$root_uuid" =~ ^[0-9a-f-]{36}$ ]] || die "malformed root filesystem UUID"
[ "$boot_uuid" != "$root_uuid" ] || die "boot and root filesystem UUIDs must differ"

boot_size="$(stat -c '%s' "$boot_image")"
root_size="$(stat -c '%s' "$root_image")"
[ $((boot_size % sector_size)) -eq 0 ] || die "boot image is not sector aligned"
[ $((root_size % sector_size)) -eq 0 ] || die "root image is not sector aligned"

leading_bytes=$((leading_mib * 1024 * 1024))
trailing_bytes=$((trailing_mib * 1024 * 1024))
[ $((leading_bytes % sector_size)) -eq 0 ] || die "leading gap is not sector aligned"
[ $((trailing_bytes % sector_size)) -eq 0 ] || die "trailing gap is not sector aligned"

boot_start=$((leading_bytes / sector_size))
boot_sectors=$((boot_size / sector_size))
root_start=$((boot_start + boot_sectors))
root_sectors=$((root_size / sector_size))
total_sectors=$((root_start + root_sectors + trailing_bytes / sector_size))
total_size=$((total_sectors * sector_size))

boot_sha="$(sha256sum "$boot_image")"
boot_sha="${boot_sha%% *}"
root_sha="$(sha256sum "$root_image")"
root_sha="${root_sha%% *}"
disk_seed="$(printf 'hotdog-pmaports-disk\n%s\n%s\n' "$boot_sha" "$root_sha" | sha256sum)"
boot_seed="$(printf 'hotdog-pmaports-boot\n%s\n' "$boot_sha" | sha256sum)"
root_seed="$(printf 'hotdog-pmaports-root\n%s\n' "$root_sha" | sha256sum)"
disk_guid="$(guid_from_hex "${disk_seed%% *}")"
boot_guid="$(guid_from_hex "${boot_seed%% *}")"
root_guid="$(guid_from_hex "${root_seed%% *}")"

mkdir -p "$outdir"
image="$outdir/oneplus-hotdog.img"
truncate -s "$total_size" "$image"

note "creating deterministic 4K-sector GPT"
loop_dev="$(sudo -n losetup --find --show --sector-size "$sector_size" "$image")"
sudo -n sgdisk \
	--clear \
	--set-alignment=1 \
	--disk-guid="$disk_guid" \
	--new="1:${boot_start}:+${boot_sectors}" \
	--typecode="1:c12a7328-f81f-11d2-ba4b-00a0c93ec93b" \
	--change-name="1:pmOS_boot" \
	--partition-guid="1:$boot_guid" \
	--new="2:${root_start}:+${root_sectors}" \
	--typecode="2:b921b045-1df0-41c3-af44-4c6f280d3fae" \
	--change-name="2:pmOS_root" \
	--partition-guid="2:$root_guid" \
	"$loop_dev" >/dev/null
sudo -n partprobe "$loop_dev"
sudo -n udevadm settle

partition_prefix="$loop_dev"
[[ "$loop_dev" =~ [0-9]$ ]] && partition_prefix="${loop_dev}p"
boot_partition="${partition_prefix}1"
root_partition="${partition_prefix}2"

for partition in "$boot_partition" "$root_partition"; do
	for _ in 1 2 3 4 5; do
		[ -b "$partition" ] && break
		sleep 1
	done
	[ -b "$partition" ] || die "partition device did not appear: $partition"
done

[ "$(sudo -n blockdev --getsize64 "$boot_partition")" -eq "$boot_size" ] ||
	die "generated boot partition has the wrong size"
[ "$(sudo -n blockdev --getsize64 "$root_partition")" -eq "$root_size" ] ||
	die "generated root partition has the wrong size"

note "copying exact pmOS_boot filesystem"
sudo -n dd if="$boot_image" of="$boot_partition" bs=16M iflag=fullblock \
	conv=fsync status=progress
note "copying exact pmOS_root filesystem"
sudo -n dd if="$root_image" of="$root_partition" bs=16M iflag=fullblock \
	conv=fsync status=progress
sudo -n blockdev --flushbufs "$loop_dev"
sync

boot_readback_sha="$(sudo -n dd if="$boot_partition" bs=16M iflag=fullblock status=none | sha256sum)"
boot_readback_sha="${boot_readback_sha%% *}"
root_readback_sha="$(sudo -n dd if="$root_partition" bs=16M iflag=fullblock status=none | sha256sum)"
root_readback_sha="${root_readback_sha%% *}"
[ "$boot_readback_sha" = "$boot_sha" ] || die "pmOS_boot partition readback mismatch"
[ "$root_readback_sha" = "$root_sha" ] || die "pmOS_root partition readback mismatch"

sudo -n blkid -p "$boot_partition" "$root_partition" |
	tee "$outdir/blkid.txt" >/dev/null
grep -q 'LABEL="pmOS_boot"' "$outdir/blkid.txt" || die "boot label missing after assembly"
grep -q "UUID=\"$boot_uuid\"" "$outdir/blkid.txt" || die "boot UUID changed after assembly"
grep -q 'LABEL="pmOS_root"' "$outdir/blkid.txt" || die "root label missing after assembly"
grep -q "UUID=\"$root_uuid\"" "$outdir/blkid.txt" || die "root UUID changed after assembly"
sudo -n sgdisk --verify "$loop_dev" | tee "$outdir/gpt-verify.txt" >/dev/null
sudo -n sgdisk --print "$loop_dev" | tee "$outdir/gpt.txt" >/dev/null
sudo -n sgdisk --info=1 "$loop_dev" | tee "$outdir/gpt-partition-1.txt" >/dev/null
sudo -n sgdisk --info=2 "$loop_dev" | tee "$outdir/gpt-partition-2.txt" >/dev/null

sudo -n losetup --detach "$loop_dev"
loop_dev=""
image_sha="$(sha256sum "$image")"
image_sha="${image_sha%% *}"

cat > "$outdir/SHA256SUMS" <<EOF
$image_sha  oneplus-hotdog.img
EOF

cat > "$outdir/README.md" <<EOF
# OnePlus 7T Pro staged postmarketOS subpartition image

- Disk image SHA256: \`$image_sha\`
- Disk image size: \`$total_size\` bytes
- Logical sector size: \`$sector_size\` bytes
- Disk GUID: \`$disk_guid\`
- pmOS_boot SHA256: \`$boot_sha\`
- pmOS_boot UUID: \`$boot_uuid\`
- pmOS_root SHA256: \`$root_sha\`
- pmOS_root UUID: \`$root_uuid\`

Both partition payloads passed complete readback hashing. The GPT contains
exactly two partitions and passed \`sgdisk --verify\`. This is offline build
evidence, not proof of a hardware write or boot.
EOF

note "pmOS_boot SHA256: $boot_sha"
note "pmOS_root SHA256: $root_sha"
note "disk image SHA256: $image_sha"
note "disk image size: $total_size bytes"
note "output: $outdir"
