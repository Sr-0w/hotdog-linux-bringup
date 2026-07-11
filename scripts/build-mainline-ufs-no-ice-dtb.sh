#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/env.sh"

INPUT_DTB="$HOTDOG_ROOT/build/experiments/2026-07-11-120000-mainline617-ufs-smmu-bypass-dtb/sm8150-oneplus-hotdog-kexec-lowbank-ufs-smmu-bypass.dtb"
OUTDIR=""

usage() {
	cat <<'USAGE'
Usage: build-mainline-ufs-no-ice-dtb.sh [options]

Build a temporary bring-up DTB that makes Qualcomm ICE optional for UFS. The
input must already contain the validated firmware-gap reservation and the UFS
and QUP Apps SMMU bypass. Only the UFS qcom,ice phandle is removed.

Options:
  --input-dtb FILE  Firmware-gap and SMMU-bypass DTB.
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

OUTDIR="${OUTDIR:-$HOTDOG_ROOT/build/experiments/$(date +%F-%H%M%S)-mainline617-ufs-no-ice-dtb}"
OUTPUT_DTB="$OUTDIR/sm8150-oneplus-hotdog-kexec-lowbank-ufs-smmu-bypass-no-ice.dtb"
UFS_NODE="/soc@0/ufshc@1d84000"
QUP_NODE="/soc@0/geniqup@ac0000"
ICE_NODE="/soc@0/crypto@1d90000"

for command_name in dtc fdtget fdtput sha256sum; do
	command -v "$command_name" >/dev/null 2>&1 || {
		printf 'Missing command: %s\n' "$command_name" >&2
		exit 127
	}
done
[ -s "$INPUT_DTB" ] || { printf 'Missing input DTB: %s\n' "$INPUT_DTB" >&2; exit 2; }

[ "$(fdtget -t x "$INPUT_DTB" "$UFS_NODE" qcom,ice)" = "65" ] || {
	printf 'Unexpected UFS qcom,ice phandle\n' >&2
	exit 2
}
[ "$(fdtget -t x "$INPUT_DTB" "$ICE_NODE" phandle)" = "65" ] || {
	printf 'UFS qcom,ice does not point to the expected ICE node\n' >&2
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

mkdir -p "$OUTDIR"
cp "$INPUT_DTB" "$OUTPUT_DTB"
fdtput -d "$OUTPUT_DTB" "$UFS_NODE" qcom,ice

if fdtget "$OUTPUT_DTB" "$UFS_NODE" qcom,ice >/dev/null 2>&1; then
	printf 'UFS qcom,ice property still exists after patch\n' >&2
	exit 3
fi
[ "$(fdtget -t x "$OUTPUT_DTB" "$ICE_NODE" phandle)" = "65" ] || {
	printf 'ICE node changed unexpectedly\n' >&2
	exit 3
}

dtc -I dtb -O dts -o "$OUTDIR/verify.dts" "$OUTPUT_DTB" 2> "$OUTDIR/dtc-warnings.txt"
{
	printf 'input_ufs_qcom_ice=65\n'
	printf 'output_ufs_qcom_ice=removed\n'
	printf 'ice_node=unchanged\n'
	printf 'required_cmdline=arm-smmu.disable_bypass=0\n'
} > "$OUTDIR/changes.txt"
sha256sum "$INPUT_DTB" "$OUTPUT_DTB" > "$OUTDIR/SHA256SUMS"

printf 'Output DTB: %s\n' "$OUTPUT_DTB"
cat "$OUTDIR/changes.txt"
cat "$OUTDIR/SHA256SUMS"
