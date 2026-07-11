#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=/dev/null
source "$(dirname "$0")/env.sh"

K1_COMMIT="379d8fe35c7ca685a650bd82fd023af0ea3f0de0"
EXPECTED_DTS_SHA="d33fb0e36a065f6f2b09e5436e89ef2bb0a80d79f9633a2d4b800f549248f51a"
EXPECTED_CONFIG_SHA="af45c52e0176343e6696dbed5f6a65fd51af639441598ac9d010318b813ee185"
EXPECTED_DTB_SHA="44052506301f7fcad9725c77a98323ec283adf1159b7bee941e7ed2ac3447b49"
DEFAULT_SOURCE_TREE="$HOTDOG_SRC_ROOT/kernel/linux-postmarketos-qcom-sm8150-k1"
LEGACY_SOURCE_TREE="$HOTDOG_SRC_ROOT/kernel/linux-postmarketos-qcom-sm8150-v6.17.0-sm8150"
SOURCE_TREE=""
OUTDIR=""
JOBS="${JOBS:-$(nproc 2>/dev/null || printf '1\n')}"
WORKTREE=""
WORKTREE_REGISTERED=0

usage() {
	cat <<'USAGE'
Usage: build-mainline-k1-base-dtb.sh [options]

Rebuild the exact K1 hotdog base DTB from the pinned SM8150 kernel commit,
tracked hotdog DTS patch, and captured K1 config. No phone is accessed.

Options:
  --source-tree DIR  SM8150 kernel git checkout. Default:
                     src/kernel/linux-postmarketos-qcom-sm8150-k1
  --outdir DIR       Output directory below build/experiments by default.
  --jobs N           Parallel make jobs. Default: host CPU count.
  -h, --help         Show this help.

Prepare the default source checkout with:
  ./scripts/bootstrap-sources.sh --sm8150-k1
USAGE
}

die() {
	printf '%s\n' "$*" >&2
	exit 1
}

cleanup() {
	if [ "$WORKTREE_REGISTERED" -eq 1 ] && [ -n "$SOURCE_TREE" ]; then
		git -C "$SOURCE_TREE" worktree remove --force "$WORKTREE" >/dev/null 2>&1 || true
		git -C "$SOURCE_TREE" worktree prune >/dev/null 2>&1 || true
	fi
}
trap cleanup EXIT

while [ "$#" -gt 0 ]; do
	case "$1" in
		--source-tree)
			[ "$#" -ge 2 ] || die "--source-tree requires a directory"
			SOURCE_TREE="$2"
			shift
			;;
		--outdir)
			[ "$#" -ge 2 ] || die "--outdir requires a directory"
			OUTDIR="$2"
			shift
			;;
		--jobs)
			[ "$#" -ge 2 ] || die "--jobs requires a value"
			JOBS="$2"
			shift
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			die "Unknown argument: $1"
			;;
	esac
	shift
done

case "$JOBS" in
	''|*[!0-9]*) die "--jobs must be a positive integer" ;;
esac
[ "$JOBS" -ge 1 ] || die "--jobs must be a positive integer"

if [ -z "$SOURCE_TREE" ]; then
	if [ -d "$DEFAULT_SOURCE_TREE/.git" ]; then
		SOURCE_TREE="$DEFAULT_SOURCE_TREE"
	elif [ -d "$LEGACY_SOURCE_TREE/.git" ]; then
		SOURCE_TREE="$LEGACY_SOURCE_TREE"
	else
		SOURCE_TREE="$DEFAULT_SOURCE_TREE"
	fi
fi
SOURCE_TREE="$(readlink -f "$SOURCE_TREE" 2>/dev/null || printf '%s\n' "$SOURCE_TREE")"
OUTDIR="${OUTDIR:-$HOTDOG_ROOT/build/experiments/$(date +%F-%H%M%S)-mainline617-k1-base-dtb}"
OUTDIR="$(readlink -m "$OUTDIR")"
PATCH_FILE="$HOTDOG_ROOT/patches/mainline-hotdog-k1-dts.patch"
CONFIG_FILE="$HOTDOG_ROOT/aports/device/testing/linux-oneplus-hotdog-mainline617-k1/config-oneplus-hotdog-mainline617-k1.aarch64"
OUTPUT_DTB="$OUTDIR/00-base-mainline617.dtb"
SOURCE_COPY="$OUTDIR/sm8150-oneplus-hotdog.dts"
BUILD_DIR="$OUTDIR/build"
WORKTREE="$OUTDIR/kernel-worktree"

for command_name in awk cat cp find git grep install make mkdir readlink sha256sum; do
	command -v "$command_name" >/dev/null 2>&1 || die "Missing command: $command_name"
