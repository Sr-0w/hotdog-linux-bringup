#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=/dev/null
source "$(dirname "$0")/env.sh"
# shellcheck source=/dev/null
source "$(dirname "$0")/phone-lock.sh"

PMOS_HOST="${PMOS_HOST:-$HOTDOG_PMOS_HOST}"
PMOS_USER="${PMOS_USER:-$HOTDOG_PMOS_USER}"
PMOS_PASSWORD="${PMOS_PASSWORD:-$HOTDOG_PMOS_PASSWORD}"
SERIAL="${ANDROID_SERIAL:-$HOTDOG_TARGET_SERIAL}"
IMAGE=""
IMAGE_EXPECTED_SHA256=""
EXPECTED_SOURCE_BOOT_ID=""
EXPECTED_SOURCE_KERNEL=""
REMOTE_DIR=""
KEEP_REMOTE=0
CONFIRM_SUPER_WRITE=0
LOCK_WAIT_SEC="${LOCK_WAIT_SEC:-0}"
REMOTE_SUDO_MODE=""
REMOTE_WORK_CREATED=0
WRITE_COMPLETED=0

usage() {
	cat <<'USAGE'
Usage: stage-super-rootfs-from-pmos-ssh.sh --image rootfs.raw.img \
  --image-sha256 SHA256 --expected-source-boot-id ID \
  --expected-source-kernel RELEASE --confirm-super-write [options]

Stage a raw postmarketOS disk image through an already-running hotdog system,
write it only to the physical partition named "super", and verify every written
byte by SHA-256 readback. The script never reboots the phone.

Required safeguards:
  --image FILE                 Raw 4096-byte-sector GPT image.
  --image-sha256 SHA           Exact local, staged and readback SHA-256.
  --expected-source-boot-id ID Exact source boot ID.
  --expected-source-kernel REL Exact source uname -r.
  --confirm-super-write        Acknowledge that super will be overwritten.

Options:
  --host HOST                  postmarketOS SSH host. Default: 172.16.42.1.
  --user USER                  SSH user. Default: user.
  --password PASS              SSH password. Defaults to PMOS_PASSWORD.
  --serial SERIAL              Expected androidboot.serialno.
  --remote-dir DIR             Staging directory below ~/.cache.
  --keep-remote                Keep the staged image after successful verify.
  --lock-wait SEC              Seconds to wait for the phone-operation lock.
  -h, --help                   Show this help.
USAGE
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--image)
			[ "$#" -ge 2 ] || { echo "Missing value for --image" >&2; exit 2; }
			IMAGE="$2"
			shift
			;;
		--image-sha256)
			[ "$#" -ge 2 ] || { echo "Missing value for --image-sha256" >&2; exit 2; }
			IMAGE_EXPECTED_SHA256="${2,,}"
			shift
			;;
		--expected-source-boot-id)
			[ "$#" -ge 2 ] || { echo "Missing value for --expected-source-boot-id" >&2; exit 2; }
			EXPECTED_SOURCE_BOOT_ID="$2"
			shift
			;;
		--expected-source-kernel)
			[ "$#" -ge 2 ] || { echo "Missing value for --expected-source-kernel" >&2; exit 2; }
			EXPECTED_SOURCE_KERNEL="$2"
			shift
			;;
		--host)
			[ "$#" -ge 2 ] || { echo "Missing value for --host" >&2; exit 2; }
			PMOS_HOST="$2"
			shift
			;;
		--user)
			[ "$#" -ge 2 ] || { echo "Missing value for --user" >&2; exit 2; }
			PMOS_USER="$2"
			shift
			;;
		--password)
			[ "$#" -ge 2 ] || { echo "Missing value for --password" >&2; exit 2; }
			PMOS_PASSWORD="$2"
			shift
			;;
		--serial)
			[ "$#" -ge 2 ] || { echo "Missing value for --serial" >&2; exit 2; }
			SERIAL="$2"
			shift
			;;
		--remote-dir)
			[ "$#" -ge 2 ] || { echo "Missing value for --remote-dir" >&2; exit 2; }
			REMOTE_DIR="$2"
			shift
			;;
		--keep-remote)
			KEEP_REMOTE=1
			;;
		--confirm-super-write)
			CONFIRM_SUPER_WRITE=1
			;;
		--lock-wait)
			[ "$#" -ge 2 ] || { echo "Missing value for --lock-wait" >&2; exit 2; }
			LOCK_WAIT_SEC="$2"
			shift
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			echo "Unknown argument: $1" >&2
			usage >&2
			exit 2
			;;
	esac
	shift
