#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source "$(dirname "$0")/env.sh"

source_dir="$HOTDOG_ROOT/images/pmos-experiments/2026-08-02-221500-clearstaff616-direct-entry-v13-continue/components"
kernel="$source_dir/kernel"
source_dtb="$source_dir/dtb"
ramdisk="$source_dir/ramdisk"
cmdline="$HOTDOG_ROOT/configs/clearstaff-hotdog-passive.cmdline"
kernel_sha=5978fb51e9386f318b22d6fbc598619d43d31238b123f758fe3de6a7dfa363db
source_dtb_sha=040b4b50989b01dafe400436137bf73a64f3ad5e89bf4c7ddf79a19b3cfcee4c
ramdisk_sha=9918d137fdbf2fc64dc6185b291eefde631becf72d1aefde7c2c6a2f4a619d4d
cmdline_sha=902b55b27a157cc6ff14ce5acd155e4b118b1754a9ba8a0707117593071df8f6
stamp="${HOTDOG_BUILD_STAMP:-$(date +%F-%H%M%S)}"
build_dir="$HOTDOG_ROOT/build/experiments/$stamp-clearstaff616-v14-simplefb-nomap"
outdir="$HOTDOG_ROOT/images/pmos-experiments/$stamp-clearstaff616-direct-entry-v14-simplefb-nomap"
patched_dtb="$build_dir/hotdog-simplefb-nomap.dtb"
framebuffer_node=/chosen/framebuffer@9c000000
reserved_node=/reserved-memory/memory@9c000000

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

for command in awk diff dtc fdtget fdtput grep sha256sum wc; do
	command -v "$command" >/dev/null 2>&1 || die "missing command: $command"
done

check_sha kernel "$kernel" "$kernel_sha"
check_sha DTB "$source_dtb" "$source_dtb_sha"
check_sha ramdisk "$ramdisk" "$ramdisk_sha"
check_sha "kernel command line" "$cmdline" "$cmdline_sha"
[ ! -e "$build_dir" ] || die "refusing to reuse build directory: $build_dir"
[ ! -e "$outdir" ] || die "refusing to reuse output directory: $outdir"

[ "$(fdtget -t x "$source_dtb" "$framebuffer_node" reg)" = "0 9c000000 0 1123800" ] ||
	die "unexpected simple-framebuffer range"
[ "$(fdtget -t x "$source_dtb" "$reserved_node" reg)" = "0 9c000000 0 2400000" ] ||
	die "unexpected splash reservation range"
if fdtget -p "$source_dtb" "$reserved_node" | grep -Fxq no-map; then
	die "source splash reservation is already marked no-map"
fi

mkdir -p "$build_dir"
cp "$source_dtb" "$patched_dtb"
dtc -I dtb -O dts -o "$build_dir/before.dts" "$source_dtb" \
	2> "$build_dir/before-dtc.err"

# The splash reservation currently remains part of the arm64 linear map. That
# makes simplefb's ioremap_wc() reject it as ordinary RAM. Keep the reservation
# but exclude it from the linear map so the existing write-combining mapping can
# succeed without exposing the memory to the page allocator.
fdtput -t x "$patched_dtb" "$reserved_node" no-map

fdtget -p "$patched_dtb" "$reserved_node" | grep -Fxq no-map ||
	die "patched splash reservation has no no-map property"
[ "$(fdtget -t x "$patched_dtb" "$framebuffer_node" reg)" = "0 9c000000 0 1123800" ] ||
	die "patched simple-framebuffer range changed"
[ "$(fdtget -t x "$patched_dtb" "$reserved_node" reg)" = "0 9c000000 0 2400000" ] ||
	die "patched splash reservation range changed"

dtc -I dtb -O dts -o "$build_dir/after.dts" "$patched_dtb" \
	2> "$build_dir/after-dtc.err"
diff -u "$build_dir/before.dts" "$build_dir/after.dts" \
	> "$build_dir/semantic.diff" || true
change_count="$(awk '/^[+-]/ && !/^(---|\+\+\+)/ { count++ } END { print count + 0 }' \
	"$build_dir/semantic.diff")"
[ "$change_count" -eq 1 ] ||
	die "DTB semantic diff contains $change_count changes instead of one"
grep -Eq '^\+[[:space:]]+no-map;$' "$build_dir/semantic.diff" ||
	die "DTB semantic diff is not the expected no-map addition"

sha256sum "$source_dtb" "$patched_dtb" > "$build_dir/SHA256SUMS"
cat > "$build_dir/change.txt" <<'EOF'
Node: /reserved-memory/memory@9c000000
Change: add the empty no-map property
Purpose: keep the splash framebuffer reserved while allowing arm64 ioremap_wc
         to map it for simplefb instead of rejecting it as linear-mapped RAM.
EOF

"$HOTDOG_ROOT/scripts/build-mainline-direct-bootimg.sh" \
	--kernel "$kernel" \
	--dtb "$patched_dtb" \
	--ramdisk "$ramdisk" \
	--cmdline-file "$cmdline" \
	--outdir "$outdir" \
	--name boot-clearstaff616-direct-entry-v14-simplefb-nomap \
	--partition-size 100663296

printf 'Build directory: %s\nArtifact directory: %s\n' "$build_dir" "$outdir"
