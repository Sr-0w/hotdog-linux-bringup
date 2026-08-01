#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source "$(dirname "$0")/env.sh"

INPUT_DTB="$HOTDOG_ROOT/images/pmos-experiments/2026-07-30-010517-mainline617-direct-rdinit-first511-restart2/components/replacement.dtb"
INPUT_SHA256="040b4b50989b01dafe400436137bf73a64f3ad5e89bf4c7ddf79a19b3cfcee4c"
OUTDIR=""

usage() {
	cat <<'USAGE'
Usage: build-mainline-hotdog-ufs-no-device-reset-dtb.sh [options]

Build a controlled hotdog direct-boot DTB that differs from the pinned
mainline DTB only by removal of the UFS controller's reset-gpios property.
This reproduces the attached-device reset policy used by the external
ClearStaff hotdog DTS. It does not modify phone storage.

Options:
  --input-dtb FILE  Pinned native-mainline hotdog DTB.
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

OUTDIR="${OUTDIR:-$HOTDOG_ROOT/build/experiments/$(date +%F-%H%M%S)-mainline617-hotdog-ufs-no-device-reset-dtb}"
OUTPUT_DTB="$OUTDIR/sm8150-oneplus-hotdog-ufs-no-device-reset.dtb"
UFS_NODE="/soc@0/ufshc@1d84000"

for command_name in cmp dtc fdtget fdtput sha256sum; do
	command -v "$command_name" >/dev/null 2>&1 || {
		printf 'Missing command: %s\n' "$command_name" >&2
		exit 127
	}
done
[ -s "$INPUT_DTB" ] || { printf 'Missing input DTB: %s\n' "$INPUT_DTB" >&2; exit 2; }

actual_input_sha256="$(sha256sum "$INPUT_DTB" | awk '{ print $1 }')"
[ "$actual_input_sha256" = "$INPUT_SHA256" ] || {
	printf 'Input DTB SHA256 mismatch: expected %s, got %s\n' \
		"$INPUT_SHA256" "$actual_input_sha256" >&2
	exit 2
}
[ "$(fdtget -t x "$INPUT_DTB" "$UFS_NODE" reset-gpios)" = "4e af 1" ] || {
	printf 'Unexpected UFS reset-gpios property\n' >&2
	exit 2
}
[ "$(fdtget -t s "$INPUT_DTB" "$UFS_NODE" status)" = "okay" ] || {
	printf 'The input UFS controller is not enabled\n' >&2
	exit 2
}

mkdir -p "$OUTDIR"
cp "$INPUT_DTB" "$OUTPUT_DTB"
fdtput -d "$OUTPUT_DTB" "$UFS_NODE" reset-gpios

if fdtget "$OUTPUT_DTB" "$UFS_NODE" reset-gpios >/dev/null 2>&1; then
	printf 'UFS reset-gpios still exists after transformation\n' >&2
	exit 3
fi
[ "$(fdtget -t s "$OUTPUT_DTB" "$UFS_NODE" status)" = "okay" ] || {
	printf 'UFS status changed unexpectedly\n' >&2
	exit 3
}

dtc -I dtb -O dts -o "$OUTDIR/input.dts" "$INPUT_DTB" \
	2> "$OUTDIR/input-dtc-warnings.txt"
dtc -I dtb -O dts -o "$OUTDIR/output.dts" "$OUTPUT_DTB" \
	2> "$OUTDIR/output-dtc-warnings.txt"
sed '/^[[:space:]]*reset-gpios = /d' "$OUTDIR/input.dts" > "$OUTDIR/input-without-reset-gpios.dts"
cmp "$OUTDIR/input-without-reset-gpios.dts" "$OUTDIR/output.dts" || {
	printf 'The transformed DTB differs by more than reset-gpios removal\n' >&2
	exit 3
}

{
	printf 'input_sha256=%s\n' "$INPUT_SHA256"
	printf 'input_ufs_reset_gpios=4e af 1\n'
	printf 'output_ufs_reset_gpios=removed\n'
	printf 'semantic_delta=reset-gpios-only\n'
} > "$OUTDIR/changes.txt"
sha256sum "$INPUT_DTB" "$OUTPUT_DTB" > "$OUTDIR/SHA256SUMS"

printf 'Output DTB: %s\n' "$OUTPUT_DTB"
cat "$OUTDIR/changes.txt"
cat "$OUTDIR/SHA256SUMS"
