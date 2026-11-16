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
	echo "hotdog clean 6.17 validation: $*" >&2
	exit 1
}

expect_config() {
	grep -qx "$1" "$config" || die "missing config: $1"
}

[ -s "$image" ] || die "missing Image: $image"
[ -s "$config" ] || die "missing config: $config"
[ -s "$dtb" ] || die "missing DTB: $dtb"

expect_config 'CONFIG_LOCALVERSION="-sm8150-hotdog-clean"'
expect_config '# CONFIG_LOCALVERSION_AUTO is not set'
expect_config 'CONFIG_ONEPLUS_HOTDOG_EARLY_BOOT=y'
expect_config 'CONFIG_DRM_PANEL_SAMSUNG_ONEPLUS_DSC=y'
expect_config 'CONFIG_DRM_MSM=y'
expect_config 'CONFIG_TOUCHSCREEN_S6SY761=m'
expect_config 'CONFIG_INPUT_AW8697_HAPTICS=y'
expect_config 'CONFIG_SCSI_UFS_QCOM=y'
expect_config 'CONFIG_ARM_SMMU=y'
expect_config 'CONFIG_QCOM_IPA=m'
expect_config 'CONFIG_ATH10K_SNOC=m'
expect_config 'CONFIG_BT_QCA=m'
expect_config 'CONFIG_QCOM_Q6V5_ADSP=m'
expect_config 'CONFIG_QCOM_Q6V5_MSS=m'
expect_config 'CONFIG_SND_SOC_SM8150=m'
expect_config 'CONFIG_SND_SOC_TFA9874=m'
expect_config 'CONFIG_SND_SOC_WCD934X=m'
expect_config 'CONFIG_I2C_QCOM_CCI=m'
expect_config 'CONFIG_VIDEO_QCOM_CAMSS=m'
expect_config 'CONFIG_VIDEO_QCOM_HOTDOG_POPUP=m'
expect_config 'CONFIG_VIDEO_IMX471=m'
expect_config 'CONFIG_VIDEO_IMX481=m'
expect_config 'CONFIG_VIDEO_IMX586=m'
expect_config 'CONFIG_VIDEO_S5K3M5=m'
expect_config 'CONFIG_VIDEO_AK7375=m'
expect_config 'CONFIG_VIDEO_LC898217XC=m'
expect_config 'CONFIG_MXM1120=m'
expect_config 'CONFIG_QCOM_FASTRPC=m'
expect_config 'CONFIG_QCOM_PD_MAPPER=m'
expect_config 'CONFIG_SND_SOC_QDSP6_ELLIPTIC=m'
expect_config 'CONFIG_SND_SOC_QDSP6_HOSTLESS=m'
expect_config 'CONFIG_USB_CONFIGFS_ACM=y'
expect_config 'CONFIG_USB_CONFIGFS_NCM=y'
expect_config '# CONFIG_RAID6_PQ_BENCHMARK is not set'

python3 - "$image" <<'PY'
import pathlib
import struct
import sys

image = pathlib.Path(sys.argv[1]).read_bytes()
if len(image) < 64:
    raise SystemExit("arm64 Image is shorter than its header")
text_offset, image_size = struct.unpack_from("<QQ", image, 8)
if text_offset != 0x80000:
    raise SystemExit(f"unexpected Image text offset: {text_offset:#x}")
if image_size != 0x1AD0000:
    raise SystemExit(f"unexpected Image size field: {image_size:#x}")
if image[56:60] != b"ARMd":
    raise SystemExit("missing arm64 Image magic")
PY

for contract in \
	'CONFIG_ONEPLUS_HOTDOG_EARLY_BOOT' \
	'0x01ad0000' \
	'APSS WDT: 0x17c10000'; do
	grep -q "$contract" arch/arm64/kernel/head.S ||
		die "missing direct-boot source contract: $contract"
done
for forbidden in hotdog_fb_stage hotdog_pmsg_stage hotdog_entry_canary; do
	! grep -q "$forbidden" arch/arm64/kernel/head.S ||
		die "historical entry instrumentation remains: $forbidden"
done

