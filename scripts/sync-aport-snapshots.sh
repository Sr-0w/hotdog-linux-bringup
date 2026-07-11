#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
	cat <<'USAGE'
Usage: sync-aport-snapshots.sh [--apply] [options]

Compare the curated public aport snapshots with the canonical local pmaports
checkout. By default this is a check-only canonical-to-snapshot comparison.
Use --apply to copy in the selected direction.

Options:
  --apply              Copy after a difference is found. Default: check-only.
  --to-snapshots       Copy canonical pmaports into ./aports. Default.
  --to-pmaports        Copy ./aports into the canonical pmaports checkout.
  --target-pmaports D  Canonical pmaports checkout. Default:
                       $HOTDOG_PMAPORTS_SM8150
  -h, --help           Show this help.
USAGE
}

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

note() {
	printf '[sync-aport-snapshots] %s\n' "$*"
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/env.sh"

apply=0
direction="to-snapshots"
target_pmaports="$HOTDOG_PMAPORTS_SM8150"
snapshot_root="$HOTDOG_ROOT/aports"
snapshot_rels=(
	"device/testing/device-oneplus-hotdog"
	"device/testing/firmware-oneplus-hotdog"
	"device/testing/linux-postmarketos-sm8150-staging"
	"device/testing/linux-postmarketos-qcom-sm8150"
	"device/testing/linux-oneplus-hotdog-lineage414"
	"device/testing/linux-oneplus-hotdog-mainline617-k1"
)

while [ "$#" -gt 0 ]; do
	case "$1" in
		--apply)
			apply=1
			;;
		--to-snapshots)
			direction="to-snapshots"
			;;
		--to-pmaports)
			direction="to-pmaports"
			;;
		--target-pmaports)
			[ "$#" -ge 2 ] || die "--target-pmaports requires a value"
			target_pmaports="$2"
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

[ -d "$snapshot_root" ] || die "missing snapshot root: $snapshot_root"
[ -d "$target_pmaports" ] || die "missing target pmaports checkout: $target_pmaports"
for command_name in cp diff file find mv; do
	command -v "$command_name" >/dev/null 2>&1 || die "missing required command: $command_name"
done

allowed_snapshot_file() {
	local rel="$1"
	local path="$2"

	case "$rel:$path" in
		device/testing/device-oneplus-hotdog:APKBUILD | \
		device/testing/device-oneplus-hotdog:deviceinfo | \
		device/testing/device-oneplus-hotdog:30-initramfs-firmware.files | \
		device/testing/device-oneplus-hotdog:51-qcom-sm8150.lua | \
		device/testing/device-oneplus-hotdog:modules-initfs | \
		device/testing/device-oneplus-hotdog:device-oneplus-hotdog.post-install | \
		device/testing/device-oneplus-hotdog:90-hotdog-bringup-doas.conf | \
		device/testing/device-oneplus-hotdog:device-oneplus-hotdog-nonfree-firmware.post-install | \
		device/testing/firmware-oneplus-hotdog:APKBUILD | \
		device/testing/linux-postmarketos-sm8150-staging:APKBUILD | \
		device/testing/linux-postmarketos-sm8150-staging:config-sm8150.aarch64 | \
		device/testing/linux-postmarketos-sm8150-staging:0001-arm64-dts-qcom-add-oneplus-hotdog.patch | \
		device/testing/linux-postmarketos-qcom-sm8150:APKBUILD | \
		device/testing/linux-postmarketos-qcom-sm8150:config-postmarketos-qcom-sm8150.aarch64 | \
		device/testing/linux-oneplus-hotdog-lineage414:APKBUILD | \
		device/testing/linux-oneplus-hotdog-lineage414:config-oneplus-hotdog-lineage414.aarch64 | \
		device/testing/linux-oneplus-hotdog-lineage414:stock-hotdog-dtbpack.dtb | \
		device/testing/linux-oneplus-hotdog-mainline617-k1:APKBUILD | \
		device/testing/linux-oneplus-hotdog-mainline617-k1:README.md | \
		device/testing/linux-oneplus-hotdog-mainline617-k1:config-oneplus-hotdog-mainline617-k1.aarch64 | \
		device/testing/linux-oneplus-hotdog-mainline617-k1:0001-arm64-hotdog-use-android-entry-layout.patch | \
		device/testing/linux-oneplus-hotdog-mainline617-k1:0002-input-fts-fix-strict-prototypes.patch | \
		device/testing/linux-oneplus-hotdog-mainline617-k1:0003-power-supply-idtp9418-include-gpio-consumer.patch | \
		device/testing/linux-oneplus-hotdog-mainline617-k1:0004-arm64-dts-qcom-add-oneplus-hotdog.patch)
			return 0
			;;
		*)
			return 1
			;;
	esac
}

