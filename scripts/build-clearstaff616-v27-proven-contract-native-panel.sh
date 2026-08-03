#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source "$(dirname "$0")/env.sh"

kernel_build="$HOTDOG_ROOT/build/clearstaff-v26-native-panel"
kernel="$kernel_build/arch/arm64/boot/Image"
vmlinux="$kernel_build/vmlinux"
config="$kernel_build/.config"
base_dtb="$HOTDOG_ROOT/images/pmos-experiments/2026-08-02-221500-clearstaff616-direct-entry-v13-continue/components/dtb"
panel_overlay_source="$HOTDOG_ROOT/configs/clearstaff-hotdog-native-panel-overlay.dts"
d7_overlay="$HOTDOG_ROOT/images/pmos-experiments/2026-07-31-014429-d7-mainline-native-ufs/components/filtered-entry5.dtbo"
ramdisk="$HOTDOG_ROOT/images/pmos-experiments/2026-08-03-160000-clearstaff616-direct-entry-v25-native-display/components/ramdisk"
cmdline="$HOTDOG_ROOT/configs/clearstaff-hotdog-passive.cmdline"
kernel_sha=0f32671a2c9345f0a49e4282d472d3215228848da27b48de542cd83b2dccf6d9
base_dtb_sha=040b4b50989b01dafe400436137bf73a64f3ad5e89bf4c7ddf79a19b3cfcee4c
panel_overlay_source_sha=b923667943b1b3982cf5a82688e91b4319a8c68bde1b51cb01d73ffaa71dd62b
d7_overlay_sha=f667f356ec70b5cb3950615a13a3e66dd58eebf86046239c6e476c117a6821aa
ramdisk_sha=e4c563fcfc6f2a3533fd16539dd22a3fc578bf858e450a9ae7f66d212ae49ec3
cmdline_sha=902b55b27a157cc6ff14ce5acd155e4b118b1754a9ba8a0707117593071df8f6
stamp="${HOTDOG_BUILD_STAMP:-$(date +%F-%H%M%S)}"
build_dir="$HOTDOG_ROOT/build/experiments/$stamp-clearstaff616-v27-proven-contract-native-panel"
outdir="$HOTDOG_ROOT/images/pmos-experiments/$stamp-clearstaff616-direct-entry-v27-proven-contract-native-panel"
panel_overlay="$build_dir/hotdog-native-panel.dtbo"
dtb="$build_dir/hotdog-v13-native-panel.dtb"
effective_dtb="$build_dir/hotdog-v13-native-panel-d7-effective.dtb"
mdss=/soc@0/display-subsystem@ae00000
dsi="$mdss/dsi@ae94000"
panel="$dsi/panel@0"

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

for command in awk dtc fdtget fdtoverlay grep llvm-nm python3 sha256sum; do
	command -v "$command" >/dev/null 2>&1 || die "missing command: $command"
done

check_sha kernel "$kernel" "$kernel_sha"
check_sha "proven V13 DTB" "$base_dtb" "$base_dtb_sha"
check_sha "native panel overlay source" "$panel_overlay_source" "$panel_overlay_source_sha"
check_sha "D7 filtered overlay" "$d7_overlay" "$d7_overlay_sha"
check_sha ramdisk "$ramdisk" "$ramdisk_sha"
check_sha "kernel command line" "$cmdline" "$cmdline_sha"
[ -s "$vmlinux" ] || die "missing vmlinux: $vmlinux"
[ -s "$config" ] || die "missing kernel config: $config"
[ ! -e "$build_dir" ] || die "refusing to reuse build directory: $build_dir"
[ ! -e "$outdir" ] || die "refusing to reuse output directory: $outdir"

python3 - "$kernel" "$vmlinux" <<'PY'
import pathlib
import struct
import subprocess
import sys

image = pathlib.Path(sys.argv[1]).read_bytes()
if len(image) < 64:
    raise SystemExit("arm64 Image is shorter than its header")
load_offset, image_size = struct.unpack_from("<QQ", image, 8)
magic = struct.unpack_from("<I", image, 56)[0]
if load_offset != 0x80000:
    raise SystemExit(f"unexpected arm64 load offset: {load_offset:#x}")
if image_size != 0x1AD0000:
    raise SystemExit(f"unexpected arm64 image size: {image_size:#x}")
if len(image) > image_size:
    raise SystemExit(f"kernel exceeds declared image window: {len(image)} > {image_size}")
if magic != 0x644D5241:
    raise SystemExit(f"bad arm64 Image magic: {magic:#x}")

symbols = {}
for line in subprocess.check_output(["llvm-nm", "-n", sys.argv[2]], text=True).splitlines():
    fields = line.split()
    if len(fields) == 3 and fields[2] in {"_text", "_end"}:
        symbols[fields[2]] = int(fields[0], 16)
linked_size = symbols.get("_end", 0) - symbols.get("_text", 0)
if linked_size != image_size:
    raise SystemExit(
        f"linked image window {linked_size:#x} does not match header {image_size:#x}"
    )
PY

