#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source "$(dirname "$0")/env.sh"

source_dir="$HOTDOG_ROOT/images/pmos-experiments/2026-08-03-115000-clearstaff616-direct-entry-v18-fb-heartbeat/components"
kernel="$source_dir/kernel"
source_dtb="$source_dir/dtb"
ramdisk="$source_dir/ramdisk"
cmdline="$HOTDOG_ROOT/configs/clearstaff-hotdog-passive.cmdline"
kernel_sha=5978fb51e9386f318b22d6fbc598619d43d31238b123f758fe3de6a7dfa363db
source_dtb_sha=574450adec3cd81b49a4373b6078af4e6dc497badc38cc4dc123559733431d5a
ramdisk_sha=d15cebf6ddf0963b6ec89509f7d27ce5cc1f3f4fd67ab092a66c95f1f9927837
cmdline_sha=902b55b27a157cc6ff14ce5acd155e4b118b1754a9ba8a0707117593071df8f6
stamp="${HOTDOG_BUILD_STAMP:-$(date +%F-%H%M%S)}"
build_dir="$HOTDOG_ROOT/build/experiments/$stamp-clearstaff616-v19-simplefb-clocks"
outdir="$HOTDOG_ROOT/images/pmos-experiments/$stamp-clearstaff616-direct-entry-v19-simplefb-clocks"
patched_dtb="$build_dir/hotdog-simplefb-clocks.dtb"
framebuffer_node=/chosen/framebuffer@9c000000
gcc_node=/soc@0/clock-controller@100000
gcc_phandle=2c

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

for command in awk diff dtc fdtget fdtput grep sha256sum; do
	command -v "$command" >/dev/null 2>&1 || die "missing command: $command"
done
check_sha kernel "$kernel" "$kernel_sha"
check_sha DTB "$source_dtb" "$source_dtb_sha"
check_sha ramdisk "$ramdisk" "$ramdisk_sha"
check_sha "kernel command line" "$cmdline" "$cmdline_sha"
[ ! -e "$build_dir" ] || die "refusing to reuse build directory: $build_dir"
[ ! -e "$outdir" ] || die "refusing to reuse output directory: $outdir"

[ "$(fdtget -t x "$source_dtb" "$gcc_node" phandle)" = "$gcc_phandle" ] ||
	die "unexpected GCC phandle"
if fdtget -p "$source_dtb" "$framebuffer_node" | grep -Fxq clocks; then
	die "source simple-framebuffer already has clocks"
fi

mkdir -p "$build_dir"
cp "$source_dtb" "$patched_dtb"
dtc -I dtb -O dts -o "$build_dir/before.dts" "$source_dtb" \
	2> "$build_dir/before-dtc.err"

# Match the retained-scanout contract used by other SM8150 mainline devices.
# simplefb will prepare and enable both GCC display AXI clocks for its lifetime.
fdtput -t x "$patched_dtb" "$framebuffer_node" clocks \
	0x2c 0x15 0x2c 0x16

[ "$(fdtget -t x "$patched_dtb" "$framebuffer_node" clocks)" = \
	"2c 15 2c 16" ] || die "simple-framebuffer clocks do not match SM8150 GCC"
[ "$(fdtget -t s "$patched_dtb" /soc@0/clock-controller@af00000 status)" = \
	disabled ] || die "patched DTB unexpectedly enabled DISPCC"

dtc -I dtb -O dts -o "$build_dir/after.dts" "$patched_dtb" \
	2> "$build_dir/after-dtc.err"
diff -u "$build_dir/before.dts" "$build_dir/after.dts" \
	> "$build_dir/semantic.diff" || true
change_count="$(awk '/^[+-]/ && !/^(---|\+\+\+)/ { count++ } END { print count + 0 }' \
	"$build_dir/semantic.diff")"
[ "$change_count" -eq 1 ] ||
	die "DTB semantic diff contains $change_count changes instead of one"
grep -Eq '^\+[[:space:]]+clocks = <0x2c 0x15 0x2c 0x16>;$' \
	"$build_dir/semantic.diff" ||
	die "DTB semantic diff is not the expected simplefb clocks addition"

sha256sum "$source_dtb" "$patched_dtb" > "$build_dir/SHA256SUMS"
cat > "$build_dir/change.txt" <<'EOF'
Node: /chosen/framebuffer@9c000000
Change: add clocks = <&gcc GCC_DISP_HF_AXI_CLK>,
                     <&gcc GCC_DISP_SF_AXI_CLK>
Purpose: make simplefb hold the two SM8150 GCC display AXI clocks for the
         lifetime of retained firmware scanout. This is the same dependency
         declared by existing SM8150 simple-framebuffer device trees.
EOF

"$HOTDOG_ROOT/scripts/build-mainline-direct-bootimg.sh" \
	--kernel "$kernel" \
	--dtb "$patched_dtb" \
	--ramdisk "$ramdisk" \
	--cmdline-file "$cmdline" \
	--outdir "$outdir" \
	--name boot-clearstaff616-direct-entry-v19-simplefb-clocks \
	--partition-size 100663296

printf 'Build directory: %s\nArtifact directory: %s\n' "$build_dir" "$outdir"
