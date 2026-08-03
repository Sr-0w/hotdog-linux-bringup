#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source "$(dirname "$0")/env.sh"

kernel_build="$HOTDOG_ROOT/build/clearstaff-v26-native-panel"
kernel="$kernel_build/arch/arm64/boot/Image"
dtb="$kernel_build/arch/arm64/boot/dts/qcom/sm8150-oneplus-hotdog.dtb"
config="$kernel_build/.config"
ramdisk="$HOTDOG_ROOT/images/pmos-experiments/2026-08-03-160000-clearstaff616-direct-entry-v25-native-display/components/ramdisk"
cmdline="$HOTDOG_ROOT/configs/clearstaff-hotdog-passive.cmdline"
kernel_sha=24f8c6339e3341d70dd36c2c36da474f9c8d67812f26691d764edc86a1b2ad87
dtb_sha=5130f9b2fb98484d71fd2bd946ef44d08ac347e9b6f337ab0b69d42572525a89
ramdisk_sha=e4c563fcfc6f2a3533fd16539dd22a3fc578bf858e450a9ae7f66d212ae49ec3
cmdline_sha=902b55b27a157cc6ff14ce5acd155e4b118b1754a9ba8a0707117593071df8f6
stamp="${HOTDOG_BUILD_STAMP:-$(date +%F-%H%M%S)}"
build_dir="$HOTDOG_ROOT/build/experiments/$stamp-clearstaff616-v26-native-panel"
outdir="$HOTDOG_ROOT/images/pmos-experiments/$stamp-clearstaff616-direct-entry-v26-native-panel"
mdss=/soc@0/display-subsystem@ae00000
dsi="$mdss/dsi@ae94000"
panel="$dsi/panel@0"
avdd=/panel-avdd-regulator

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

for command in awk fdtget grep python3 sha256sum stat strings; do
	command -v "$command" >/dev/null 2>&1 || die "missing command: $command"
done
check_sha kernel "$kernel" "$kernel_sha"
check_sha DTB "$dtb" "$dtb_sha"
check_sha ramdisk "$ramdisk" "$ramdisk_sha"
check_sha "kernel command line" "$cmdline" "$cmdline_sha"
[ -s "$config" ] || die "missing kernel config: $config"
[ ! -e "$build_dir" ] || die "refusing to reuse build directory: $build_dir"
[ ! -e "$outdir" ] || die "refusing to reuse output directory: $outdir"

python3 - "$kernel" <<'PY'
import pathlib
import struct
import sys

image = pathlib.Path(sys.argv[1]).read_bytes()
if len(image) < 64:
    raise SystemExit("arm64 Image is shorter than its header")
load_offset, image_size = struct.unpack_from("<QQ", image, 8)
magic = struct.unpack_from("<I", image, 56)[0]
if load_offset != 0x80000:
    raise SystemExit(f"unexpected arm64 load offset: {load_offset:#x}")
if image_size != 0x1C00000:
    raise SystemExit(f"unexpected fixed arm64 image size: {image_size:#x}")
if len(image) > image_size:
    raise SystemExit(f"kernel exceeds fixed image window: {len(image)} > {image_size}")
if magic != 0x644D5241:
    raise SystemExit(f"bad arm64 Image magic: {magic:#x}")
PY

grep -qx 'CONFIG_DRM_MSM=y' "$config" || die "MSM DRM is not built in"
grep -qx 'CONFIG_DRM_MSM_DSI=y' "$config" || die "MSM DSI is not built in"
grep -qx 'CONFIG_DRM_PANEL_SAMSUNG_ONEPLUS_DSC=y' "$config" ||
	die "native OnePlus panel driver is not built in"
grep -aFq 'samsung,oneplus-dsc' "$kernel" ||
	die "native OnePlus panel compatible is absent from the kernel"

[ "$(fdtget -t s "$dtb" "$mdss" status)" = okay ] || die "MDSS is disabled"
[ "$(fdtget -t s "$dtb" "$dsi" status)" = okay ] || die "DSI is disabled"
[ "$(fdtget -t s "$dtb" "$panel" status)" = okay ] || die "panel is disabled"
[ "$(fdtget -t s "$dtb" "$panel" compatible)" = samsung,oneplus-dsc ] ||
	die "DTB does not select the native OnePlus panel"
[ "$(fdtget -t x "$dtb" "$panel" vddio-supply)" = cd ] ||
	die "panel does not consume PM8150 LDO14"
[ "$(fdtget -t x "$dtb" "$panel" avdd-supply)" = ce ] ||
	die "panel does not consume its GPIO-controlled AVDD rail"
[ "$(fdtget -t x "$dtb" "$panel" reset-gpios)" = "4f 6 1" ] ||
	die "panel reset is not TLMM GPIO 6 active-low"
[ "$(fdtget -t s "$dtb" "$avdd" compatible)" = regulator-fixed ] ||
	die "panel AVDD is not a fixed regulator"
[ "$(fdtget -t x "$dtb" "$avdd" gpio)" = "4f 82 0" ] ||
	die "panel AVDD is not controlled by TLMM GPIO 130 active-high"

mkdir -p "$build_dir"
sha256sum "$kernel" "$dtb" "$ramdisk" "$cmdline" > "$build_dir/SHA256SUMS"
grep -E '^(CONFIG_DRM_MSM|CONFIG_DRM_MSM_DSI|CONFIG_DRM_PANEL_SAMSUNG_ONEPLUS_DSC)=' \
	"$config" > "$build_dir/display.config"
cat > "$build_dir/change.txt" <<'EOF'
Kernel: ClearStaff Linux 6.16 rebuilt from the exact V13 configuration and
        compiler, with the validated entry continuation in source form
Panel: generated from OnePlus' downstream samsung_oneplus_dsc command table,
       adapted as a built-in DRM/MIPI-DSI command-mode DSC panel driver
DTB: native hotdog MDSS/DPU/DSI graph with PM8150 LDO14 VDDIO, TLMM GPIO 130
     AVDD, and TLMM GPIO 6 active-low reset wired to the panel
Initramfs: passive V25 postmarketOS diagnostic userspace; no framebuffer
           heartbeat and no automatic panic or reset
DTBO: selected by the launcher; this candidate requires the no-op DTBO
Purpose: first direct-mainline test in which Linux owns and initializes the
         complete known OnePlus 7T Pro panel power and command sequence.
EOF

"$HOTDOG_ROOT/scripts/build-mainline-direct-bootimg.sh" \
	--kernel "$kernel" \
	--dtb "$dtb" \
	--ramdisk "$ramdisk" \
	--cmdline-file "$cmdline" \
	--outdir "$outdir" \
	--name boot-clearstaff616-direct-entry-v26-native-panel \
	--partition-size 100663296

printf 'Build directory: %s\nArtifact directory: %s\n' "$build_dir" "$outdir"
