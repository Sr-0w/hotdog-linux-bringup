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
build_dir="$HOTDOG_ROOT/build/experiments/$stamp-clearstaff616-v23-panel-gpio130"
outdir="$HOTDOG_ROOT/images/pmos-experiments/$stamp-clearstaff616-direct-entry-v23-panel-gpio130"
patched_dtb="$build_dir/hotdog-panel-gpio130.dtb"
framebuffer_node=/chosen/framebuffer@9c000000
regulator_node=/display-panel-avdd-eldo
tlmm_node=/soc@0/pinctrl@3100000
tlmm_phandle=4e
regulator_phandle=1001

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

[ "$(fdtget -t x "$source_dtb" "$tlmm_node" phandle)" = "$tlmm_phandle" ] ||
	die "unexpected TLMM phandle"
if fdtget -l "$source_dtb" / | grep -Fxq "${regulator_node#/}"; then
	die "source DTB already defines the panel regulator"
fi
if fdtget -p "$source_dtb" "$framebuffer_node" | grep -Fxq panel-supply; then
	die "source simple-framebuffer already has panel-supply"
fi
dtc -I dtb -O dts -o "$build_dir.source.dts" "$source_dtb" 2>/dev/null
if grep -Eq "phandle = <0x${regulator_phandle}>;" "$build_dir.source.dts"; then
	die "reserved panel-regulator phandle is already used"
fi
rm "$build_dir.source.dts"

mkdir -p "$build_dir"
cp "$source_dtb" "$patched_dtb"
dtc -I dtb -O dts -o "$build_dir/before.dts" "$source_dtb" \
	2> "$build_dir/before-dtc.err"

# Reproduce the OnePlus downstream panel AVDD enable and give simplefb a
# persistent consumer so neither the regulator core nor GPIO ownership can
# drop firmware scanout while native DSI support is still disabled.
fdtput -c "$patched_dtb" "$regulator_node"
fdtput -t s "$patched_dtb" "$regulator_node" compatible regulator-fixed
fdtput -t s "$patched_dtb" "$regulator_node" regulator-name \
	display_panel_avdd_eldo
fdtput -t x "$patched_dtb" "$regulator_node" regulator-min-microvolt 0x1b7740
fdtput -t x "$patched_dtb" "$regulator_node" regulator-max-microvolt 0x1b7740
fdtput -t x "$patched_dtb" "$regulator_node" regulator-enable-ramp-delay 0xe9
fdtput -t x "$patched_dtb" "$regulator_node" gpio 0x4e 0x82 0x0
fdtput "$patched_dtb" "$regulator_node" enable-active-high
fdtput "$patched_dtb" "$regulator_node" regulator-boot-on
fdtput "$patched_dtb" "$regulator_node" regulator-always-on
fdtput -t x "$patched_dtb" "$regulator_node" phandle 0x1001
fdtput -t x "$patched_dtb" "$framebuffer_node" panel-supply 0x1001

[ "$(fdtget -t s "$patched_dtb" "$regulator_node" compatible)" = \
	regulator-fixed ] || die "panel regulator compatible is missing"
[ "$(fdtget -t x "$patched_dtb" "$regulator_node" gpio)" = \
	"4e 82 0" ] || die "panel regulator does not target TLMM GPIO 130"
[ "$(fdtget -t x "$patched_dtb" "$regulator_node" phandle)" = \
	"$regulator_phandle" ] || die "panel regulator phandle is missing"
[ "$(fdtget -t x "$patched_dtb" "$framebuffer_node" panel-supply)" = \
	"$regulator_phandle" ] || die "simple-framebuffer does not consume panel AVDD"
for property in enable-active-high regulator-boot-on regulator-always-on; do
	fdtget -p "$patched_dtb" "$regulator_node" | grep -Fxq "$property" ||
		die "panel regulator lacks $property"
done

dtc -I dtb -O dts -o "$build_dir/after.dts" "$patched_dtb" \
	2> "$build_dir/after-dtc.err"
diff -u "$build_dir/before.dts" "$build_dir/after.dts" \
	> "$build_dir/semantic.diff" || true
change_count="$(awk '/^[+-]/ && !/^(---|\+\+\+)/ { count++ } END { print count + 0 }' \
	"$build_dir/semantic.diff")"
[ "$change_count" -eq 14 ] ||
	die "DTB semantic diff contains $change_count changes instead of 14"
grep -Eq '^\+[[:space:]]+panel-supply = <0x1001>;$' \
	"$build_dir/semantic.diff" || die "semantic diff lacks panel-supply"
grep -Eq '^\+[[:space:]]+gpio = <0x4e 0x82 0x00>;$' \
	"$build_dir/semantic.diff" || die "semantic diff lacks GPIO 130"

sha256sum "$source_dtb" "$patched_dtb" "$kernel" "$ramdisk" "$cmdline" \
	> "$build_dir/SHA256SUMS"
cat > "$build_dir/change.txt" <<'EOF'
Parent: ClearStaff V20 simplefb GCC clocks, passive failure
Change: add the downstream OnePlus display_panel_avdd_eldo fixed regulator on
        TLMM GPIO 130 and expose it to simplefb as panel-supply.
Purpose: make Linux explicitly drive and retain the firmware-initialized panel
         AVDD rail while native MDSS/DSI/panel support remains disabled. The
         kernel, initramfs, and command line are unchanged from V20.
EOF

"$HOTDOG_ROOT/scripts/build-mainline-direct-bootimg.sh" \
	--kernel "$kernel" \
	--dtb "$patched_dtb" \
	--ramdisk "$ramdisk" \
	--cmdline-file "$cmdline" \
	--outdir "$outdir" \
	--name boot-clearstaff616-direct-entry-v23-panel-gpio130 \
	--partition-size 100663296

printf 'Build directory: %s\nArtifact directory: %s\n' "$build_dir" "$outdir"
