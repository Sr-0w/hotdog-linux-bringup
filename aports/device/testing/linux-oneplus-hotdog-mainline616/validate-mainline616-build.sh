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
panel_source=drivers/gpu/drm/panel/panel-samsung-oneplus-dsc.c
[ -s "$panel_source" ] || die "missing OnePlus panel source: $panel_source"
ufs_source=drivers/ufs/host/ufs-qcom.c
[ -s "$ufs_source" ] || die "missing Qualcomm UFS source: $ufs_source"
tfa9874_source=sound/soc/codecs/tfa9874.c
[ -s "$tfa9874_source" ] || die "missing TFA9874 source: $tfa9874_source"
sm8150_audio_source=sound/soc/qcom/sm8150.c
[ -s "$sm8150_audio_source" ] ||
	die "missing SM8150 audio source: $sm8150_audio_source"

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

python3 - "$panel_source" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text()

required = (
    "struct drm_connector *connector;",
    "static const struct drm_display_mode samsung_oneplus_dsc_60hz_mode",
    ".clock = (1440 + 16 + 8 + 8) * (3120 + 400 + 28 + 1156) * 60 / 1000,",
    ".vsync_start = 3120 + 400,",
    ".vsync_end = 3120 + 400 + 28,",
    ".vtotal = 3120 + 400 + 28 + 1156,",
    "static const struct drm_display_mode samsung_oneplus_dsc_90hz_mode",
    ".clock = (1440 + 16 + 8 + 8) * (3120 + 4 + 4 + 8) * 90 / 1000,",
    ".vsync_start = 3120 + 4,",
    ".vsync_end = 3120 + 4 + 4,",
    ".vtotal = 3120 + 4 + 4 + 8,",
    "DRM_MODE_MATCH_TIMINGS | DRM_MODE_MATCH_CLOCK",
    "return 0x20;",
    "return 0x30;",
    "u8 control_display_cmd[] = { MIPI_DCS_WRITE_CONTROL_DISPLAY, control_display };",
    "mipi_dsi_dcs_write_buffer_multi(&dsi_ctx, control_display_cmd,",
    "ctx->connector = connector;",
    "mode->type |= DRM_MODE_TYPE_PREFERRED;",
)
for value in required:
    if value not in source:
        raise SystemExit(f"missing stock dual-mode panel contract: {value!r}")

mode_list = source[source.index("static const struct drm_display_mode * const modes[]") :]
mode_list = mode_list[:mode_list.index("};")]
if mode_list.index("&samsung_oneplus_dsc_90hz_mode") > mode_list.index(
    "&samsung_oneplus_dsc_60hz_mode"
):
    raise SystemExit("90 Hz must remain the preferred first panel mode")

if "drm_connector_helper_get_modes_fixed" in source:
    raise SystemExit("fixed single-mode panel helper remains")
PY

python3 - "$ufs_source" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text()
try:
    contract = source[
        source.index("static int ufs_qcom_set_dma_mask") :
        source.index("static const struct ufs_hba_variant_ops", source.index("static int ufs_qcom_set_dma_mask"))
    ]
except ValueError as exc:
    raise SystemExit(f"missing Qualcomm UFS DMA-mask contract: {exc}") from exc

required = (
    'of_device_is_compatible(hba->dev->of_node, "qcom,sm8150-ufshc")',
    '"SM8150 UFS DMA mask constrained to 32-bit\\n"',
    "dma_set_mask_and_coherent(hba->dev, DMA_BIT_MASK(32))",
)
for value in required:
    if value not in contract:
        raise SystemExit(f"missing SM8150 UFS DMA32 contract: {value!r}")

if "of_find_property" in contract or '"iommus"' in contract:
    raise SystemExit("SM8150 DMA32 must not depend on the presence of iommus")

sm8150_branch = contract[: contract.index("if (hba->capabilities")]
if sm8150_branch.count("DMA_BIT_MASK(32)") != 1:
    raise SystemExit("SM8150 UFS branch must contain exactly one DMA32 selection")
PY

python3 - "$tfa9874_source" "$sm8150_audio_source" <<'PY'
import pathlib
import sys

tfa_source = pathlib.Path(sys.argv[1]).read_text()
machine_source = pathlib.Path(sys.argv[2]).read_text()

required = (
    "#define TFA9874_SYSTEM_CONTROL\t\t0x00",
    "#define TFA9874_STATUS_FLAGS1\t\t0x11",
    "#define TFA9874_REVISION_REG\t\t0x03",
    "#define TFA9874_REVISION_0C74\t\t0x0c74",
    ".val_format_endian = REGMAP_ENDIAN_BIG,",
    ".max_register = 0xfb,",
    ".readable_reg = tfa9874_readable_reg,",
    ".writeable_reg = tfa9874_writeable_reg,",
    ".cache_type = REGCACHE_NONE,",
    "client->addr != 0x34 && client->addr != 0x35",
    "regmap_read(tfa->regmap, TFA9874_REVISION_REG, &revision)",
    "revision != TFA9874_REVISION_0C74",
    "tfa->slot = client->addr == 0x35;",
    "static int tfa9874_safe_off(struct tfa9874 *tfa)",
    "static int tfa9874_configure(struct tfa9874 *tfa)",
    "regmap_read_poll_timeout(tfa->regmap, TFA9874_STATUS_FLAGS1",
    "TFA9874_PLLS | TFA9874_CLKS",
    "static DEVICE_ATTR_RO(diagnostics);",
    "static struct snd_soc_dai_driver tfa9874_dai",
    ".channels_min = 2,",
    ".channels_max = 2,",
    ".rates = SNDRV_PCM_RATE_48000,",
    ".formats = SNDRV_PCM_FMTBIT_S24_LE,",
    "OxygenOS speaker profile prepared on TDM slot %u; output muted",
    "&tfa9874_component_driver,",
    "&tfa9874_dai, 1);",
)
for value in required:
    if value not in tfa_source:
        raise SystemExit(f"missing bounded TFA9874 output contract: {value!r}")

