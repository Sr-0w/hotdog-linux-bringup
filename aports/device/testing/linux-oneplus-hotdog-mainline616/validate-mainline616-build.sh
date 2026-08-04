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

smbx_source=drivers/power/supply/qcom_smbx.c
[ -s "$smbx_source" ] || die "missing SMB charger source: $smbx_source"

python3 - "$smbx_source" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text()


def section(start: str, end: str) -> str:
    try:
        return source[source.index(start):source.index(end, source.index(start))]
    except ValueError as exc:
        raise SystemExit(f"missing SMB charger source section: {exc}") from exc


pm8150b = section(
    "static const struct smb_match_data pm8150b_match_data",
    "static const struct smb_match_data pm7250b_match_data",
)
for setting in (
    ".fv_min_uv = 3600000,",
    ".fv_max_uv = 4790000,",
    ".fv_step_uv = 10000,",
    ".fcc_max_ua = 8000000,",
    ".fcc_step_ua = 50000,",
    ".icl_max_ua = 5000000,",
    ".icl_step_ua = 50000,",
):
    if setting not in pm8150b:
        raise SystemExit(f"missing PM8150B charge parameter: {setting}")

smb5_init = section(
    "static const struct smb_init_register smb5_init_seq[]",
    "static const struct smb_init_register smb2_init_seq[]",
)
for unsafe_write in (
    "{ .addr = USBIN_CMD_IL",
    "{ .addr = CHARGING_ENABLE_CMD",
    "{ .addr = FAST_CHARGE_CURRENT_CFG",
):
    if unsafe_write in smb5_init:
        raise SystemExit(f"premature SMB5 init write remains: {unsafe_write}")

probe = section("static int smb_probe", "static const struct of_device_id")
for operation in (
    "USBIN_SUSPEND_BIT, USBIN_SUSPEND_BIT",
    "chip->batt_info->constant_charge_voltage_max_uv",
    "float_voltage_sel",
    "fast_charge_current_sel",
    "smb_set_current_limit(chip, SDP_CURRENT_UA)",
    "USBIN_SUSPEND_BIT, 0",
    "charge limits: float=%u uV fast=%u uA input=%u uA",
):
    if operation not in probe:
        raise SystemExit(f"missing fail-safe SMB5 probe operation: {operation}")

if "return !!(val & mask);" not in source:
    raise SystemExit("SMB overvoltage status does not test the register value")
PY

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
expect_config 'CONFIG_QCOM_SCM=y'
expect_config 'CONFIG_QCOM_MDT_LOADER=y'
expect_config 'CONFIG_QCOM_RPMPD=y'
expect_config 'CONFIG_INTERCONNECT_QCOM_SM8150=y'
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
expect_config 'CONFIG_INPUT=y'
expect_config 'CONFIG_INPUT_EVDEV=y'
expect_config 'CONFIG_KEYBOARD_GPIO=y'
expect_config 'CONFIG_INPUT_PM8941_PWRKEY=y'
expect_config 'CONFIG_PINCTRL_QCOM_SPMI_PMIC=y'
expect_config 'CONFIG_POWER_SUPPLY=y'
expect_config 'CONFIG_POWER_SUPPLY_HWMON=y'
expect_config 'CONFIG_BATTERY_QCOM_FG=y'
expect_config 'CONFIG_CHARGER_QCOM_SMB2=y'

memory=/memory@80000000
reserved=/reserved-memory
soc=/soc@0
ufs=$soc/ufshc@1d84000
qup=$soc/geniqup@ac0000
qup2=$soc/geniqup@cc0000
gpi2=$soc/dma-controller@c00000
i2c17=$qup2/i2c@c80000
touch=$i2c17/touchscreen@48
gpu=$soc/gpu@2c00000
gmu=$soc/gmu@2c6a000
adreno_smmu=$soc/iommu@2ca0000
gpu_zap=$gpu/zap-shader
dwc3=$soc/usb@a6f8800/usb@a600000
panel=$soc/display-subsystem@ae00000/dsi@ae94000/panel@0
battery=/battery
gpio_keys=/gpio-keys
volume_up=$gpio_keys/volume-up
pm8150=$soc/spmi@c440000/pmic@0
pm8150b=$soc/spmi@c440000/pmic@2
pm8150b_charger=$pm8150b/charger@1000
pm8150b_fg=$pm8150b/fuel-gauge@4000
volume_up_state=$pm8150/gpio@c000/volume-up-state
pon_pwrkey=$pm8150/pon@800/pwrkey
pon_resin=$pm8150/pon@800/resin
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

expect_value volume-key-compatible gpio-keys \
	fdtget -ts "$dtb" "$gpio_keys" compatible
expect_value volume-up-label volume_up fdtget -ts "$dtb" "$volume_up" label
expect_value volume-up-code 73 fdtget -tx "$dtb" "$volume_up" linux,code
expect_value volume-up-input-type 1 \
	fdtget -tx "$dtb" "$volume_up" linux,input-type
expect_value volume-up-debounce f \
	fdtget -tx "$dtb" "$volume_up" debounce-interval
fdtget "$dtb" "$volume_up" wakeup-source >/dev/null ||
	die "volume-up must be a wakeup source"
pm8150_gpios_path=$(fdtget -ts "$dtb" /__symbols__ pm8150_gpios) ||
	die "missing pm8150_gpios symbol"
pm8150_gpios_phandle=$(fdtget -tx "$dtb" "$pm8150_gpios_path" phandle) ||
	die "missing PM8150 GPIO phandle"