done

stamp="$(date +%F-%H%M%S)"
run_dir="$HOTDOG_LOG_ROOT/stage-super-rootfs-from-pmos-ssh-$stamp"
mkdir -p "$run_dir"
exec > >(tee "$run_dir/run.log") 2>&1

log() {
	printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

die() {
	log "ERROR: $1"
	exit "${2:-1}"
}

cleanup() {
	phone_lock_release || true
	if [ "$REMOTE_WORK_CREATED" -eq 1 ] && [ "$WRITE_COMPLETED" -eq 0 ]; then
		log "Staged data was retained after failure for diagnosis: $REMOTE_DIR"
	fi
}
trap cleanup EXIT

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || die "Missing command: $1" 127
}

remote_quote() {
	local value="$1"
	printf "'%s'" "${value//\'/\'\\\'\'}"
}

ssh_base() {
	SSHPASS="$PMOS_PASSWORD" sshpass -e ssh \
		-o StrictHostKeyChecking=no \
		-o UserKnownHostsFile="$run_dir/known_hosts" \
		-o ConnectTimeout=8 \
		-o ServerAliveInterval=10 \
		-o ServerAliveCountMax=3 \
		-o PreferredAuthentications=password \
		-o PubkeyAuthentication=no \
		"$PMOS_USER@$PMOS_HOST" "$@"
}

remote_run() {
	ssh_base "$@"
}

detect_remote_sudo_mode() {
	if remote_run 'sudo -n true' >/dev/null 2>&1; then
		REMOTE_SUDO_MODE="noninteractive"
	elif printf '%s\n' "$PMOS_PASSWORD" |
		remote_run "sudo -S -p '' true" >/dev/null 2>&1; then
		REMOTE_SUDO_MODE="password"
	else
		die "Remote sudo authentication failed" 3
	fi
	log "Remote sudo mode: $REMOTE_SUDO_MODE"
}

remote_sudo_sh() {
	local script="$1"

	case "$REMOTE_SUDO_MODE" in
		noninteractive)
			remote_run "sudo -n sh -c $(remote_quote "$script")"
			;;
		password)
			printf '%s\n' "$PMOS_PASSWORD" |
				remote_run "sudo -S -p '' sh -c $(remote_quote "$script")"
			;;
		*)
			die "Remote sudo mode was not initialized" 3
			;;
	esac
}

assert_remote_identity() {
	remote_run \
		"EXPECTED_SERIAL=$(remote_quote "$SERIAL") EXPECTED_BOOT_ID=$(remote_quote "$EXPECTED_SOURCE_BOOT_ID") EXPECTED_KERNEL=$(remote_quote "$EXPECTED_SOURCE_KERNEL") sh -s" \
		<<'REMOTE_IDENTITY'
set -eu

expected_serial="${EXPECTED_SERIAL:?}"
expected_boot_id="${EXPECTED_BOOT_ID:?}"
expected_kernel="${EXPECTED_KERNEL:?}"
cmdline="$(cat /proc/cmdline 2>/dev/null || true)"
boot_id="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)"
kernel="$(uname -r 2>/dev/null || true)"

case " $cmdline " in
	*" androidboot.serialno=$expected_serial "*) ;;
	*) printf 'serial mismatch\n' >&2; exit 1 ;;
esac

for token in \
	androidboot.project_codename=hotdog \
	androidboot.prjname=19801 \
	androidboot.platform_name=SM8150 \
	androidboot.oplus.brand=OnePlus
do
	case " $cmdline " in
		*" $token "*) ;;
		*) printf 'missing identity token: %s\n' "$token" >&2; exit 1 ;;
	esac
done

[ "$boot_id" = "$expected_boot_id" ] || {
	printf 'boot ID mismatch: expected %s, got %s\n' "$expected_boot_id" "$boot_id" >&2
	exit 1
}
[ "$kernel" = "$expected_kernel" ] || {
	printf 'kernel mismatch: expected %s, got %s\n' "$expected_kernel" "$kernel" >&2
	exit 1
}

printf 'identity-ok boot_id=%s kernel=%s\n' "$boot_id" "$kernel"
REMOTE_IDENTITY
}

