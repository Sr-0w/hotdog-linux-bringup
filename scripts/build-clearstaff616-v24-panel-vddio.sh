#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source "$(dirname "$0")/env.sh"

source_dir="$HOTDOG_ROOT/images/pmos-experiments/2026-08-03-150000-clearstaff616-direct-entry-v23-panel-gpio130/components"
kernel="$source_dir/kernel"
source_dtb="$source_dir/dtb"
ramdisk="$source_dir/ramdisk"
cmdline="$HOTDOG_ROOT/configs/clearstaff-hotdog-passive.cmdline"
kernel_sha=5978fb51e9386f318b22d6fbc598619d43d31238b123f758fe3de6a7dfa363db
source_dtb_sha=f31932dacc853854fa08ad7a243ca6bcac50c51aa3cbc45f3311073c784b3b87
ramdisk_sha=bc13a04577f65e7812267b96cbd8a5cfb79652397408edbf8104b5d14b8e631a
cmdline_sha=902b55b27a157cc6ff14ce5acd155e4b118b1754a9ba8a0707117593071df8f6
stamp="${HOTDOG_BUILD_STAMP:-$(date +%F-%H%M%S)}"
build_dir="$HOTDOG_ROOT/build/experiments/$stamp-clearstaff616-v24-panel-vddio"
outdir="$HOTDOG_ROOT/images/pmos-experiments/$stamp-clearstaff616-direct-entry-v24-panel-vddio"
patched_dtb="$build_dir/hotdog-panel-vddio.dtb"
framebuffer_node=/chosen/framebuffer@9c000000
vddio_node=/soc@0/rsc@18200000/pm8150-rpmh-regulators/ldo14
vddio_phandle=1be

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

[ "$(fdtget -t x "$source_dtb" "$vddio_node" phandle)" = \
	"$vddio_phandle" ] || die "unexpected PM8150 LDO14 phandle"
[ "$(fdtget -t x "$source_dtb" "$vddio_node" regulator-min-microvolt)" = \
	"1b7740" ] || die "PM8150 LDO14 minimum is not 1.8 V"
[ "$(fdtget -t x "$source_dtb" /display-panel-avdd-eldo gpio)" = \
	"4e 82 0" ] || die "V23 GPIO 130 panel regulator is absent"
[ "$(fdtget -t x "$source_dtb" "$framebuffer_node" panel-supply)" = \
	"1001" ] || die "V23 simplefb panel supply is absent"
if fdtget -p "$source_dtb" "$framebuffer_node" | grep -Fxq vddio-supply; then
	die "source simple-framebuffer already has vddio-supply"
fi

mkdir -p "$build_dir"
cp "$source_dtb" "$patched_dtb"
dtc -I dtb -O dts -o "$build_dir/before.dts" "$source_dtb" \
	2> "$build_dir/before-dtc.err"

# The downstream OnePlus display controller consumes PM8150 LDO14 as vddio.
# simplefb understands arbitrary *-supply properties and keeps them enabled.
fdtput -t x "$patched_dtb" "$framebuffer_node" vddio-supply 0x1be

[ "$(fdtget -t x "$patched_dtb" "$framebuffer_node" vddio-supply)" = \
	"$vddio_phandle" ] || die "simple-framebuffer does not consume PM8150 LDO14"
dtc -I dtb -O dts -o "$build_dir/after.dts" "$patched_dtb" \
	2> "$build_dir/after-dtc.err"
diff -u "$build_dir/before.dts" "$build_dir/after.dts" \
	> "$build_dir/semantic.diff" || true
change_count="$(awk '/^[+-]/ && !/^(---|\+\+\+)/ { count++ } END { print count + 0 }' \
	"$build_dir/semantic.diff")"
[ "$change_count" -eq 1 ] ||
	die "DTB semantic diff contains $change_count changes instead of one"
grep -Eq '^\+[[:space:]]+vddio-supply = <0x1be>;$' \
	"$build_dir/semantic.diff" || die "semantic diff lacks PM8150 LDO14"

sha256sum "$source_dtb" "$patched_dtb" "$kernel" "$ramdisk" "$cmdline" \
	> "$build_dir/SHA256SUMS"
cat > "$build_dir/change.txt" <<'EOF'
Parent: ClearStaff V23 explicit OnePlus panel AVDD on GPIO 130
Change: add vddio-supply = <&vreg_l14a_1p8> to simplefb.
Purpose: retain both supplies named by the downstream OnePlus display path:
         the GPIO-controlled panel AVDD and PM8150 LDO14 VDDIO. The kernel,
         initramfs, command line, and every other DTB property remain V23.
EOF

"$HOTDOG_ROOT/scripts/build-mainline-direct-bootimg.sh" \
	--kernel "$kernel" \
	--dtb "$patched_dtb" \
	--ramdisk "$ramdisk" \
	--cmdline-file "$cmdline" \
	--outdir "$outdir" \
	--name boot-clearstaff616-direct-entry-v24-panel-vddio \
	--partition-size 100663296

printf 'Build directory: %s\nArtifact directory: %s\n' "$build_dir" "$outdir"
