#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/env.sh"

INPUT_DTB="$HOTDOG_ROOT/build/experiments/2026-07-11-121000-mainline617-ufs-no-ice-dtb/sm8150-oneplus-hotdog-kexec-lowbank-ufs-smmu-bypass-no-ice.dtb"
OUTDIR=""

usage() {
	cat <<'USAGE'
Usage: build-mainline-pmos-boot-dtb.sh [options]

Build the current postmarketOS boot DTB. The input must already reserve the
validated firmware gap, bypass Apps SMMU for UFS/QUP, and make ICE optional.
This final step removes the DWC3 Apps SMMU link so USB probes before the pmOS
initramfs performs its one-shot gadget setup.

Options:
  --input-dtb FILE  Validated UFS-capable mainline DTB.
  --outdir DIR      Output directory below build/experiments by default.
  -h, --help        Show this help.
USAGE
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--input-dtb) INPUT_DTB="$2"; shift ;;
		--outdir) OUTDIR="$2"; shift ;;
		-h|--help) usage; exit 0 ;;
		*) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
	esac
	shift
done

OUTDIR="${OUTDIR:-$HOTDOG_ROOT/build/experiments/$(date +%F-%H%M%S)-mainline617-pmos-boot-dtb}"
OUTPUT_DTB="$OUTDIR/sm8150-oneplus-hotdog-mainline-pmos-boot.dtb"
UFS_NODE="/soc@0/ufshc@1d84000"
QUP_NODE="/soc@0/geniqup@ac0000"
DWC3_NODE="/soc@0/usb@a6f8800/usb@a600000"

for command_name in dtc fdtget fdtput sha256sum; do
	command -v "$command_name" >/dev/null 2>&1 || {
		printf 'Missing command: %s\n' "$command_name" >&2
		exit 127
	}
done
[ -s "$INPUT_DTB" ] || { printf 'Missing input DTB: %s\n' "$INPUT_DTB" >&2; exit 2; }

[ "$(fdtget -t x "$INPUT_DTB" "$DWC3_NODE" iommus)" = "2b 140 0" ] || {
	printf 'Unexpected DWC3 iommus property\n' >&2
	exit 2
}
[ "$(fdtget -t x "$INPUT_DTB" /reserved-memory/hotdog-removed-gap@89d00000 reg)" = "0 89d00000 0 1a00000" ] || {
	printf 'Input DTB is missing the validated firmware gap reservation\n' >&2
	exit 2
}
for node in "$UFS_NODE" "$QUP_NODE"; do
	if fdtget "$INPUT_DTB" "$node" iommus >/dev/null 2>&1; then
		printf 'Input DTB still contains iommus on %s\n' "$node" >&2
		exit 2
	fi
done
if fdtget "$INPUT_DTB" "$UFS_NODE" qcom,ice >/dev/null 2>&1; then
	printf 'Input DTB still contains UFS qcom,ice\n' >&2
	exit 2
fi

mkdir -p "$OUTDIR"
cp "$INPUT_DTB" "$OUTPUT_DTB"
fdtput -d "$OUTPUT_DTB" "$DWC3_NODE" iommus

if fdtget "$OUTPUT_DTB" "$DWC3_NODE" iommus >/dev/null 2>&1; then
	printf 'DWC3 iommus property still exists after patch\n' >&2
	exit 3
fi

dtc -I dtb -O dts -o "$OUTDIR/verify.dts" "$OUTPUT_DTB" 2> "$OUTDIR/dtc-warnings.txt"
{
	printf 'input_dwc3_iommus=2b 140 0\n'
	printf 'output_dwc3_iommus=removed\n'
	printf 'required_cmdline=arm-smmu.disable_bypass=0\n'
} > "$OUTDIR/changes.txt"
sha256sum "$INPUT_DTB" "$OUTPUT_DTB" > "$OUTDIR/SHA256SUMS"

printf 'Output DTB: %s\n' "$OUTPUT_DTB"
cat "$OUTDIR/changes.txt"
cat "$OUTDIR/SHA256SUMS"