validate_local_gpt() {
	local dump="$run_dir/rootfs-gpt.txt"
	local partition_count=""

	sfdisk --sector-size 4096 -d "$IMAGE" > "$dump" 2> "$run_dir/rootfs-gpt.stderr" ||
		die "Could not parse the raw image as a 4096-byte-sector GPT" 4
	grep -Fxq 'label: gpt' "$dump" || die "Rootfs image is not GPT" 4
	grep -Fxq 'sector-size: 4096' "$dump" || die "Rootfs GPT does not use 4096-byte sectors" 4
	partition_count="$(grep -c ' : start=' "$dump")"
	[ "$partition_count" -eq 2 ] || die "Expected two nested rootfs partitions, found $partition_count" 4
	grep -Fq 'type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B' "$dump" ||
		die "Rootfs image lacks its EFI-type boot partition" 4
	grep -Fq 'type=B921B045-1DF0-41C3-AF44-4C6F280D3FAE' "$dump" ||
		die "Rootfs image lacks its ARM64 root partition" 4
}

main() {
	local image_abs=""
	local image_sha=""
	local image_sha_after=""
	local image_size=""
	local remote_home=""
	local remote_image=""
	local remote_script=""
	local remote_available_kib=""
	local required_kib=""
	local remote_env=""

	[ -n "$IMAGE" ] || die "Missing --image" 2
	[ -s "$IMAGE" ] || die "Missing or empty image: $IMAGE" 2
	[[ "$IMAGE_EXPECTED_SHA256" =~ ^[0-9a-f]{64}$ ]] ||
		die "--image-sha256 must be exactly 64 hexadecimal characters" 2
	[[ "$EXPECTED_SOURCE_BOOT_ID" =~ ^[0-9a-fA-F-]{36}$ ]] ||
		die "--expected-source-boot-id must be supplied" 2
	[ -n "$EXPECTED_SOURCE_KERNEL" ] || die "--expected-source-kernel must be supplied" 2
	[ "$CONFIRM_SUPER_WRITE" -eq 1 ] || die "Missing --confirm-super-write" 2
	[ -n "$PMOS_PASSWORD" ] || die "Set PMOS_PASSWORD or use --password" 2
	[ -n "$SERIAL" ] || die "Set ANDROID_SERIAL, HOTDOG_TARGET_SERIAL, or use --serial" 2
	[[ "$LOCK_WAIT_SEC" =~ ^[0-9]+$ ]] || die "--lock-wait must be a non-negative integer" 2

	for command_name in awk dd gzip grep readlink sfdisk sha256sum ssh sshpass stat tee; do
		require_cmd "$command_name"
	done

	image_abs="$(readlink -f "$IMAGE")"
	IMAGE="$image_abs"
	image_size="$(stat -c '%s' "$IMAGE")"
	[ $((image_size % 4096)) -eq 0 ] || die "Image size is not 4096-byte aligned" 4
	image_sha="$(sha256sum "$IMAGE" | awk '{ print $1 }')"
	[ "$image_sha" = "$IMAGE_EXPECTED_SHA256" ] ||
		die "Local SHA256 mismatch: expected $IMAGE_EXPECTED_SHA256, got $image_sha" 4
	validate_local_gpt

	log "Run directory: $run_dir"
	log "Image: $IMAGE"
	log "Image size: $image_size bytes"
	log "Image SHA256: $IMAGE_EXPECTED_SHA256"
	log "Source boot: $EXPECTED_SOURCE_BOOT_ID / $EXPECTED_SOURCE_KERNEL"
	log "Destination contract: physical PARTNAME=super; no reboot"

	phone_lock_acquire "stage verified rootfs to super from pmOS SSH" "$LOCK_WAIT_SEC" ||
		die "Could not acquire local phone-operation lock" 3

	log "Checking SSH, root authentication and source identity"
	remote_run 'printf "ssh-ok host="; uname -n'
	detect_remote_sudo_mode
	remote_sudo_sh 'test "$(id -u)" -eq 0'
	assert_remote_identity || die "pmOS SSH peer identity check failed" 4

	remote_home="$(remote_run 'printf %s "$HOME"')"
	case "$remote_home" in
		/*) ;;
		*) die "Remote HOME is not an absolute path: $remote_home" 3 ;;
	esac
	if [ -z "$REMOTE_DIR" ]; then
		REMOTE_DIR="$remote_home/.cache/hotdog-rootfs-stage-$stamp"
	fi
	case "$REMOTE_DIR" in
		"$remote_home"/.cache/hotdog-rootfs-stage-*) ;;
		*) die "--remote-dir must be below $remote_home/.cache/hotdog-rootfs-stage-*" 2 ;;
	esac
	remote_image="$REMOTE_DIR/rootfs.raw.img"
	remote_script="$REMOTE_DIR/write-super.sh"

	log "Creating remote staging directory: $REMOTE_DIR"
	remote_run "umask 077; mkdir -p $(remote_quote "$REMOTE_DIR"); chmod 700 $(remote_quote "$REMOTE_DIR")"
	REMOTE_WORK_CREATED=1
	remote_available_kib="$(remote_run "df -Pk $(remote_quote "$REMOTE_DIR") | awk 'NR == 2 { print \$4 }'")"
	[[ "$remote_available_kib" =~ ^[0-9]+$ ]] || die "Could not determine remote free space" 3
	required_kib=$(( (image_size + 1023) / 1024 + 1048576 ))
	[ "$remote_available_kib" -ge "$required_kib" ] ||
		die "Remote staging filesystem lacks 1 GiB headroom" 3
	log "Remote staging free space: $remote_available_kib KiB"

	log "Transferring compressed image; progress reports uncompressed input bytes"
	dd if="$IMAGE" bs=16M status=progress |
		gzip -1 |
		ssh_base "set -e; gzip -dc > $(remote_quote "$remote_image.part"); mv -f $(remote_quote "$remote_image.part") $(remote_quote "$remote_image")"

	image_sha_after="$(sha256sum "$IMAGE" | awk '{ print $1 }')"
	[ "$image_sha_after" = "$IMAGE_EXPECTED_SHA256" ] ||
		die "Local image changed during transfer" 4
	log "Verifying staged image before privileged block access"
	remote_run \
		"test \"\$(stat -c %s $(remote_quote "$remote_image"))\" = $(remote_quote "$image_size") && test \"\$(sha256sum $(remote_quote "$remote_image") | awk '{ print \$1 }')\" = $(remote_quote "$IMAGE_EXPECTED_SHA256")" ||
		die "Remote staged image size or SHA256 mismatch" 4

	log "Installing the fail-closed remote writer"
	ssh_base "cat > $(remote_quote "$remote_script")" <<'REMOTE_WRITER'
#!/bin/sh
set -eu

log() {
	printf '[remote %s] %s\n' "$(date '+%F %T')" "$*"
}

die() {
	log "ERROR: $1"
	exit "${2:-1}"
}

img="${REMOTE_IMAGE:?}"
expected_sha="${EXPECTED_SHA:?}"
expected_size="${EXPECTED_SIZE:?}"
expected_serial="${EXPECTED_SERIAL:?}"
expected_boot_id="${EXPECTED_BOOT_ID:?}"
expected_kernel="${EXPECTED_KERNEL:?}"
partition_label="${PARTITION_LABEL:?}"

assert_identity() {
	cmdline="$(cat /proc/cmdline 2>/dev/null || true)"
	boot_id="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)"
	kernel="$(uname -r 2>/dev/null || true)"

	case " $cmdline " in
		*" androidboot.serialno=$expected_serial "*) ;;
		*) die "serial mismatch" 7 ;;
	esac
	for token in \
		androidboot.project_codename=hotdog \
		androidboot.prjname=19801 \
		androidboot.platform_name=SM8150 \
		androidboot.oplus.brand=OnePlus
	do
		case " $cmdline " in
			*" $token "*) ;;
			*) die "missing identity token: $token" 7 ;;
		esac
	done
	[ "$boot_id" = "$expected_boot_id" ] || die "source boot ID changed" 7
	[ "$kernel" = "$expected_kernel" ] || die "source kernel changed" 7
}

validate_target() {
	block_name="${part_real##*/}"
	sys_block="/sys/class/block/$block_name"
	[ -r "$sys_block/uevent" ] || die "missing target uevent: $part_real" 5
	partname="$(awk -F= '$1 == "PARTNAME" { print $2; exit }' "$sys_block/uevent")"
	[ "$partname" = "super" ] || die "target is PARTNAME=${partname:-missing}, not super" 5
	[ -r "$sys_block/size" ] || die "missing target size" 5
	sectors="$(cat "$sys_block/size")"
	case "$sectors" in
		''|*[!0-9]*) die "invalid target sector count: $sectors" 5 ;;
	esac
	capacity=$((sectors * 512))
	[ "$capacity" -ge "$expected_size" ] ||
		die "super is too small: $capacity bytes < $expected_size bytes" 5

	target_dev="$(cat "$sys_block/dev")"
	if awk -v dev="$target_dev" '$3 == dev { found=1 } END { exit found ? 0 : 1 }' /proc/self/mountinfo; then
		die "super is mounted according to mountinfo" 5
	fi
	if findmnt -rn -S "$part_real" >/dev/null 2>&1; then
		die "super is mounted according to findmnt" 5
	fi

	root_source="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
	root_real="$(readlink -f "$root_source" 2>/dev/null || printf '%s\n' "$root_source")"
	[ "$root_real" != "$part_real" ] || die "super is the active root filesystem" 5

	for holder in "$sys_block"/holders/*; do
		[ -e "$holder" ] || continue
		die "super has an active holder: ${holder##*/}" 5
	done
	for backing_file in /sys/block/loop*/loop/backing_file; do
		[ -r "$backing_file" ] || continue
		backing="$(cat "$backing_file")"
		case "$backing" in
			/*) ;;
			*) backing="/$backing" ;;
		esac
		backing_real="$(readlink -f "$backing" 2>/dev/null || printf '%s\n' "$backing")"
		[ "$backing_real" != "$part_real" ] ||
			die "super backs active loop device ${backing_file#/sys/block/}" 5
	done
	if awk -v target="$part_real" 'NR > 1 && $1 == target { found=1 } END { exit found ? 0 : 1 }' /proc/swaps; then
		die "super is active swap" 5
	fi
	log "Validated $part_real: PARTNAME=super, capacity=$capacity, unused"
}

[ "$partition_label" = "super" ] || die "refusing anything except PARTNAME=super" 2
[ -f "$img" ] || die "missing staged image: $img" 4
[ ! -L "$img" ] || die "staged image must not be a symlink" 4
case "$expected_size" in
	''|*[!0-9]*) die "invalid expected image size" 4 ;;
esac
[ $((expected_size % 4096)) -eq 0 ] || die "image is not 4096-byte aligned" 4

assert_identity
actual_size="$(stat -c %s "$img")"
[ "$actual_size" = "$expected_size" ] || die "staged image size mismatch" 4
actual_sha="$(sha256sum "$img" | awk '{ print $1 }')"
[ "$actual_sha" = "$expected_sha" ] || die "staged image SHA256 mismatch" 4

part="/dev/disk/by-partlabel/$partition_label"
[ -b "$part" ] || die "missing $part" 5
part_real="$(readlink -f "$part")"
[ -b "$part_real" ] || die "resolved target is not a block device: $part_real" 5
validate_target

# Re-check every mutable input immediately before the only destructive command.
assert_identity
[ "$(stat -c %s "$img")" = "$expected_size" ] || die "image size changed before write" 4
[ "$(sha256sum "$img" | awk '{ print $1 }')" = "$expected_sha" ] ||
	die "image SHA256 changed before write" 4
[ "$(readlink -f "$part")" = "$part_real" ] || die "super symlink retargeted" 5
validate_target

log "Writing exactly $expected_size bytes to $part_real with O_DIRECT"
dd if="$img" of="$part_real" bs=4M iflag=direct oflag=direct conv=fsync status=noxfer
sync

log "Reading back exactly $expected_size bytes from $part_real"
readback_sha="$(dd if="$part_real" bs=4M count="$expected_size" iflag=count_bytes,direct status=none | sha256sum | awk '{ print $1 }')"
[ "$readback_sha" = "$expected_sha" ] ||
	die "readback SHA256 mismatch: $readback_sha != $expected_sha" 6
log "super verify OK: $readback_sha"
REMOTE_WRITER
	remote_run "chmod 700 $(remote_quote "$remote_script")"

	remote_env="REMOTE_IMAGE=$(remote_quote "$remote_image")"
	remote_env="$remote_env EXPECTED_SHA=$(remote_quote "$IMAGE_EXPECTED_SHA256")"
	remote_env="$remote_env EXPECTED_SIZE=$(remote_quote "$image_size")"
	remote_env="$remote_env EXPECTED_SERIAL=$(remote_quote "$SERIAL")"
	remote_env="$remote_env EXPECTED_BOOT_ID=$(remote_quote "$EXPECTED_SOURCE_BOOT_ID")"
	remote_env="$remote_env EXPECTED_KERNEL=$(remote_quote "$EXPECTED_SOURCE_KERNEL")"
	remote_env="$remote_env PARTITION_LABEL=super"

	log "Running privileged super writer and full readback verification"
	remote_sudo_sh "$remote_env sh $(remote_quote "$remote_script")" |
		tee "$run_dir/remote-writer-readback.txt"
	WRITE_COMPLETED=1

	if [ "$KEEP_REMOTE" -eq 0 ]; then
		log "Removing verified remote staging data"
		remote_run "rm -rf $(remote_quote "$REMOTE_DIR")"
		REMOTE_WORK_CREATED=0
	else
		log "Keeping remote staging data: $REMOTE_DIR"
	fi

	log "Success: super contains the verified image; the phone was not rebooted"
	log "Evidence: $run_dir"
}

main
