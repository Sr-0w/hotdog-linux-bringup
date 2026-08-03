#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source "$(dirname "$0")/env.sh"

source_dir="$HOTDOG_ROOT/images/pmos-experiments/2026-08-02-231500-clearstaff616-direct-entry-v14-simplefb-nomap/components"
kernel="$source_dir/kernel"
source_dtb="$source_dir/dtb"
ramdisk="$source_dir/ramdisk"
cmdline="$HOTDOG_ROOT/configs/clearstaff-hotdog-passive.cmdline"
kernel_sha=5978fb51e9386f318b22d6fbc598619d43d31238b123f758fe3de6a7dfa363db
source_dtb_sha=9510099d9a8eed0e1f368427ec17ce8595e81c992cc3b88eeca3883580870fad
ramdisk_sha=9918d137fdbf2fc64dc6185b291eefde631becf72d1aefde7c2c6a2f4a619d4d
cmdline_sha=902b55b27a157cc6ff14ce5acd155e4b118b1754a9ba8a0707117593071df8f6
stamp="${HOTDOG_BUILD_STAMP:-$(date +%F-%H%M%S)}"
build_dir="$HOTDOG_ROOT/build/experiments/$stamp-clearstaff616-v17-dispcc-off"
outdir="$HOTDOG_ROOT/images/pmos-experiments/$stamp-clearstaff616-direct-entry-v17-dispcc-off"
patched_dtb="$build_dir/hotdog-simplefb-nomap-dispcc-off.dtb"
dispcc_node=/soc@0/clock-controller@af00000
mdss_node=/soc@0/display-subsystem@ae00000

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

[ "$(fdtget -t s "$source_dtb" "$mdss_node" status)" = disabled ] ||
	die "MDSS is not disabled in the pinned V14 DTB"
if fdtget -p "$source_dtb" "$dispcc_node" | grep -Fxq status; then
	die "source DISPCC node already has an explicit status"
fi
[ "$(fdtget -t s "$source_dtb" "$dispcc_node" compatible)" = qcom,sm8150-dispcc ] ||
	die "unexpected DISPCC compatible"

mkdir -p "$build_dir"
cp "$source_dtb" "$patched_dtb"
dtc -I dtb -O dts -o "$build_dir/before.dts" "$source_dtb" \
	2> "$build_dir/before-dtc.err"

# The SM8150 DISPCC probe programs both display PLLs even when MDSS, DPU, and
# DSI are disabled. Preserve the bootloader-owned scanout for simplefb by
# preventing that probe until the native display graph is ready.
fdtput -t s "$patched_dtb" "$dispcc_node" status disabled

[ "$(fdtget -t s "$patched_dtb" "$dispcc_node" status)" = disabled ] ||
	die "patched DISPCC node is not disabled"
[ "$(fdtget -t s "$patched_dtb" "$mdss_node" status)" = disabled ] ||
	die "patched DTB unexpectedly enabled MDSS"

dtc -I dtb -O dts -o "$build_dir/after.dts" "$patched_dtb" \
	2> "$build_dir/after-dtc.err"
diff -u "$build_dir/before.dts" "$build_dir/after.dts" \
	> "$build_dir/semantic.diff" || true
change_count="$(awk '/^[+-]/ && !/^(---|\+\+\+)/ { count++ } END { print count + 0 }' \
	"$build_dir/semantic.diff")"
[ "$change_count" -eq 1 ] ||
	die "DTB semantic diff contains $change_count changes instead of one"
grep -Eq '^\+[[:space:]]+status = "disabled";$' "$build_dir/semantic.diff" ||
	die "DTB semantic diff is not the expected DISPCC status addition"

sha256sum "$source_dtb" "$patched_dtb" > "$build_dir/SHA256SUMS"
cat > "$build_dir/change.txt" <<'EOF'
Node: /soc@0/clock-controller@af00000
Change: add status = "disabled"
Purpose: prevent the SM8150 DISPCC probe from reprogramming firmware display
         PLLs before a native MDSS/DSI/panel graph can own the scanout.
EOF

"$HOTDOG_ROOT/scripts/build-mainline-direct-bootimg.sh" \
	--kernel "$kernel" \
	--dtb "$patched_dtb" \
	--ramdisk "$ramdisk" \
	--cmdline-file "$cmdline" \
	--outdir "$outdir" \
	--name boot-clearstaff616-direct-entry-v17-dispcc-off \
	--partition-size 100663296

printf 'Build directory: %s\nArtifact directory: %s\n' "$build_dir" "$outdir"
