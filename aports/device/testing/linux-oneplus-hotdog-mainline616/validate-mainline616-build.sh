#!/bin/sh
set -eu

if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
	echo "usage: $0 IMAGE CONFIG DTB [MODULES_DIR]" >&2
	exit 2
fi

image=$1
config=$2
dtb=$3
modules_dir=${4:-}

die() {
	echo "hotdog mainline 6.16 validation: $*" >&2
	exit 1
}

expect_config() {
	grep -qx "$1" "$config" || die "missing config: $1"
}

expect_value() {
	label=$1
	expected=$2
	shift 2
	actual=$("$@") || die "could not read $label"
	[ "$actual" = "$expected" ] ||
		die "$label: expected '$expected', got '$actual'"
}

expect_absent() {
	label=$1
	shift
	if "$@" >/dev/null 2>&1; then
		die "$label must be absent"
	fi
}

[ -s "$image" ] || die "missing Image: $image"
[ -s "$config" ] || die "missing config: $config"
[ -s "$dtb" ] || die "missing DTB: $dtb"

if [ -n "$modules_dir" ]; then
	[ -d "$modules_dir" ] || die "missing modules directory: $modules_dir"
	find "$modules_dir" -type f -name '*.ko' -print -quit | grep -q . ||
		die "no kernel modules under: $modules_dir"
	find "$modules_dir" -type f -path '*/drivers/input/touchscreen/s6sy761.ko' \
		-print -quit | grep -q . || die "missing S6SY761 touchscreen module"
fi

python3 - "$image" <<'PY'
import pathlib
import struct
import sys

image = pathlib.Path(sys.argv[1]).read_bytes()
if len(image) < 64:
    raise SystemExit("arm64 Image header is truncated")

load_offset, image_size = struct.unpack_from("<QQ", image, 8)
magic = struct.unpack_from("<I", image, 56)[0]
if load_offset != 0x80000:
    raise SystemExit(f"unexpected arm64 load offset: {load_offset:#x}")
if image_size != 0x1AD0000:
    raise SystemExit(f"unexpected direct-entry window: {image_size:#x}")
if len(image) > image_size:
    raise SystemExit(f"Image exceeds direct-entry window: {len(image):#x}")
if magic != 0x644D5241:
    raise SystemExit(f"invalid arm64 Image magic: {magic:#x}")
PY

expect_config 'CONFIG_DRM_MSM=y'
expect_config 'CONFIG_DRM_MSM_DSI=y'
expect_config 'CONFIG_DRM_PANEL_SAMSUNG_ONEPLUS_DSC=y'
expect_config 'CONFIG_USB_DWC3=y'
expect_config 'CONFIG_USB_DWC3_DUAL_ROLE=y'
expect_config 'CONFIG_USB_CONFIGFS=y'
expect_config 'CONFIG_USB_CONFIGFS_ACM=y'
expect_config 'CONFIG_USB_CONFIGFS_NCM=y'
expect_config 'CONFIG_ARM_SMMU=y'
expect_config 'CONFIG_SCSI_UFS_QCOM=y'
expect_config 'CONFIG_QCOM_WDT=y'
expect_config 'CONFIG_EXT4_FS=y'
expect_config 'CONFIG_FONT_TER16x32=y'
expect_config 'CONFIG_QCOM_GENI_SE=y'
expect_config 'CONFIG_QCOM_GPI_DMA=y'
expect_config 'CONFIG_I2C_QCOM_GENI=y'
expect_config 'CONFIG_TOUCHSCREEN_S6SY761=m'

memory=/memory@80000000
reserved=/reserved-memory
soc=/soc@0
ufs=$soc/ufshc@1d84000
qup=$soc/geniqup@ac0000
qup2=$soc/geniqup@cc0000
gpi2=$soc/dma-controller@c00000
i2c17=$qup2/i2c@c80000
touch=$i2c17/touchscreen@48
dwc3=$soc/usb@a6f8800/usb@a600000
panel=$soc/display-subsystem@ae00000/dsi@ae94000/panel@0
te=$soc/pinctrl@3100000/panel-te-default-state
ts_reset=$soc/pinctrl@3100000/ts-reset-default-state
ts_int=$soc/pinctrl@3100000/ts-int-default-state

expect_value memory '0 80000000 0 3bb00000' fdtget -tx "$dtb" "$memory" reg
expect_value firmware-gap '0 89d00000 0 1a00000' \
	fdtget -tx "$dtb" "$reserved/hotdog-removed-gap@89d00000" reg