safe_off = tfa_source[
    tfa_source.index("static int tfa9874_safe_off"):
    tfa_source.index("static int tfa9874_configure")
]
for value in (
    "TFA9874_AMPE | TFA9874_DCA, 0",
    "TFA9874_PWDN, TFA9874_PWDN",
):
    if value not in safe_off:
        raise SystemExit(f"TFA9874 safe-off contract is incomplete: {value!r}")

mute = tfa_source[
    tfa_source.index("static int tfa9874_mute_stream"):
    tfa_source.index("static void tfa9874_shutdown")
]
clock_poll = mute.index("regmap_read_poll_timeout")
amplifier_enable = mute.index("TFA9874_AMPE, TFA9874_AMPE")
if amplifier_enable < clock_poll:
    raise SystemExit("TFA9874 amplifier is enabled before its clocks are stable")
if "500, 20000" not in mute:
    raise SystemExit("TFA9874 clock-stability wait is not bounded to 20 ms")
if "goto fail_off" not in mute or "tfa9874_safe_off(tfa);" not in mute:
    raise SystemExit("TFA9874 unmute failures do not return to the safe-off state")

for forbidden in ("gpiod_", "reset_control_"):
    if forbidden in tfa_source:
        raise SystemExit(f"physical amplifier reset must remain untouched: {forbidden}")

machine_required = (
    "#define QUAT_MI2S_BCLK_RATE\t3072000",
    "snd_mask_set_format(fmt, SNDRV_PCM_FORMAT_S24_LE);",
    "Q6AFE_LPASS_CLK_ID_QUAD_MI2S_IBIT",
    "QUAT_MI2S_BCLK_RATE, SNDRV_PCM_STREAM_PLAYBACK",
    "snd_soc_dai_set_fmt(cpu_dai, SND_SOC_DAIFMT_BP_FP);",
    "snd_soc_dai_set_fmt(cpu_dai, fmt);",
)
for value in machine_required:
    if value not in machine_source:
        raise SystemExit(f"missing SM8150 QUAT MI2S contract: {value!r}")
if machine_source.count("case QUATERNARY_MI2S_RX:") < 3:
    raise SystemExit("SM8150 machine driver does not cover QUAT MI2S lifecycle")

startup = machine_source[
    machine_source.index("static int sm8150_snd_startup"):
    machine_source.index("static void sm8150_snd_shutdown")
]
quat_start = startup.index("case QUATERNARY_MI2S_RX:")
quat_startup = startup[quat_start:startup.index("break;", quat_start)]
if "SND_SOC_DAIFMT_BP_FP" not in quat_startup:
    raise SystemExit("SM8150 QUAT MI2S CPU must provide BCLK and frame sync")
if "snd_soc_dai_set_fmt(cpu_dai, fmt);" in quat_startup:
    raise SystemExit("SM8150 QUAT MI2S CPU remains configured as a clock consumer")
PY

