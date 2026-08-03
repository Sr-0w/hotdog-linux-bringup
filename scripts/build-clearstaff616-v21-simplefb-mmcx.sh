#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source "$(dirname "$0")/env.sh"

source_dir="$HOTDOG_ROOT/images/pmos-experiments/2026-08-03-133000-clearstaff616-direct-entry-v20-simplefb-clocks-no-panic/components"
kernel="$source_dir/kernel"
source_dtb="$source_dir/dtb"
ramdisk="$source_dir/ramdisk"
cmdline="$HOTDOG_ROOT/configs/clearstaff-hotdog-passive.cmdline"
kernel_sha=5978fb51e9386f318b22d6fbc598619d43d31238b123f758fe3de6a7dfa363db
source_dtb_sha=c84344db53697b013ff4ca9eeb3b01b0277999984c09de70b2100b1a0515bfe0
ramdisk_sha=bc13a04577f65e7812267b96cbd8a5cfb79652397408edbf8104b5d14b8e631a
cmdline_sha=902b55b27a157cc6ff14ce5acd155e4b118b1754a9ba8a0707117593071df8f6
stamp="${HOTDOG_BUILD_STAMP:-$(date +%F-%H%M%S)}"
build_dir="$HOTDOG_ROOT/build/experiments/$stamp-clearstaff616-v21-simplefb-mmcx"
outdir="$HOTDOG_ROOT/images/pmos-experiments/$stamp-clearstaff616-direct-entry-v21-simplefb-mmcx"
patched_dtb="$build_dir/hotdog-simplefb-mmcx.dtb"
framebuffer_node=/chosen/framebuffer@9c000000
rpmhpd_node=/soc@0/rsc@18200000/power-controller
rpmhpd_phandle=6f
sm8150_mmcx=9
low_svs_opp_phandle=b3

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

[ "$(fdtget -t x "$source_dtb" "$rpmhpd_node" phandle)" = \
	"$rpmhpd_phandle" ] || die "unexpected RPMHPD phandle"
[ "$(fdtget -t x "$source_dtb" \
	/soc@0/display-subsystem@ae00000/display-controller@ae01000 \
	power-domains)" = "$rpmhpd_phandle $sm8150_mmcx" ] ||
	die "DPU does not identify the expected SM8150 MMCX domain"
[ "$(fdtget -t x "$source_dtb" /soc@0/clock-controller@af00000 \
	required-opps)" = "$low_svs_opp_phandle" ] ||
	die "DISPCC does not identify the expected low-SVS MMCX vote"
if fdtget -p "$source_dtb" "$framebuffer_node" | grep -Fxq power-domains; then
	die "source simple-framebuffer already has power-domains"
fi
if fdtget -p "$source_dtb" "$framebuffer_node" | grep -Fxq required-opps; then
	die "source simple-framebuffer already has required-opps"
fi

mkdir -p "$build_dir"
cp "$source_dtb" "$patched_dtb"
dtc -I dtb -O dts -o "$build_dir/before.dts" "$source_dtb" \
	2> "$build_dir/before-dtc.err"

# Substitute for disabled DISPCC as an explicit, persistent MMCX consumer.
fdtput -t x "$patched_dtb" "$framebuffer_node" power-domains \
	0x6f 0x09
fdtput -t x "$patched_dtb" "$framebuffer_node" required-opps \
	0xb3

[ "$(fdtget -t x "$patched_dtb" "$framebuffer_node" power-domains)" = \
	"6f 9" ] || die "simple-framebuffer does not reference SM8150 MMCX"
[ "$(fdtget -t x "$patched_dtb" "$framebuffer_node" required-opps)" = \
	"b3" ] || die "simple-framebuffer does not request low-SVS MMCX"
[ "$(fdtget -t s "$patched_dtb" /soc@0/clock-controller@af00000 status)" = \
	disabled ] || die "patched DTB unexpectedly enabled DISPCC"

dtc -I dtb -O dts -o "$build_dir/after.dts" "$patched_dtb" \
	2> "$build_dir/after-dtc.err"
diff -u "$build_dir/before.dts" "$build_dir/after.dts" \
	> "$build_dir/semantic.diff" || true
change_count="$(awk '/^[+-]/ && !/^(---|\+\+\+)/ { count++ } END { print count + 0 }' \
	"$build_dir/semantic.diff")"
[ "$change_count" -eq 2 ] ||
	die "DTB semantic diff contains $change_count changes instead of two"
grep -Eq '^\+[[:space:]]+power-domains = <0x6f 0x09>;$' \
	"$build_dir/semantic.diff" ||
	die "DTB semantic diff lacks the expected MMCX dependency"
grep -Eq '^\+[[:space:]]+required-opps = <0xb3>;$' \
	"$build_dir/semantic.diff" ||
	die "DTB semantic diff lacks the expected low-SVS vote"

sha256sum "$source_dtb" "$patched_dtb" > "$build_dir/SHA256SUMS"
cat > "$build_dir/change.txt" <<'EOF'
Node: /chosen/framebuffer@9c000000
Change: add power-domains = <&rpmhpd SM8150_MMCX>
        add required-opps = <&rpmhpd_opp_low_svs>
Purpose: make simplefb keep the display's parent MMCX rail powered and voted at
         the same minimum performance level requested by SM8150 DISPCC. DISPCC
         remains disabled, so Linux does not reprogram firmware scanout.
EOF

"$HOTDOG_ROOT/scripts/build-mainline-direct-bootimg.sh" \
	--kernel "$kernel" \
	--dtb "$patched_dtb" \
	--ramdisk "$ramdisk" \
	--cmdline-file "$cmdline" \
	--outdir "$outdir" \
	--name boot-clearstaff616-direct-entry-v21-simplefb-mmcx \
	--partition-size 100663296

printf 'Build directory: %s\nArtifact directory: %s\n' "$build_dir" "$outdir"