expect_value ramoops '0 a9800000 0 400000' \
	fdtget -tx "$dtb" "$reserved/ramoops@a9800000" reg
expect_value ramoops-record 40000 \
	fdtget -tx "$dtb" "$reserved/ramoops@a9800000" record-size
expect_value ramoops-console 1000 \
	fdtget -tx "$dtb" "$reserved/ramoops@a9800000" console-size
expect_value ramoops-ftrace 1000 \
	fdtget -tx "$dtb" "$reserved/ramoops@a9800000" ftrace-size
expect_value ramoops-pmsg 1000 \
	fdtget -tx "$dtb" "$reserved/ramoops@a9800000" pmsg-size

expect_value framebuffer-compatible simple-framebuffer \
	fdtget -ts "$dtb" /chosen/framebuffer@9c000000 compatible
expect_value framebuffer-width 5a0 \
	fdtget -tx "$dtb" /chosen/framebuffer@9c000000 width
expect_value framebuffer-height c30 \
	fdtget -tx "$dtb" /chosen/framebuffer@9c000000 height

apps_smmu_path=$(fdtget -ts "$dtb" /__symbols__ apps_smmu) ||
	die "missing apps_smmu symbol"
apps_smmu_phandle=$(fdtget -tx "$dtb" "$apps_smmu_path" phandle) ||
	die "missing Apps SMMU phandle"
expect_value dwc3-iommus "$apps_smmu_phandle 140 0" \
	fdtget -tx "$dtb" "$dwc3" iommus
expect_value dwc3-role peripheral fdtget -ts "$dtb" "$dwc3" dr_mode
expect_value dwc3-speed high-speed fdtget -ts "$dtb" "$dwc3" maximum-speed
expect_absent ufs-iommus fdtget "$dtb" "$ufs" iommus
expect_absent ufs-ice fdtget "$dtb" "$ufs" qcom,ice
expect_absent qup-iommus fdtget "$dtb" "$qup" iommus

expect_value panel-compatible samsung,oneplus-dsc \
	fdtget -ts "$dtb" "$panel" compatible
expect_value panel-status okay fdtget -ts "$dtb" "$panel" status
expect_value panel-te-function mdp_vsync fdtget -ts "$dtb" "$te" function
expect_value ufs-bridge ufs-phy-gdsc-bridge \
	fdtget -ts "$dtb" /ufs-phy-gdsc-supply regulator-name

expect_value qupv3-id2-status okay fdtget -ts "$dtb" "$qup2" status
expect_value gpi-dma2-status okay fdtget -ts "$dtb" "$gpi2" status
expect_value i2c17-status okay fdtget -ts "$dtb" "$i2c17" status
expect_value touchscreen-compatible samsung,s6sy761 \
	fdtget -ts "$dtb" "$touch" compatible
expect_value touchscreen-address 48 fdtget -tx "$dtb" "$touch" reg
expect_value touchscreen-interrupt '7a 8' fdtget -tx "$dtb" "$touch" interrupts
vdd_path=$(fdtget -ts "$dtb" /__symbols__ vreg_l1c_1p8) ||
	die "missing vreg_l1c_1p8 symbol"
vdd_phandle=$(fdtget -tx "$dtb" "$vdd_path" phandle) ||
	die "missing vreg_l1c_1p8 phandle"
avdd_path=$(fdtget -ts "$dtb" /__symbols__ vreg_l10c_3p3) ||
	die "missing vreg_l10c_3p3 symbol"
avdd_phandle=$(fdtget -tx "$dtb" "$avdd_path" phandle) ||
	die "missing vreg_l10c_3p3 phandle"
expect_value touchscreen-vdd "$vdd_phandle" fdtget -tx "$dtb" "$touch" vdd-supply
expect_value touchscreen-avdd "$avdd_phandle" fdtget -tx "$dtb" "$touch" avdd-supply
expect_value touchscreen-reset-pin gpio54 fdtget -ts "$dtb" "$ts_reset" pins
expect_value touchscreen-irq-pin gpio122 fdtget -ts "$dtb" "$ts_int" pins
fdtget "$dtb" "$ts_reset" output-high >/dev/null ||
	die "touchscreen reset pin must default high"

for symbol in \
	ufsphy_mem ufshc_mem pm8150_l5 pm8150l_l3 \
	pm8150_l10 pm8150_l9 pm8150_s4 pm8150l_s8 ufs_phy_gdsc; do
	fdtget -ts "$dtb" /__symbols__ "$symbol" >/dev/null ||
		die "missing filtered-DTBO compatibility symbol: $symbol"
done

echo "hotdog mainline 6.16 build contract: PASS"