if [ -n "$modules_dir" ]; then
	[ -d "$modules_dir" ] || die "missing modules directory: $modules_dir"
	find "$modules_dir" -type f -name '*.ko' -print -quit | grep -q . ||
		die "no kernel modules under: $modules_dir"
	find "$modules_dir" -type f -path '*/drivers/input/touchscreen/s6sy761.ko' \
		-print -quit | grep -q . || die "missing S6SY761 touchscreen module"
	find "$modules_dir" -type f -path '*/drivers/net/wireless/ath/ath10k/ath10k_snoc.ko' \
		-print -quit | grep -q . || die "missing WCN3990 ath10k SNOC module"
	find "$modules_dir" -type f -path '*/drivers/bluetooth/hci_uart.ko' \
		-print -quit | grep -q . || die "missing Bluetooth HCI UART module"
	find "$modules_dir" -type f -path '*/drivers/bluetooth/btqca.ko' \
		-print -quit | grep -q . || die "missing Qualcomm Bluetooth module"
	find "$modules_dir" -type f -path '*/drivers/remoteproc/qcom_q6v5_pas.ko' \
		-print -quit | grep -q . || die "missing Qualcomm PAS remoteproc module"
	find "$modules_dir" -type f -path '*/drivers/base/regmap/regmap-slimbus.ko' \
		-print -quit | grep -q . || die "missing SLIMbus regmap module"
	find "$modules_dir" -type f -path '*/drivers/slimbus/slim-qcom-ngd-ctrl.ko' \
		-print -quit | grep -q . || die "missing Qualcomm NGD SLIMbus module"
	find "$modules_dir" -type f -path '*/drivers/mfd/wcd934x.ko' \
		-print -quit | grep -q . || die "missing WCD9340 MFD module"
	find "$modules_dir" -type f -path '*/drivers/gpio/gpio-wcd934x.ko' \
		-print -quit | grep -q . || die "missing WCD9340 GPIO module"
	find "$modules_dir" -type f -path '*/sound/soc/codecs/snd-soc-wcd934x.ko' \
		-print -quit | grep -q . || die "missing WCD9340 codec module"
	find "$modules_dir" -type f -path '*/drivers/soundwire/soundwire-bus.ko' \
		-print -quit | grep -q . || die "missing SoundWire bus module"
	find "$modules_dir" -type f -path '*/drivers/soundwire/soundwire-qcom.ko' \
		-print -quit | grep -q . || die "missing Qualcomm SoundWire module"
	find "$modules_dir" -type f -path '*/sound/soc/qcom/qdsp6/q6afe-dai.ko' \
		-print -quit | grep -q . || die "missing Q6AFE DAI module"
	find "$modules_dir" -type f -path '*/sound/soc/qcom/qdsp6/q6asm-dai.ko' \
		-print -quit | grep -q . || die "missing Q6ASM DAI module"
	find "$modules_dir" -type f -path '*/sound/soc/qcom/qdsp6/q6routing.ko' \
		-print -quit | grep -q . || die "missing Q6 routing module"
	find "$modules_dir" -type f -path '*/sound/soc/qcom/snd-soc-sm8150.ko' \
		-print -quit | grep -q . || die "missing SM8150 machine sound module"
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
expect_config 'CONFIG_CFG80211=m'
expect_config 'CONFIG_MAC80211=m'
expect_config 'CONFIG_ATH10K=m'
expect_config 'CONFIG_ATH10K_SNOC=m'
expect_config 'CONFIG_SERIAL_QCOM_GENI=y'
expect_config 'CONFIG_BT=m'
expect_config 'CONFIG_BT_QCA=m'
expect_config 'CONFIG_BT_HCIUART=m'
expect_config 'CONFIG_BT_HCIUART_SERDEV=y'
expect_config 'CONFIG_BT_HCIUART_H4=y'
expect_config 'CONFIG_BT_HCIUART_QCA=y'
expect_config 'CONFIG_QRTR=m'
expect_config 'CONFIG_QCOM_RPROC_COMMON=m'
expect_config 'CONFIG_QCOM_Q6V5_MSS=m'
expect_config 'CONFIG_QCOM_Q6V5_PAS=m'
expect_config 'CONFIG_QCOM_SYSMON=m'
expect_config 'CONFIG_QCOM_RMTFS_MEM=y'
expect_config 'CONFIG_RPMSG_QCOM_GLINK_SMEM=m'
expect_config 'CONFIG_QRTR_SMD=m'
expect_config 'CONFIG_SND_SOC_QDSP6_AFE_DAI=m'
expect_config 'CONFIG_SND_SOC_QDSP6_ASM_DAI=m'
expect_config 'CONFIG_SND_SOC_QDSP6_ROUTING=m'
expect_config 'CONFIG_SND_SOC_SM8150=m'
expect_config 'CONFIG_SND_SOC_TFA9874=y'
expect_config 'CONFIG_I2C_QCOM_GENI=y'
expect_config 'CONFIG_TYPEC=y'
expect_config 'CONFIG_TYPEC_MUX_FSA4480=y'