done

[ -d "$SOURCE_TREE/.git" ] || die "Missing SM8150 kernel checkout: $SOURCE_TREE (run ./scripts/bootstrap-sources.sh --sm8150-k1)"
[ -s "$PATCH_FILE" ] || die "Missing tracked hotdog DTS patch: $PATCH_FILE"
[ -s "$CONFIG_FILE" ] || die "Missing captured K1 config: $CONFIG_FILE"

config_sha="$(sha256sum "$CONFIG_FILE" | awk '{ print $1 }')"
[ "$config_sha" = "$EXPECTED_CONFIG_SHA" ] || die "Captured K1 config hash mismatch: $config_sha"

if ! git -C "$SOURCE_TREE" cat-file -e "$K1_COMMIT^{commit}" 2>/dev/null; then
	printf 'Pinned commit is absent locally; fetching %s\n' "$K1_COMMIT"
	git -C "$SOURCE_TREE" fetch origin "$K1_COMMIT"
fi
git -C "$SOURCE_TREE" cat-file -e "$K1_COMMIT^{commit}" 2>/dev/null || die "Pinned K1 commit is unavailable: $K1_COMMIT"

if [ -e "$OUTDIR" ] && find "$OUTDIR" -mindepth 1 -print -quit 2>/dev/null | grep -q .; then
	die "Output directory is not empty: $OUTDIR"
fi
mkdir -p "$OUTDIR"

git -C "$SOURCE_TREE" worktree add --detach "$WORKTREE" "$K1_COMMIT"
WORKTREE_REGISTERED=1
git -C "$WORKTREE" apply --check "$PATCH_FILE"
git -C "$WORKTREE" apply "$PATCH_FILE"

dts_path="$WORKTREE/arch/arm64/boot/dts/qcom/sm8150-oneplus-hotdog.dts"
dts_sha="$(sha256sum "$dts_path" | awk '{ print $1 }')"
[ "$dts_sha" = "$EXPECTED_DTS_SHA" ] || die "Hotdog DTS hash mismatch: $dts_sha"

mkdir -p "$BUILD_DIR"
install -m 0644 "$CONFIG_FILE" "$BUILD_DIR/.config"
make -C "$WORKTREE" O="$BUILD_DIR" ARCH=arm64 LLVM=1 olddefconfig
make -C "$WORKTREE" O="$BUILD_DIR" ARCH=arm64 LLVM=1 -j "$JOBS" qcom/sm8150-oneplus-hotdog.dtb

built_dtb="$BUILD_DIR/arch/arm64/boot/dts/qcom/sm8150-oneplus-hotdog.dtb"
[ -s "$built_dtb" ] || die "Kernel build did not produce the hotdog DTB"
dtb_sha="$(sha256sum "$built_dtb" | awk '{ print $1 }')"
[ "$dtb_sha" = "$EXPECTED_DTB_SHA" ] || die "K1 base DTB hash mismatch: $dtb_sha"

cp "$built_dtb" "$OUTPUT_DTB"
cp "$dts_path" "$SOURCE_COPY"

patch_sha="$(sha256sum "$PATCH_FILE" | awk '{ print $1 }')"
{
	printf 'kernel_source=%s\n' "$SOURCE_TREE"
	printf 'kernel_commit=%s\n' "$K1_COMMIT"
	printf 'patch_sha256=%s\n' "$patch_sha"
	printf 'config_sha256=%s\n' "$config_sha"
	printf 'dts_sha256=%s\n' "$dts_sha"
	printf 'dtb_sha256=%s\n' "$dtb_sha"
	printf 'output_dtb=%s\n' "$OUTPUT_DTB"
} > "$OUTDIR/properties.txt"

sha256sum "$CONFIG_FILE" "$PATCH_FILE" "$SOURCE_COPY" "$OUTPUT_DTB" > "$OUTDIR/SHA256SUMS"

{
	printf '# K1 hotdog base DTB\n\n'
	printf -- '- Kernel commit: `%s`\n' "$K1_COMMIT"
	printf -- '- Config SHA256: `%s`\n' "$config_sha"
	printf -- '- Source DTS SHA256: `%s`\n' "$dts_sha"
	printf -- '- Base DTB SHA256: `%s`\n' "$dtb_sha"
	printf -- '- Output: `%s`\n\n' "$OUTPUT_DTB"
	printf 'The output is byte-identical to the hardware-tested K1 base DTB.\n'
} > "$OUTDIR/MANIFEST.md"

printf 'K1 base DTB: %s\n' "$OUTPUT_DTB"
cat "$OUTDIR/properties.txt"
