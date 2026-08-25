#!/bin/sh
set -eu

usage() {
	echo "usage: $0 SOURCE_TREE [OUTPUT_DIR]" >&2
	exit 2
}

[ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage

root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source_tree=$(realpath "$1")
output_dir=${2:+$(realpath -m "$2")}

. "$root/metadata.env"
"$root/verify-checkpoint.sh"

[ -d "$source_tree/.git" ] || {
	echo "SOURCE_TREE must be a Git checkout" >&2
	exit 1
}

head=$(git -C "$source_tree" rev-parse HEAD)
tree=$(git -C "$source_tree" rev-parse HEAD^{tree})
[ "$head" = "$BASE_COMMIT" ] || {
	echo "wrong base commit: $head" >&2
	exit 1
}
[ "$tree" = "$BASE_TREE" ] || {
	echo "wrong base tree: $tree" >&2
	exit 1
}
[ -z "$(git -C "$source_tree" status --short)" ] || {
	echo "SOURCE_TREE is not clean" >&2
	exit 1
}

while IFS= read -r patch_name; do
	patch -d "$source_tree" -p1 -f -s --no-backup-if-mismatch \
		< "$root/patches/$patch_name"
done < "$root/series"

if find "$source_tree" -type f \( -name '*.orig' -o -name '*.rej' \) | grep -q .; then
	echo "patch application left .orig or .rej files" >&2
	exit 1
fi

index=$(mktemp)
trap 'rm -f "$index"' EXIT HUP INT TERM
rm -f "$index"
GIT_INDEX_FILE=$index git -C "$source_tree" read-tree HEAD
GIT_INDEX_FILE=$index git -C "$source_tree" add -A
actual_tree=$(GIT_INDEX_FILE=$index git -C "$source_tree" write-tree)
[ "$actual_tree" = "$FINAL_SOURCE_TREE" ] || {
	echo "reconstructed tree mismatch: $actual_tree" >&2
	exit 1
}

echo "source tree reconstructed exactly: $actual_tree"

[ -n "$output_dir" ] || exit 0
mkdir -p "$output_dir"
cp "$root/config.resolved" "$output_dir/.config"

make -C "$source_tree" O="$output_dir" ARCH=arm64 LLVM=1 LLVM_IAS=1 olddefconfig
actual_config=$(sha256sum "$output_dir/.config" | awk '{print $1}')
[ "$actual_config" = "$CONFIG_RESOLVED_SHA256" ] || {
	echo "resolved config mismatch: $actual_config" >&2
	echo "use the recorded toolchain or inspect the olddefconfig delta" >&2
	exit 1
}

make -C "$source_tree" O="$output_dir" ARCH=arm64 LLVM=1 LLVM_IAS=1 \
	SOURCE_DATE_EPOCH="$BASE_SOURCE_DATE_EPOCH" \
	KBUILD_BUILD_TIMESTAMP="2025-08-22 17:25:08" \
	KBUILD_BUILD_USER="$KBUILD_BUILD_USER" \
	KBUILD_BUILD_HOST="$KBUILD_BUILD_HOST" \
	KBUILD_BUILD_VERSION="$KBUILD_BUILD_VERSION" \
	Image modules qcom/sm8150-oneplus-hotdog.dtb

"$root/validate-mainline616-build.sh" \
	"$output_dir/arch/arm64/boot/Image" \
	"$output_dir/.config" \
	"$output_dir/arch/arm64/boot/dts/qcom/sm8150-oneplus-hotdog.dtb"

echo "build and source contract passed"