memory=/memory@80000000
reserved=/reserved-memory
xbl_aop_gap=$reserved/memory@85e40000
stock_removed_gap=$reserved/memory@89b00000
stock_cdsp_gap=$reserved/memory@99517000
soc=/soc@0
ufs=$soc/ufshc@1d84000
qup=$soc/geniqup@ac0000
qup0=$soc/geniqup@8c0000
qup2=$soc/geniqup@cc0000
gpi0=$soc/dma-controller@800000
gpi2=$soc/dma-controller@c00000
i2c4=$qup0/i2c@890000
fsa4480=$i2c4/typec-mux@42
fsa4480_endpoint=$fsa4480/port/endpoint
tfa9874_top=$i2c4/audio-codec@34
tfa9874_bottom=$i2c4/audio-codec@35
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
volume_down=$gpio_keys/volume-down
pm8150=$soc/spmi@c440000/pmic@0
pm8150b=$soc/spmi@c440000/pmic@2
pm8150b_charger=$pm8150b/charger@1000
pm8150b_fg=$pm8150b/fuel-gauge@4000
pm8150b_typec=$pm8150b/typec@1500
remoteproc_mpss=$soc/remoteproc@4080000
remoteproc_adsp=$soc/remoteproc@17300000
slim=$soc/slim-ngd@171c0000
slim_ngd=$slim/slim@1
wcd9340_ifd=$slim_ngd/ifd@0,0
wcd9340=$slim_ngd/codec@1,0
wcd9340_gpio=$wcd9340/gpio-controller@42
wcd9340_swm=$wcd9340/soundwire@c85
sound=/sound
q6asmdai=$remoteproc_adsp/glink-edge/apr/apr-service@7/dais
q6asm_mm1=$q6asmdai/dai@0
q6asm_mm2=$q6asmdai/dai@1
sound_mm1=$sound/mm1-dai-link
sound_mm2=$sound/mm2-dai-link
sound_speaker=$sound/speaker-dai-link
sound_slim=$sound/slim-dai-link
sound_slimcap=$sound/slimcap-dai-link
wifi=$soc/wifi@18800000
uart13=$qup2/serial@c8c000
bluetooth=$uart13/bluetooth
wlan_mem=$reserved/memory@8bc00000
adsp_mem=$reserved/memory@8be00000
rmtfs_mem=$reserved/memory@fc201000
volume_up_state=$pm8150/gpio@c000/volume-up-state
pon_pwrkey=$pm8150/pon@800/pwrkey
volume_down_state=$pm8150/gpio@c000/volume-down-state
te=$soc/pinctrl@3100000/panel-te-default-state
ts_reset=$soc/pinctrl@3100000/ts-reset-default-state
ts_int=$soc/pinctrl@3100000/ts-int-default-state
uart13_sleep=$soc/pinctrl@3100000/qup-uart13-sleep-state
wcd_intr=$soc/pinctrl@3100000/wcd-intr-default-state
fsa_usbc_ana_en=$soc/pinctrl@3100000/fsa-usbc-ana-en-state
quat_mi2s=$soc/pinctrl@3100000/quat-mi2s-active-state
quat_mi2s_sd0=$soc/pinctrl@3100000/quat-mi2s-sd0-active-state
quat_mi2s_sd1=$soc/pinctrl@3100000/quat-mi2s-sd1-active-state

expect_value memory '0 80000000 0 3bb00000' fdtget -tx "$dtb" "$memory" reg
expect_value firmware-gap '0 89d00000 0 1a00000' \
	fdtget -tx "$dtb" "$reserved/hotdog-removed-gap@89d00000" reg
expect_value xbl-aop-gap '0 85e40000 0 c0000' \
	fdtget -tx "$dtb" "$xbl_aop_gap" reg
fdtget -p "$dtb" "$xbl_aop_gap" | grep -qx no-map ||
	die "XBL/AOP gap reservation is missing no-map"
expect_value stock-removed-gap '0 89b00000 0 200000' \
	fdtget -tx "$dtb" "$stock_removed_gap" reg
fdtget -p "$dtb" "$stock_removed_gap" | grep -qx no-map ||
	die "stock removed_regions gap is missing no-map"
expect_value stock-cdsp-gap '0 99517000 0 e9000' \
	fdtget -tx "$dtb" "$stock_cdsp_gap" reg
fdtget -p "$dtb" "$stock_cdsp_gap" | grep -qx no-map ||
	die "stock CDSP gap is missing no-map"
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
expect_value dwc3-role otg fdtget -ts "$dtb" "$dwc3" dr_mode
# No speed cap: the controller must keep both PHYs so SuperSpeed and the
# DisplayPort altmode stay reachable.
expect_absent dwc3-speed-cap fdtget "$dtb" "$dwc3" maximum-speed
expect_absent usb-utmi-pipe-clk \
	fdtget "$dtb" "$soc/usb@a6f8800" qcom,select-utmi-as-pipe-clk
# Role switching must stay wired end to end: the controller advertises a
# switch, the Type-C block and its VBUS boost are enabled, and the connector
# reaches both the controller and the SBU mux. Losing any one of these
# silently drops the port back to peripheral-only.
fdtget "$dtb" "$dwc3" usb-role-switch >/dev/null 2>&1 ||
	die "dwc3 must advertise usb-role-switch"
fdtget "$dtb" "$dwc3/ports/port@0/endpoint" remote-endpoint >/dev/null 2>&1 ||
	die "dwc3 high-speed endpoint must reach the Type-C connector"
typec=$(fdtget -ts "$dtb" /__symbols__ pm8150b_typec) ||
	die "missing Type-C symbol"
expect_value typec-status okay fdtget -ts "$dtb" "$typec" status
expect_value typec-connector usb-c-connector \
	fdtget -ts "$dtb" "$typec/connector" compatible
expect_value typec-power-role dual \
	fdtget -ts "$dtb" "$typec/connector" power-role
expect_value typec-data-role dual \
	fdtget -ts "$dtb" "$typec/connector" data-role
fdtget "$dtb" "$typec/connector/ports/port@0/endpoint" remote-endpoint \
	>/dev/null 2>&1 || die "Type-C connector must reach the dwc3 data role"
fdtget "$dtb" "$typec/connector/ports/port@1/endpoint" remote-endpoint \
	>/dev/null 2>&1 || die "Type-C connector must reach the SuperSpeed mux"
fdtget "$dtb" "$typec/connector/ports/port@2/endpoint" remote-endpoint \
	>/dev/null 2>&1 || die "Type-C connector must reach the SBU mux"
fdtget -p "$dtb" "$typec/connector/altmodes/displayport" >/dev/null 2>&1 ||
	die "Type-C connector must declare a DisplayPort altmode"
