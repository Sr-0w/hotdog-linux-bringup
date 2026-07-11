#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/env.sh"

INPUT_DTB="$HOTDOG_ROOT/build/experiments/2026-07-11-112700-mainline617-lowbank-firmware-gap-dtb/sm8150-oneplus-hotdog-kexec-lowbank-firmware-gap.dtb"
OUTDIR=""

usage() {
	cat <<'USAGE'
Usage: build-mainline-ufs-smmu-bypass-dtb.sh [options]

Build a temporary bring-up DTB that removes the Apps SMMU links from UFS and
QUP. Boot it with arm-smmu.disable_bypass=0 so those streams use direct DMA
while the SMMU registration failure is investigated.

Options:
  --input-dtb FILE  Firmware-gap-fixed mainline DTB.
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

OUTDIR="${OUTDIR:-$HOTDOG_ROOT/build/experiments/$(date +%F-%H%M%S)-mainline617-ufs-smmu-bypass-dtb}"
OUTPUT_DTB="$OUTDIR/sm8150-oneplus-hotdog-kexec-lowbank-ufs-smmu-bypass.dtb"
UFS_NODE="/soc@0/ufshc@1d84000"
QUP_NODE="/soc@0/geniqup@ac0000"

for command_name in dtc fdtget fdtput sha256sum; do
	command -v "$command_name" >/dev/null 2>&1 || {
		printf 'Missing command: %s\n' "$command_name" >&2
		exit 127
	}
done
[ -s "$INPUT_DTB" ] || { printf 'Missing input DTB: %s\n' "$INPUT_DTB" >&2; exit 2; }

ufs_iommus="$(fdtget -t x "$INPUT_DTB" "$UFS_NODE" iommus)"
qup_iommus="$(fdtget -t x "$INPUT_DTB" "$QUP_NODE" iommus)"
[ "$ufs_iommus" = "2b 300 0" ] || {
	printf 'Unexpected UFS iommus property: %s\n' "$ufs_iommus" >&2
	exit 2
}
[ "$qup_iommus" = "2b 603 0" ] || {
	printf 'Unexpected QUP iommus property: %s\n' "$qup_iommus" >&2
	exit 2
}
[ "$(fdtget -t x "$INPUT_DTB" /reserved-memory/hotdog-removed-gap@89d00000 reg)" = "0 89d00000 0 1a00000" ] || {
	printf 'Input DTB is missing the validated firmware gap reservation\n' >&2
	exit 2
}

mkdir -p "$OUTDIR"
cp "$INPUT_DTB" "$OUTPUT_DTB"
fdtput -d "$OUTPUT_DTB" "$UFS_NODE" iommus
fdtput -d "$OUTPUT_DTB" "$QUP_NODE" iommus

if fdtget "$OUTPUT_DTB" "$UFS_NODE" iommus >/dev/null 2>&1; then
	printf 'UFS iommus property still exists after patch\n' >&2
	exit 3
fi
if fdtget "$OUTPUT_DTB" "$QUP_NODE" iommus >/dev/null 2>&1; then
	printf 'QUP iommus property still exists after patch\n' >&2
	exit 3
fi

dtc -I dtb -O dts -o "$OUTDIR/verify.dts" "$OUTPUT_DTB" 2> "$OUTDIR/dtc-warnings.txt"
{
	printf 'input_ufs_iommus=%s\n' "$ufs_iommus"
	printf 'input_qup_iommus=%s\n' "$qup_iommus"
	printf 'output_ufs_iommus=removed\n'
	printf 'output_qup_iommus=removed\n'
	printf 'required_cmdline=arm-smmu.disable_bypass=0\n'
} > "$OUTDIR/changes.txt"
sha256sum "$INPUT_DTB" "$OUTPUT_DTB" > "$OUTDIR/SHA256SUMS"

printf 'Output DTB: %s\n' "$OUTPUT_DTB"
cat "$OUTDIR/changes.txt"
cat "$OUTDIR/SHA256SUMS"