dts=$(mktemp)
trap 'rm -f "$dts"' EXIT HUP INT TERM
dtc -q -I dtb -O dts -o "$dts" "$dtb"

for contract in \
	'compatible = "oneplus,hotdog", "oneplus,oneplus7", "qcom,sm8150"' \
	'compatible = "samsung,oneplus-dsc"' \
	'compatible = "samsung,s6sy761"' \
	'compatible = "awinic,aw8697"' \
	'compatible = "nxp,pn553", "nxp,nxp-nci-i2c"' \
	'compatible = "qcom,sm8150-ipa"' \
	'compatible = "qcom,sm8150-sndcard"' \
	'compatible = "nxp,tfa9874"' \
	'compatible = "qcom,wcn3990-bt"' \
	'firmware-name = "qcom/sm8150/oneplus/hotdog/modem.mbn"' \
	'firmware-name = "qcom/sm8150/oneplus/hotdog/adsp.mbn"' \
	'firmware-name = "qcom/sm8150/oneplus/hotdog/ipa_fws.mbn"' \
	'compatible = "qcom,sm8150-camss"' \
	'compatible = "sony,imx586"' \
	'compatible = "sony,imx481"' \
	'compatible = "sony,imx471"' \
	'compatible = "samsung,s5k3m5"' \
	'compatible = "onnn,lc898217xc"' \
	'compatible = "magnachip,mxm1120"' \
	'compatible = "oneplus,hotdog-popup-motor"' \
	'firmware-name = "qcom/sm8150/oneplus/hotdog/slpi.mbn"' \
	'compatible = "oneplus,hotdog-elliptic-ultrasound"' \
	'compatible = "qcom,q6dsp-hostless-dais"' \
	'label = "Alert slider"' \
	'linux,code = <0x22>' \
	'compatible = "usb-c-connector"' \
	'compatible = "syscon-reboot-mode"' \
	'mode-bootloader = "wfU"' \
	'mode-recovery = <0x77665502>' \
	'firmware-name = "qcom/sm8150/oneplus/hotdog/a640_zap.mbn"' \
	'iommus = <' \
	'reg = <0x00 0x85e40000 0x00 0xc0000>' \
	'reg = <0x00 0x89d00000 0x00 0x1a00000>' \
	'reg = <0x00 0xfc201000 0x00 0x200000>'; do
	grep -Fq "$contract" "$dts" || die "missing DTB contract: $contract"
done

grep -aFq 'samsung,oneplus-dsc' "$image" ||
	die "built-in panel driver is absent from Image"

for symbol in mdss_dsi0 mdss_dsi1 mdss_mdp pcie0 sdhc_2 soc spmi_bus tlmm; do
	fdtget -p "$dtb" /__symbols__ | grep -qx "$symbol" ||
		die "missing bootloader-overlay symbol: $symbol"
done

[ "$(fdtget -t s "$dtb" /soc@0/geniqup@8c0000 status)" = okay ] ||
	die "QUP0 haptics wrapper is not enabled"

if [ -n "$modules_dir" ]; then
	[ -d "$modules_dir" ] || die "missing modules directory: $modules_dir"
	for module_name in s6sy761.ko ipa.ko ath10k_snoc.ko qcom_q6v5_pas.ko \
			snd-soc-sm8150.ko snd-soc-tfa9874.ko snd-soc-wcd934x.ko \
			qcom-camss.ko imx586.ko imx481.ko imx471.ko s5k3m5.ko \
			ak7375.ko lc898217xc.ko mxm1120.ko hotdog-popup-motor.ko \
			qcom_pd_mapper.ko q6elliptic.ko q6hostless.ko; do
		module=$(find "$modules_dir" -type f -name "$module_name" -print -quit)
		[ -n "$module" ] || die "$module_name is absent"
		vermagic=$(modinfo -F vermagic "$module")
		case "$vermagic" in
			6.17.0-sm8150-hotdog-clean\ *) ;;
			*) die "unexpected $module_name vermagic: $vermagic" ;;
		esac
	done
fi

echo "hotdog clean 6.17 validation: PASS"