expect_value typec-dp-vdo 1c46 \
	fdtget -tx "$dtb" "$typec/connector/altmodes/displayport" vdo
qmpphy=$(fdtget -ts "$dtb" /__symbols__ usb_1_qmpphy) ||
	die "missing combo PHY symbol"
expect_value qmpphy-status okay fdtget -ts "$dtb" "$qmpphy" status
fdtget "$dtb" "$qmpphy" orientation-switch >/dev/null 2>&1 ||
	die "combo PHY must advertise orientation-switch"
dp=$(fdtget -ts "$dtb" /__symbols__ mdss_dp) ||
	die "missing DisplayPort controller symbol"
expect_value dp-status okay fdtget -ts "$dtb" "$dp" status
vbus=$(fdtget -ts "$dtb" /__symbols__ pm8150b_vbus) ||
	die "missing VBUS regulator symbol"
expect_value vbus-status okay fdtget -ts "$dtb" "$vbus" status
expect_value ufs-iommus "$apps_smmu_phandle 300 0" \
	fdtget -tx "$dtb" "$ufs" iommus
expect_absent ufs-ice fdtget "$dtb" "$ufs" qcom,ice
expect_absent qup-iommus fdtget "$dtb" "$qup" iommus
expect_value qupv3-id0-status okay fdtget -ts "$dtb" "$qup0" status
expect_absent qupv3-id0-iommus fdtget "$dtb" "$qup0" iommus
expect_value gpi-dma0-status disabled fdtget -ts "$dtb" "$gpi0" status
expect_value i2c4-status okay fdtget -ts "$dtb" "$i2c4" status
expect_value i2c4-clock-frequency 186a0 \
	fdtget -tx "$dtb" "$i2c4" clock-frequency
expect_absent i2c4-dmas fdtget "$dtb" "$i2c4" dmas
expect_absent i2c4-dma-names fdtget "$dtb" "$i2c4" dma-names
expect_value fsa4480-compatible fcs,fsa4480 \
	fdtget -ts "$dtb" "$fsa4480" compatible
expect_value fsa4480-address 42 fdtget -tx "$dtb" "$fsa4480" reg
fdtget "$dtb" "$fsa4480" mode-switch >/dev/null ||
	die "FSA4480 mode-switch capability is missing"
fdtget "$dtb" "$fsa4480" orientation-switch >/dev/null ||
	die "FSA4480 orientation-switch capability is missing"
fdtget -p "$dtb" "$fsa4480_endpoint" >/dev/null ||
	die "FSA4480 future Type-C endpoint is missing"
fdtget "$dtb" "$fsa4480_endpoint" remote-endpoint >/dev/null 2>&1 ||
	die "fsa4480 endpoint must reach the Type-C connector"
expect_value fsa4480-enable-pin gpio100 \
	fdtget -ts "$dtb" "$fsa_usbc_ana_en" pins
expect_value fsa4480-enable-function gpio \
	fdtget -ts "$dtb" "$fsa_usbc_ana_en" function
expect_value fsa4480-enable-drive-strength 2 \
	fdtget -tx "$dtb" "$fsa_usbc_ana_en" drive-strength
fdtget "$dtb" "$fsa_usbc_ana_en" output-low >/dev/null ||
	die "FSA4480 active-low enable state is missing"
fsa_usbc_ana_en_phandle=$(fdtget -tx "$dtb" "$fsa_usbc_ana_en" phandle) ||
	die "missing FSA4480 enable-state phandle"
expect_value fsa4480-pinctrl "$fsa_usbc_ana_en_phandle" \
	fdtget -tx "$dtb" "$fsa4480" pinctrl-0
for amplifier in "$tfa9874_top" "$tfa9874_bottom"; do
	expect_value "$amplifier-compatible" nxp,tfa9874 \
		fdtget -ts "$dtb" "$amplifier" compatible
	expect_value "$amplifier-dai-cells" 0 \
		fdtget -tx "$dtb" "$amplifier" '#sound-dai-cells'
	expect_absent "$amplifier-reset" fdtget "$dtb" "$amplifier" reset-gpios
	expect_absent "$amplifier-pinctrl" fdtget "$dtb" "$amplifier" pinctrl-0
done
expect_value tfa9874-top-address 34 fdtget -tx "$dtb" "$tfa9874_top" reg
expect_value tfa9874-bottom-address 35 fdtget -tx "$dtb" "$tfa9874_bottom" reg
expect_value quat-mi2s-clock-pins 'gpio137 gpio138' \
	fdtget -ts "$dtb" "$quat_mi2s" pins
expect_value quat-mi2s-clock-function qua_mi2s \
	fdtget -ts "$dtb" "$quat_mi2s" function
expect_value quat-mi2s-clock-drive 8 \
	fdtget -tx "$dtb" "$quat_mi2s" drive-strength
fdtget "$dtb" "$quat_mi2s" output-high >/dev/null ||
	die "QUAT MI2S clock state must drive its idle level"
expect_value quat-mi2s-sd0-pin gpio139 \
	fdtget -ts "$dtb" "$quat_mi2s_sd0" pins