validate_snapshot_tree() {
	local rel="$1"
	local root="$2"
	local path=""
	local snapshot_path=""
	local mime=""

	[ -d "$root" ] || die "missing package directory: $root"
	if find "$root" -type l -print -quit | grep -q .; then
		die "snapshot package must not contain symlinks: $root"
	fi

	while IFS= read -r -d '' path; do
		snapshot_path="${path#"$root"/}"
		allowed_snapshot_file "$rel" "$snapshot_path" || die "disallowed snapshot file: $rel/$snapshot_path"
		case "$snapshot_path" in
			*.apk|*.tar|*.tar.*|*.img|*.bin|*.mbn|*.tlv|*.fw)
				die "binary artifact is not allowed in snapshots: $rel/$snapshot_path"
				;;
		esac
		if [ "$rel:$snapshot_path" = "device/testing/linux-oneplus-hotdog-lineage414:stock-hotdog-dtbpack.dtb" ]; then
			continue
		fi
		mime="$(file -b --mime-type "$path")"
		case "$mime" in
			text/*|application/mbox)
				;;
			*)
				die "snapshot file is not text: $rel/$snapshot_path ($mime)"
				;;
		esac
	done < <(find "$root" -type f -print0 | sort -z)
}

sync_dir() {
	local rel="$1"
	local canonical="$target_pmaports/$rel"
	local snapshot="$snapshot_root/$rel"
	local src=""
	local dst=""
	local source_label=""
	local destination_label=""
	local parent=""
	local backup_root=""
	local backup=""
	local safe_rel=""
	local tmp=""
	local diff_file=""

	case "$direction" in
		to-snapshots)
			src="$canonical"
			dst="$snapshot"
			source_label="canonical"
			destination_label="snapshot"
			;;
		to-pmaports)
			src="$snapshot"
			dst="$canonical"
			source_label="snapshot"
			destination_label="canonical"
			;;
	esac

	validate_snapshot_tree "$rel" "$src"
	diff_file="$(mktemp "${TMPDIR:-/tmp}/hotdog-aport-snapshot-diff.XXXXXX")"
	if [ -d "$dst" ]; then
		validate_snapshot_tree "$rel" "$dst"
		if diff -qr "$src" "$dst" > "$diff_file" 2>&1; then
			note "$rel: $destination_label already matches $source_label"
			rm -f "$diff_file"
			return 0
		fi
		note "$rel: $destination_label differs from $source_label"
		sed -n '1,80p' "$diff_file" | sed 's/^/[diff] /'
		rm -f "$diff_file"
	elif [ -e "$dst" ]; then
		rm -f "$diff_file"
		die "destination exists but is not a directory: $dst"
	else
		rm -f "$diff_file"
		note "$rel: $destination_label is absent"
	fi

	if [ "$apply" -eq 0 ]; then
		note "$rel: check-only; use --apply to copy $source_label to $destination_label"
		return 1
	fi

	parent="$(dirname -- "$dst")"
	backup_root="$HOTDOG_ROOT/build/aport-backups"
	safe_rel="$(printf '%s' "$rel" | tr '/' '_')"
	backup="$backup_root/${safe_rel}.backup-$(date +%Y%m%d-%H%M%S)"
	tmp="$parent/.${safe_rel}.tmp.$$"
	mkdir -p "$parent" "$backup_root"
	rm -rf "$tmp"
	cp -a "$src" "$tmp"
	validate_snapshot_tree "$rel" "$tmp"
	if [ -d "$dst" ]; then
		mv "$dst" "$backup"
		note "$rel: previous $destination_label moved to $backup"
	fi
	mv "$tmp" "$dst"
	if ! diff -qr "$src" "$dst" >/dev/null 2>&1; then
		die "$rel: copy verification failed; previous $destination_label is in $backup"
	fi
	note "$rel: copied $source_label to $destination_label"
}

status=0
for rel in "${snapshot_rels[@]}"; do
	sync_dir "$rel" || status=$?
done
exit "$status"