grep -qx 'CONFIG_DRM_MSM=y' "$config" || die "MSM DRM is not built in"
grep -qx 'CONFIG_DRM_MSM_DSI=y' "$config" || die "MSM DSI is not built in"
grep -qx 'CONFIG_DRM_PANEL_SAMSUNG_ONEPLUS_DSC=y' "$config" ||
	die "native OnePlus panel driver is not built in"
grep -aFq 'samsung,oneplus-dsc' "$kernel" ||
	die "native OnePlus panel compatible is absent from the kernel"

for symbol in \
	mdss mdss_mdp mdss_dsi0 mdss_dsi0_out mdss_dsi0_phy \
	vreg_l3c_1p2 vreg_l5a_0p875 vreg_l14a_1p8 tlmm; do
	fdtget -t s "$base_dtb" /__symbols__ "$symbol" >/dev/null ||
		die "proven V13 DTB lacks required symbol: $symbol"
done

mkdir -p "$build_dir"
dtc -@ -I dts -O dtb -o "$panel_overlay" "$panel_overlay_source"
fdtoverlay -i "$base_dtb" -o "$dtb" "$panel_overlay"

# Replaying D7 offline proves that the bootloader overlay contract remains
# satisfiable after the native panel graph is added to the proven V13 base.
fdtoverlay -i "$dtb" -o "$effective_dtb" "$d7_overlay"

for tree in "$dtb" "$effective_dtb"; do
	[ "$(fdtget -t s "$tree" "$mdss" status)" = okay ] || die "MDSS is disabled in $tree"
	[ "$(fdtget -t s "$tree" "$mdss/display-controller@ae01000" status)" = okay ] ||
		die "DPU is disabled in $tree"
	[ "$(fdtget -t s "$tree" "$dsi" status)" = okay ] || die "DSI is disabled in $tree"
	[ "$(fdtget -t s "$tree" "$mdss/phy@ae94400" status)" = okay ] ||
		die "DSI PHY is disabled in $tree"
	[ "$(fdtget -t s "$tree" "$panel" compatible)" = samsung,oneplus-dsc ] ||
		die "native panel compatible is missing from $tree"
	[ "$(fdtget -t s "$tree" "$panel" status)" = okay ] || die "panel is disabled in $tree"
	[ "$(fdtget -t x "$tree" "$panel" reset-gpios)" = "4e 6 1" ] ||
		die "panel reset is not TLMM GPIO 6 active-low in $tree"
done

sha256sum \
	"$kernel" "$base_dtb" "$panel_overlay_source" "$panel_overlay" \
	"$dtb" "$d7_overlay" "$effective_dtb" "$ramdisk" "$cmdline" \
	> "$build_dir/SHA256SUMS"
grep -E '^(CONFIG_DRM_MSM|CONFIG_DRM_MSM_DSI|CONFIG_DRM_PANEL_SAMSUNG_ONEPLUS_DSC)=' \
	"$config" > "$build_dir/display.config"
cat > "$build_dir/change.txt" <<'EOF'
Kernel: ClearStaff Linux 6.16 rebuilt with the exact 0x01ad0000 arm64 Image
        window used by the proven V13 direct-entry kernel. The linked
        _end - _text span is checked against the header before packaging.
DTB: the exact V13 symbol-bridge DTB proven in direct boot, extended by one
     native overlay enabling MDSS, DPU, DSI0, its PHY, the OnePlus panel,
     PM8150 LDO14 VDDIO, GPIO130 AVDD, and GPIO6 active-low reset.
DTBO: D7 filtered vendor overlay. Offline replay against the extended DTB is
      mandatory and the final effective panel graph is validated.
Initramfs: passive V25 postmarketOS diagnostic userspace; no automatic reset.
Purpose: restore both pre-entry contracts lost by V26 while retaining native
         panel ownership, then distinguish bootloader rejection from a later
         DRM/panel initialization failure using the existing entry markers.
EOF

"$HOTDOG_ROOT/scripts/build-mainline-direct-bootimg.sh" \
	--kernel "$kernel" \
	--dtb "$dtb" \
	--ramdisk "$ramdisk" \
	--cmdline-file "$cmdline" \
	--outdir "$outdir" \
	--name boot-clearstaff616-direct-entry-v27-proven-contract-native-panel \
	--partition-size 100663296

cp "$panel_overlay_source" "$panel_overlay" "$effective_dtb" "$outdir/components/"
sha256sum \
	"$outdir/components/$(basename "$panel_overlay_source")" \
	"$outdir/components/$(basename "$panel_overlay")" \
	"$outdir/components/$(basename "$effective_dtb")" \
	>> "$outdir/SHA256SUMS"
cat >> "$outdir/MANIFEST.md" <<EOF

## V27 direct-entry contract

- Proven V13 base DTB: \`$base_dtb\`
- Native panel overlay source: \`$panel_overlay_source\`
- D7 overlay replay: \`$d7_overlay\`
- Offline effective DTB: \`components/$(basename "$effective_dtb")\`
- Arm64 Image window: \`0x01ad0000\` (matches linked \`_end - _text\`)
EOF

printf 'Build directory: %s\nArtifact directory: %s\n' "$build_dir" "$outdir"
