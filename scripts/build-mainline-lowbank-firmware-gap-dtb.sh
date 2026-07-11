#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/env.sh"

INPUT_DTB="$HOTDOG_ROOT/build/experiments/2026-07-11-100000-mainline617-kexec-lowbank-dtb/sm8150-oneplus-hotdog-kexec-lowbank.dtb"
STOCK_DTB="$HOTDOG_ROOT/build/experiments/2026-07-09-091600-stockdtb12-dtbo5-simplefb/stockdtb12-dtbo5-simplefb-1440x3120-x8r8g8b8.dtb"
OUTDIR=""

usage() {
	cat <<'USAGE'
Usage: build-mainline-lowbank-firmware-gap-dtb.sh [options]

Add the firmware-owned 0x89d00000-0x8b700000 no-map gap that is covered by
the stock hotdog removed_regions reservation but absent from the mainline DTB.

Options:
  --input-dtb FILE  Mainline low-bank DTB to patch.
  --stock-dtb FILE  Stock merged DTB used to verify the expected upper bound.
  --outdir DIR      Output directory below build/experiments by default.
  -h, --help        Show this help.
USAGE
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--input-dtb) INPUT_DTB="$2"; shift ;;
		--stock-dtb) STOCK_DTB="$2"; shift ;;
		--outdir) OUTDIR="$2"; shift ;;
		-h|--help) usage; exit 0 ;;
		*) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
	esac
	shift
done

OUTDIR="${OUTDIR:-$HOTDOG_ROOT/build/experiments/$(date +%F-%H%M%S)-mainline617-lowbank-firmware-gap-dtb}"
OUTPUT_DTB="$OUTDIR/sm8150-oneplus-hotdog-kexec-lowbank-firmware-gap.dtb"
GAP_NODE="/reserved-memory/hotdog-removed-gap@89d00000"

for command_name in cmp dtc fdtget fdtput sha256sum; do
	command -v "$command_name" >/dev/null 2>&1 || {
		printf 'Missing command: %s\n' "$command_name" >&2
		exit 127
	}
done
for input in "$INPUT_DTB" "$STOCK_DTB"; do
	[ -s "$input" ] || { printf 'Missing input DTB: %s\n' "$input" >&2; exit 2; }
done

main_removed="$(fdtget -t x "$INPUT_DTB" /reserved-memory/memory@86200000 reg)"
main_rmtfs="$(fdtget -t x "$INPUT_DTB" /reserved-memory/memory@f2901000 reg)"
stock_removed="$(fdtget -t x "$STOCK_DTB" /reserved-memory/removed_regions reg)"
[ "$main_removed" = "0 86200000 0 3900000" ] || {
	printf 'Unexpected mainline removed range: %s\n' "$main_removed" >&2
	exit 2
}
[ "$main_rmtfs" = "0 89b00000 0 200000" ] || {
	printf 'Unexpected mainline RMTFS range: %s\n' "$main_rmtfs" >&2
	exit 2
}
[ "$stock_removed" = "0 86200000 0 5500000" ] || {
	printf 'Unexpected stock removed range: %s\n' "$stock_removed" >&2
	exit 2
}

mkdir -p "$OUTDIR"
cp "$INPUT_DTB" "$OUTPUT_DTB"
fdtput -cp "$OUTPUT_DTB" "$GAP_NODE"
fdtput -t x "$OUTPUT_DTB" "$GAP_NODE" reg 0 0x89d00000 0 0x1a00000
fdtput "$OUTPUT_DTB" "$GAP_NODE" no-map

[ "$(fdtget -t x "$OUTPUT_DTB" /memory reg)" = "0 80000000 0 3bb00000" ]
[ "$(fdtget -t x "$OUTPUT_DTB" "$GAP_NODE" reg)" = "0 89d00000 0 1a00000" ]
fdtget -p "$OUTPUT_DTB" "$GAP_NODE" | grep -qx 'no-map'

dtc -I dtb -O dts -o "$OUTDIR/verify.dts" "$OUTPUT_DTB" 2> "$OUTDIR/dtc-warnings.txt"
dtc -I dts -O dtb -o "$OUTDIR/roundtrip.dtb" "$OUTDIR/verify.dts" 2>> "$OUTDIR/dtc-warnings.txt"
cmp "$OUTPUT_DTB" "$OUTDIR/roundtrip.dtb" || true

{
	printf 'input_memory=%s\n' "$(fdtget -t x "$INPUT_DTB" /memory reg)"
	printf 'main_removed=%s\n' "$main_removed"
	printf 'main_rmtfs=%s\n' "$main_rmtfs"
	printf 'added_gap=%s\n' "$(fdtget -t x "$OUTPUT_DTB" "$GAP_NODE" reg)"
	printf 'stock_removed=%s\n' "$stock_removed"
} > "$OUTDIR/ranges.txt"
sha256sum "$INPUT_DTB" "$STOCK_DTB" "$OUTPUT_DTB" > "$OUTDIR/SHA256SUMS"

printf 'Output DTB: %s\n' "$OUTPUT_DTB"
cat "$OUTDIR/ranges.txt"
cat "$OUTDIR/SHA256SUMS"