expect_value quat-mi2s-sd0-function qua_mi2s \
	fdtget -ts "$dtb" "$quat_mi2s_sd0" function
expect_value quat-mi2s-sd1-pin gpio140 \
	fdtget -ts "$dtb" "$quat_mi2s_sd1" pins
expect_value quat-mi2s-sd1-function qua_mi2s \
	fdtget -ts "$dtb" "$quat_mi2s_sd1" function

expect_value mpss-status okay fdtget -ts "$dtb" "$remoteproc_mpss" status
expect_value mpss-firmware qcom/sm8150/oneplus/hotdog/modem.mbn \
	fdtget -ts "$dtb" "$remoteproc_mpss" firmware-name
expect_value adsp-status okay fdtget -ts "$dtb" "$remoteproc_adsp" status
expect_value adsp-firmware qcom/sm8150/oneplus/hotdog/adsp.mbn \
	fdtget -ts "$dtb" "$remoteproc_adsp" firmware-name
expect_value adsp-address '0 8be00000 0 1e00000' \
	fdtget -tx "$dtb" "$adsp_mem" reg
fdtget -p "$dtb" "$adsp_mem" | grep -qx no-map ||
	die "ADSP reservation is missing no-map"
adsp_mem_phandle=$(fdtget -tx "$dtb" "$adsp_mem" phandle) ||
	die "missing ADSP memory phandle"
expect_value adsp-memory "$adsp_mem_phandle" \
	fdtget -tx "$dtb" "$remoteproc_adsp" memory-region
expect_value slim-status okay fdtget -ts "$dtb" "$slim" status
expect_value slim-ngd-address 1 fdtget -tx "$dtb" "$slim_ngd" reg
expect_value wcd9340-ifd-compatible slim217,250 \
	fdtget -ts "$dtb" "$wcd9340_ifd" compatible
expect_value wcd9340-ifd-address '0 0' \
	fdtget -tx "$dtb" "$wcd9340_ifd" reg
expect_value wcd9340-compatible slim217,250 \
	fdtget -ts "$dtb" "$wcd9340" compatible
expect_value wcd9340-address '1 0' fdtget -tx "$dtb" "$wcd9340" reg
expect_value wcd9340-clock-frequency 927c00 \
	fdtget -tx "$dtb" "$wcd9340" clock-frequency
expect_value wcd9340-interrupt-pin gpio123 \
	fdtget -ts "$dtb" "$wcd_intr" pins
tlmm_path=$(fdtget -ts "$dtb" /__symbols__ tlmm) ||
	die "missing TLMM symbol"
tlmm_phandle=$(fdtget -tx "$dtb" "$tlmm_path" phandle) ||
	die "missing TLMM phandle"
expect_value wcd9340-reset "$tlmm_phandle 8f 0" \
	fdtget -tx "$dtb" "$wcd9340" reset-gpios
expect_value wcd9340-interrupt "$tlmm_phandle 7b 4" \
	fdtget -tx "$dtb" "$wcd9340" interrupts-extended
vreg_s4a_path=$(fdtget -ts "$dtb" /__symbols__ vreg_s4a_1p8) ||
	die "missing vreg_s4a_1p8 symbol"
vreg_s4a_phandle=$(fdtget -tx "$dtb" "$vreg_s4a_path" phandle) ||
	die "missing vreg_s4a_1p8 phandle"
for supply_name in vdd-buck-sido vdd-buck vdd-tx vdd-rx vdd-io; do
	expect_value "wcd9340-$supply_name-supply" "$vreg_s4a_phandle" \
		fdtget -tx "$dtb" "$wcd9340" "$supply_name-supply"
done
for micbias in 1 2 3 4; do
	expect_value "wcd9340-micbias$micbias" 1b7740 \
		fdtget -tx "$dtb" "$wcd9340" "qcom,micbias$micbias-microvolt"
done
expect_value wcd9340-gpio-compatible qcom,wcd9340-gpio \
	fdtget -ts "$dtb" "$wcd9340_gpio" compatible
expect_value wcd9340-gpio-range '42 2' \
	fdtget -tx "$dtb" "$wcd9340_gpio" reg
expect_value wcd9340-soundwire-compatible qcom,soundwire-v1.3.0 \
	fdtget -ts "$dtb" "$wcd9340_swm" compatible
expect_value wcd9340-soundwire-range 'c85 40' \
	fdtget -tx "$dtb" "$wcd9340_swm" reg
expect_value sound-compatible qcom,sm8150-sndcard \
	fdtget -ts "$dtb" "$sound" compatible
expect_value sound-model 'OnePlus 7T Pro' fdtget -ts "$dtb" "$sound" model
expect_value sound-status okay fdtget -ts "$dtb" "$sound" status
expect_value sound-routing \
	'RX_BIAS MCLK AMIC1 MIC BIAS1 AMIC2 MIC BIAS2 AMIC3 MIC BIAS4 AMIC4 MIC BIAS1 AMIC5 MIC BIAS1' \
	fdtget -ts "$dtb" "$sound" audio-routing
expect_value q6asm-mm1-address 0 fdtget -tx "$dtb" "$q6asm_mm1" reg
expect_value q6asm-mm2-address 1 fdtget -tx "$dtb" "$q6asm_mm2" reg
q6asmdai_path=$(fdtget -ts "$dtb" /__symbols__ q6asmdai) ||
	die "missing Q6ASM DAI symbol"