expect_value volume-up-gpio "$pm8150_gpios_phandle 6 1" \
	fdtget -tx "$dtb" "$volume_up" gpios
volume_up_state_phandle=$(fdtget -tx "$dtb" "$volume_up_state" phandle) ||
	die "missing Volume Up pinctrl phandle"
expect_value volume-up-pinctrl "$volume_up_state_phandle" \
	fdtget -tx "$dtb" "$gpio_keys" pinctrl-0
expect_value volume-up-pin gpio6 fdtget -ts "$dtb" "$volume_up_state" pins
expect_value volume-up-function normal \
	fdtget -ts "$dtb" "$volume_up_state" function
expect_value volume-up-power-source 1 \
	fdtget -tx "$dtb" "$volume_up_state" power-source
expect_value volume-up-drive-strength 0 \
	fdtget -tx "$dtb" "$volume_up_state" qcom,drive-strength
fdtget "$dtb" "$volume_up_state" input-enable >/dev/null ||
	die "volume-up pin must be an input"
fdtget "$dtb" "$volume_up_state" bias-pull-up >/dev/null ||
	die "volume-up pin must use a pull-up"
expect_value power-key-status okay fdtget -ts "$dtb" "$pon_pwrkey" status
expect_value power-key-code 74 fdtget -tx "$dtb" "$pon_pwrkey" linux,code
expect_value volume-down-status okay fdtget -ts "$dtb" "$pon_resin" status
expect_value volume-down-code 72 fdtget -tx "$dtb" "$pon_resin" linux,code

expect_value battery-compatible simple-battery \
	fdtget -ts "$dtb" "$battery" compatible
expect_value battery-chemistry lithium-ion-polymer \
	fdtget -ts "$dtb" "$battery" device-chemistry
expect_value battery-capacity 4085000 \
	fdtget -tu "$dtb" "$battery" charge-full-design-microamp-hours
expect_value battery-min-voltage 3300000 \
	fdtget -tu "$dtb" "$battery" voltage-min-design-microvolt
expect_value battery-max-voltage 4420000 \
	fdtget -tu "$dtb" "$battery" voltage-max-design-microvolt
expect_value battery-charge-current 1500000 \
	fdtget -tu "$dtb" "$battery" constant-charge-current-max-microamp
expect_value battery-charge-voltage 4400000 \
	fdtget -tu "$dtb" "$battery" constant-charge-voltage-max-microvolt
expect_value battery-termination-current 310000 \
	fdtget -tu "$dtb" "$battery" charge-term-current-microamp
battery_phandle=$(fdtget -tx "$dtb" "$battery" phandle) ||
	die "missing battery phandle"
charger_phandle=$(fdtget -tx "$dtb" "$pm8150b_charger" phandle) ||
	die "missing PM8150B charger phandle"
expect_value charger-compatible qcom,pm8150b-charger \
	fdtget -ts "$dtb" "$pm8150b_charger" compatible
expect_value charger-status okay fdtget -ts "$dtb" "$pm8150b_charger" status
expect_value charger-battery "$battery_phandle" \
	fdtget -tx "$dtb" "$pm8150b_charger" monitored-battery
expect_value fuel-gauge-compatible qcom,pm8150b-fg \
	fdtget -ts "$dtb" "$pm8150b_fg" compatible
expect_value fuel-gauge-status okay fdtget -ts "$dtb" "$pm8150b_fg" status
expect_value fuel-gauge-battery "$battery_phandle" \
	fdtget -tx "$dtb" "$pm8150b_fg" monitored-battery
expect_value fuel-gauge-charger "$charger_phandle" \
	fdtget -tx "$dtb" "$pm8150b_fg" power-supplies

expect_value gpu-status okay fdtget -ts "$dtb" "$gpu" status
expect_value gpu-compatible 'qcom,adreno-640.1 qcom,adreno' \
	fdtget -ts "$dtb" "$gpu" compatible
expect_value gmu-status okay fdtget -ts "$dtb" "$gmu" status
expect_value gmu-compatible 'qcom,adreno-gmu-640.1 qcom,adreno-gmu' \
	fdtget -ts "$dtb" "$gmu" compatible
expect_value gpu-zap-firmware qcom/sm8150/oneplus/hotdog/a640_zap.mbn \
	fdtget -ts "$dtb" "$gpu_zap" firmware-name
adreno_smmu_phandle=$(fdtget -tx "$dtb" "$adreno_smmu" phandle) ||
	die "missing Adreno SMMU phandle"
expect_value gpu-iommus "$adreno_smmu_phandle 0 401" \
	fdtget -tx "$dtb" "$gpu" iommus
expect_value gmu-iommus "$adreno_smmu_phandle 5 400" \
	fdtget -tx "$dtb" "$gmu" iommus
gpu_mem_path=$(fdtget -ts "$dtb" /__symbols__ gpu_mem) ||
	die "missing gpu_mem symbol"
gpu_mem_phandle=$(fdtget -tx "$dtb" "$gpu_mem_path" phandle) ||
	die "missing gpu_mem phandle"
expect_value gpu-zap-memory "$gpu_mem_phandle" \
	fdtget -tx "$dtb" "$gpu_zap" memory-region

for symbol in \
	ufsphy_mem ufshc_mem pm8150_l5 pm8150l_l3 \
	pm8150_l10 pm8150_l9 pm8150_s4 pm8150l_s8 ufs_phy_gdsc; do
	fdtget -ts "$dtb" /__symbols__ "$symbol" >/dev/null ||
		die "missing filtered-DTBO compatibility symbol: $symbol"
done

echo "hotdog mainline 6.16 build contract: PASS"
