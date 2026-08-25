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
	touch_module=$(find "$modules_dir" -type f -name 's6sy761.ko' -print -quit)
	[ -n "$touch_module" ] || die "s6sy761.ko is absent"
	vermagic=$(modinfo -F vermagic "$touch_module")
	case "$vermagic" in
		6.17.0-sm8150-hotdog-clean\ *) ;;
		*) die "unexpected touch module vermagic: $vermagic" ;;
	esac
fi

echo "hotdog clean 6.17 validation: PASS"