q6asmdai_phandle=$(fdtget -tx "$dtb" "$q6asmdai_path" phandle) ||
	die "missing Q6ASM DAI phandle"
q6afedai_path=$(fdtget -ts "$dtb" /__symbols__ q6afedai) ||
	die "missing Q6AFE DAI symbol"
q6afedai_phandle=$(fdtget -tx "$dtb" "$q6afedai_path" phandle) ||
	die "missing Q6AFE DAI phandle"
q6afe_quat=$q6afedai_path/dai@22
expect_value q6afe-quat-mi2s-address 16 \
	fdtget -tx "$dtb" "$q6afe_quat" reg
expect_value q6afe-quat-mi2s-sd-line 1 \
	fdtget -tx "$dtb" "$q6afe_quat" qcom,sd-lines
q6routing_path=$(fdtget -ts "$dtb" /__symbols__ q6routing) ||
	die "missing Q6 routing symbol"
q6routing_phandle=$(fdtget -tx "$dtb" "$q6routing_path" phandle) ||
	die "missing Q6 routing phandle"
wcd9340_path=$(fdtget -ts "$dtb" /__symbols__ wcd9340) ||
	die "missing WCD9340 symbol"
wcd9340_phandle=$(fdtget -tx "$dtb" "$wcd9340_path" phandle) ||
	die "missing WCD9340 phandle"
speaker_top_path=$(fdtget -ts "$dtb" /__symbols__ speaker_top) ||
	die "missing top-speaker symbol"
speaker_top_phandle=$(fdtget -tx "$dtb" "$speaker_top_path" phandle) ||
	die "missing top-speaker phandle"
speaker_bottom_path=$(fdtget -ts "$dtb" /__symbols__ speaker_bottom) ||
	die "missing bottom-speaker symbol"
speaker_bottom_phandle=$(fdtget -tx "$dtb" "$speaker_bottom_path" phandle) ||
	die "missing bottom-speaker phandle"
quat_mi2s_phandle=$(fdtget -tx "$dtb" "$quat_mi2s" phandle) ||
	die "missing QUAT MI2S clock-state phandle"
quat_mi2s_sd0_phandle=$(fdtget -tx "$dtb" "$quat_mi2s_sd0" phandle) ||
	die "missing QUAT MI2S SD0-state phandle"
quat_mi2s_sd1_phandle=$(fdtget -tx "$dtb" "$quat_mi2s_sd1" phandle) ||
	die "missing QUAT MI2S SD1-state phandle"
expect_value sound-pinctrl \
	"$quat_mi2s_phandle $quat_mi2s_sd0_phandle $quat_mi2s_sd1_phandle" \
	fdtget -tx "$dtb" "$sound" pinctrl-0
expect_value sound-mm1-name MultiMedia1 \
	fdtget -ts "$dtb" "$sound_mm1" link-name
expect_value sound-mm1-cpu "$q6asmdai_phandle 0" \
	fdtget -tx "$dtb" "$sound_mm1/cpu" sound-dai
expect_value sound-mm2-name MultiMedia2 \
	fdtget -ts "$dtb" "$sound_mm2" link-name
expect_value sound-mm2-cpu "$q6asmdai_phandle 1" \
	fdtget -tx "$dtb" "$sound_mm2/cpu" sound-dai
expect_value sound-speaker-name 'Speaker Playback' \
	fdtget -ts "$dtb" "$sound_speaker" link-name
expect_value sound-speaker-cpu "$q6afedai_phandle 16" \
	fdtget -tx "$dtb" "$sound_speaker/cpu" sound-dai
expect_value sound-speaker-platform "$q6routing_phandle" \
	fdtget -tx "$dtb" "$sound_speaker/platform" sound-dai
expect_value sound-speaker-codecs "$speaker_top_phandle $speaker_bottom_phandle" \
	fdtget -tx "$dtb" "$sound_speaker/codec" sound-dai
expect_value sound-slim-name 'SLIM Playback 6' \
	fdtget -ts "$dtb" "$sound_slim" link-name
expect_value sound-slim-cpu "$q6afedai_phandle e" \
	fdtget -tx "$dtb" "$sound_slim/cpu" sound-dai
expect_value sound-slim-platform "$q6routing_phandle" \
	fdtget -tx "$dtb" "$sound_slim/platform" sound-dai
expect_value sound-slim-codec "$wcd9340_phandle 6" \
	fdtget -tx "$dtb" "$sound_slim/codec" sound-dai
expect_value sound-slimcap-name 'SLIM Capture 1' \
	fdtget -ts "$dtb" "$sound_slimcap" link-name
expect_value sound-slimcap-cpu "$q6afedai_phandle 3" \
	fdtget -tx "$dtb" "$sound_slimcap/cpu" sound-dai
expect_value sound-slimcap-platform "$q6routing_phandle" \
	fdtget -tx "$dtb" "$sound_slimcap/platform" sound-dai
expect_value sound-slimcap-codec "$wcd9340_phandle 1" \
	fdtget -tx "$dtb" "$sound_slimcap/codec" sound-dai
