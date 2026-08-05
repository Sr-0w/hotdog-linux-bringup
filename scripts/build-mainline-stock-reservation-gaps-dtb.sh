#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/env.sh"

INPUT_DTB=""
STOCK_DTB=""
OUTDIR=""

usage() {
	cat <<'USAGE'
Usage: build-mainline-stock-reservation-gaps-dtb.sh --input-dtb FILE [options]

Complete the HD1913 stock reserved-memory coverage in a mainline hotdog DTB
that already contains the XBL/AOP gap fix. The two remaining intervals are
0x89b00000-0x89d00000 and 0x99517000-0x99600000. This builder is offline-only
and never communicates with the phone.

Options:
  --input-dtb FILE  Mainline hotdog DTB containing the r21 reservation.
  --stock-dtb FILE  Optional merged stock DTB used as an evidence check.
  --outdir DIR      Output directory below build/experiments by default.
  -h, --help        Show this help.
USAGE
}

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
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

[ -n "$INPUT_DTB" ] || die "--input-dtb is required"
OUTDIR="${OUTDIR:-$HOTDOG_ROOT/build/experiments/$(date +%F-%H%M%S)-mainline616-stock-reservation-gaps-dtb}"
OUTPUT_DTB="$OUTDIR/sm8150-oneplus-hotdog-stock-reserved.dtb"
REMOVED_NODE="/reserved-memory/memory@89b00000"
CDSP_NODE="/reserved-memory/memory@99517000"

for command_name in cp dtc fdtget fdtput rg sha256sum; do
	command -v "$command_name" >/dev/null 2>&1 || die "missing command: $command_name"
done
[ -s "$INPUT_DTB" ] || die "missing input DTB: $INPUT_DTB"

[ "$(fdtget -t x "$INPUT_DTB" /reserved-memory/memory@85e40000 reg)" = "0 85e40000 0 c0000" ] ||
	die "input DTB does not contain the r21 XBL/AOP reservation"
[ "$(fdtget -t x "$INPUT_DTB" /reserved-memory/memory@86200000 reg)" = "0 86200000 0 3900000" ] ||
	die "unexpected mainline removed-memory prefix"
[ "$(fdtget -t x "$INPUT_DTB" /reserved-memory/hotdog-removed-gap@89d00000 reg)" = "0 89d00000 0 1a00000" ] ||
	die "unexpected mainline removed-memory suffix"
[ "$(fdtget -t x "$INPUT_DTB" /reserved-memory/memory@98715000 reg)" = "0 99515000 0 2000" ] ||
	die "unexpected mainline IPA/GPU reservation boundary"
[ "$(fdtget -t x "$INPUT_DTB" /reserved-memory/memory@98800000 reg)" = "0 99600000 0 100000" ] ||
	die "unexpected mainline SPSS reservation boundary"
for node in "$REMOVED_NODE" "$CDSP_NODE"; do
	if fdtget "$INPUT_DTB" "$node" reg >/dev/null 2>&1; then
		die "input DTB already contains $node"
	fi
done

stock_removed="not-checked"
stock_cdsp="not-checked"
if [ -n "$STOCK_DTB" ]; then
	[ -s "$STOCK_DTB" ] || die "missing stock evidence DTB: $STOCK_DTB"
	stock_removed="$(fdtget -t x "$STOCK_DTB" /reserved-memory/removed_regions reg)"
	stock_cdsp="$(fdtget -t x "$STOCK_DTB" /reserved-memory/cdsp_regions reg)"
	[ "$stock_removed" = "0 86200000 0 5500000" ] ||
		die "unexpected stock removed_regions reservation: $stock_removed"
	[ "$stock_cdsp" = "0 98900000 0 1400000" ] ||
		die "unexpected stock cdsp_regions reservation: $stock_cdsp"
fi

mkdir -p "$OUTDIR"
cp "$INPUT_DTB" "$OUTPUT_DTB"
fdtput -cp "$OUTPUT_DTB" "$REMOVED_NODE"
fdtput -t x "$OUTPUT_DTB" "$REMOVED_NODE" reg 0 0x89b00000 0 0x200000
fdtput "$OUTPUT_DTB" "$REMOVED_NODE" no-map
fdtput -cp "$OUTPUT_DTB" "$CDSP_NODE"
fdtput -t x "$OUTPUT_DTB" "$CDSP_NODE" reg 0 0x99517000 0 0xe9000
fdtput "$OUTPUT_DTB" "$CDSP_NODE" no-map

[ "$(fdtget -t x "$OUTPUT_DTB" "$REMOVED_NODE" reg)" = "0 89b00000 0 200000" ] ||
	die "output DTB has the wrong removed_regions gap"
[ "$(fdtget -t x "$OUTPUT_DTB" "$CDSP_NODE" reg)" = "0 99517000 0 e9000" ] ||
	die "output DTB has the wrong CDSP gap"
for node in "$REMOVED_NODE" "$CDSP_NODE"; do
	fdtget -p "$OUTPUT_DTB" "$node" | rg -x 'no-map' >/dev/null ||
		die "output DTB reservation $node is missing no-map"
done

dtc -I dtb -O dts -o "$OUTDIR/verify.dts" "$OUTPUT_DTB" 2> "$OUTDIR/dtc-warnings.txt"
{
	printf 'existing_xbl_aop_gap=%s\n' "$(fdtget -t x "$OUTPUT_DTB" /reserved-memory/memory@85e40000 reg)"
	printf 'added_removed_regions_gap=%s\n' "$(fdtget -t x "$OUTPUT_DTB" "$REMOVED_NODE" reg)"
	printf 'added_cdsp_regions_gap=%s\n' "$(fdtget -t x "$OUTPUT_DTB" "$CDSP_NODE" reg)"
	printf 'stock_removed_regions=%s\n' "$stock_removed"
	printf 'stock_cdsp_regions=%s\n' "$stock_cdsp"
} > "$OUTDIR/ranges.txt"
sha256sum "$INPUT_DTB" "$OUTPUT_DTB" > "$OUTDIR/SHA256SUMS"
if [ -n "$STOCK_DTB" ]; then
	sha256sum "$STOCK_DTB" >> "$OUTDIR/SHA256SUMS"
fi

printf 'Output DTB: %s\n' "$OUTPUT_DTB"
cat "$OUTDIR/ranges.txt"
cat "$OUTDIR/SHA256SUMS"