expect_absent sound-aux-devices fdtget "$dtb" "$sound" aux-devs
expect_value rmtfs-hotdog-address '0 fc201000 0 200000' \
	fdtget -tx "$dtb" "$rmtfs_mem" reg
expect_value rmtfs-client 1 fdtget -tx "$dtb" "$rmtfs_mem" qcom,client-id
expect_value rmtfs-vmid f fdtget -tx "$dtb" "$rmtfs_mem" qcom,vmid
expect_value wifi-compatible qcom,wcn3990-wifi \
	fdtget -ts "$dtb" "$wifi" compatible
expect_value wifi-status okay fdtget -ts "$dtb" "$wifi" status
expect_value wifi-registers '0 18800000 0 800000' \
	fdtget -tx "$dtb" "$wifi" reg
expect_value wifi-iommus "$apps_smmu_phandle 640 1" \
	fdtget -tx "$dtb" "$wifi" iommus
wlan_mem_phandle=$(fdtget -tx "$dtb" "$wlan_mem" phandle) ||
	die "missing WLAN MSA memory phandle"
expect_value wifi-memory "$wlan_mem_phandle" \
	fdtget -tx "$dtb" "$wifi" memory-region
for supply in \
	'vdd-0.8-cx-mx:vreg_l1a_0p75' \
	'vdd-1.8-xo:vreg_l7a_1p8' \
	'vdd-1.3-rfa:vreg_l2c_1p3' \
	'vdd-3.3-ch0:vreg_l11c_3p3' \
	'vdd-3.3-ch1:vreg_l10c_3p3'; do
	supply_name=${supply%%:*}
	supply_symbol=${supply#*:}
	supply_path=$(fdtget -ts "$dtb" /__symbols__ "$supply_symbol") ||
		die "missing Wi-Fi regulator symbol: $supply_symbol"
	supply_phandle=$(fdtget -tx "$dtb" "$supply_path" phandle) ||
		die "missing Wi-Fi regulator phandle: $supply_symbol"
	expect_value "wifi-$supply_name-supply" "$supply_phandle" \
		fdtget -tx "$dtb" "$wifi" "$supply_name-supply"
done

expect_value uart13-status okay fdtget -ts "$dtb" "$uart13" status
expect_value uart13-pinctrl-names 'default sleep' \
	fdtget -ts "$dtb" "$uart13" pinctrl-names
expect_value bluetooth-compatible qcom,wcn3990-bt \
	fdtget -ts "$dtb" "$bluetooth" compatible
expect_value bluetooth-firmware 'crnv21.bin crbtfw21.tlv' \
	fdtget -ts "$dtb" "$bluetooth" firmware-name
expect_value bluetooth-speed 30d400 \
	fdtget -tx "$dtb" "$bluetooth" max-speed
expect_value bluetooth-sleep-pins 'gpio43 gpio44 gpio45 gpio46' \
	fdtget -ts "$dtb" "$uart13_sleep/pinmux" pins
for supply in \
	'vddio:vreg_l1a_0p75' \
	'vddxo:vreg_l7a_1p8' \
	'vddrf:vreg_l2c_1p3' \
	'vddch0:vreg_l11c_3p3'; do
	supply_name=${supply%%:*}
	supply_symbol=${supply#*:}
	supply_path=$(fdtget -ts "$dtb" /__symbols__ "$supply_symbol") ||
		die "missing Bluetooth regulator symbol: $supply_symbol"
	supply_phandle=$(fdtget -tx "$dtb" "$supply_path" phandle) ||
		die "missing Bluetooth regulator phandle: $supply_symbol"
	expect_value "bluetooth-$supply_name-supply" "$supply_phandle" \
		fdtget -tx "$dtb" "$bluetooth" "$supply_name-supply"
done

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
expect_value volume-down-gpio "$pm8150_gpios_phandle 7 1" \
	fdtget -tx "$dtb" "$volume_down" gpios
volume_up_state_phandle=$(fdtget -tx "$dtb" "$volume_up_state" phandle) ||
	die "missing Volume Up pinctrl phandle"
volume_down_state_phandle=$(fdtget -tx "$dtb" "$volume_down_state" phandle) ||
	die "missing Volume Down pinctrl phandle"
expect_value volume-key-pinctrl \
	"$volume_up_state_phandle $volume_down_state_phandle" \
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
# Volume down is a PMIC GPIO like volume up. RESIN is not wired to it on this
# board, so it must stay disabled rather than offering a key it cannot report.
expect_value volume-down-label volume_down fdtget -ts "$dtb" "$volume_down" label
expect_value volume-down-code 72 fdtget -tx "$dtb" "$volume_down" linux,code
expect_value volume-down-input-type 1 \
	fdtget -tx "$dtb" "$volume_down" linux,input-type
expect_value volume-down-debounce f \
	fdtget -tx "$dtb" "$volume_down" debounce-interval
expect_value volume-down-pin gpio7 \
	fdtget -ts "$dtb" "$volume_down_state" pins
expect_value volume-down-resin-disabled disabled \
	fdtget -ts "$dtb" "$pm8150/pon@800/resin" status

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
