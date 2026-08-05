#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/env.sh"

INPUT_DTB=""
STOCK_DTB=""
OUTDIR=""

usage() {
	cat <<'USAGE'
Usage: build-mainline-xbl-aop-gap-dtb.sh --input-dtb FILE [options]

Reserve the 0x85e40000-0x85f00000 portion of the HD1913 stock XBL/AOP
region that is absent from the generic SM8150 device tree. This builder is
offline-only and never communicates with the phone.

Options:
  --input-dtb FILE  Mainline hotdog DTB to patch.
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
OUTDIR="${OUTDIR:-$HOTDOG_ROOT/build/experiments/$(date +%F-%H%M%S)-mainline616-xbl-aop-gap-dtb}"
OUTPUT_DTB="$OUTDIR/sm8150-oneplus-hotdog-xbl-aop-reserved.dtb"
GAP_NODE="/reserved-memory/memory@85e40000"

for command_name in cp dtc fdtget fdtput rg sha256sum; do
	command -v "$command_name" >/dev/null 2>&1 || die "missing command: $command_name"
done
[ -s "$INPUT_DTB" ] || die "missing input DTB: $INPUT_DTB"

[ "$(fdtget -t x "$INPUT_DTB" /reserved-memory/memory@85d00000 reg)" = "0 85d00000 0 140000" ] ||
	die "unexpected mainline XBL reservation"
[ "$(fdtget -t x "$INPUT_DTB" /reserved-memory/memory@85f00000 reg)" = "0 85f00000 0 20000" ] ||
	die "unexpected mainline AOP reservation"
[ "$(fdtget -t x "$INPUT_DTB" /reserved-memory/memory@85f20000 reg)" = "0 85f20000 0 20000" ] ||
	die "unexpected mainline cmd-db reservation"
if fdtget "$INPUT_DTB" "$GAP_NODE" reg >/dev/null 2>&1; then
	die "input DTB already reserves the XBL/AOP gap"
fi

stock_xbl_aop="not-checked"
if [ -n "$STOCK_DTB" ]; then
	[ -s "$STOCK_DTB" ] || die "missing stock evidence DTB: $STOCK_DTB"
	stock_xbl_aop="$(fdtget -t x "$STOCK_DTB" /reserved-memory/xbl_aop_mem reg)"
	[ "$stock_xbl_aop" = "0 85e00000 0 140000" ] ||
		die "unexpected stock XBL/AOP reservation: $stock_xbl_aop"
fi

mkdir -p "$OUTDIR"
cp "$INPUT_DTB" "$OUTPUT_DTB"
fdtput -cp "$OUTPUT_DTB" "$GAP_NODE"
fdtput -t x "$OUTPUT_DTB" "$GAP_NODE" reg 0 0x85e40000 0 0xc0000
fdtput "$OUTPUT_DTB" "$GAP_NODE" no-map

[ "$(fdtget -t x "$OUTPUT_DTB" "$GAP_NODE" reg)" = "0 85e40000 0 c0000" ] ||
	die "output DTB has the wrong gap reservation"
fdtget -p "$OUTPUT_DTB" "$GAP_NODE" | rg -x 'no-map' >/dev/null ||
	die "output DTB gap reservation is missing no-map"

dtc -I dtb -O dts -o "$OUTDIR/verify.dts" "$OUTPUT_DTB" 2> "$OUTDIR/dtc-warnings.txt"
{
	printf 'input_xbl=%s\n' "$(fdtget -t x "$INPUT_DTB" /reserved-memory/memory@85d00000 reg)"
	printf 'input_aop=%s\n' "$(fdtget -t x "$INPUT_DTB" /reserved-memory/memory@85f00000 reg)"
	printf 'input_cmd_db=%s\n' "$(fdtget -t x "$INPUT_DTB" /reserved-memory/memory@85f20000 reg)"
	printf 'added_xbl_aop_gap=%s\n' "$(fdtget -t x "$OUTPUT_DTB" "$GAP_NODE" reg)"
	printf 'stock_xbl_aop=%s\n' "$stock_xbl_aop"
} > "$OUTDIR/ranges.txt"
sha256sum "$INPUT_DTB" "$OUTPUT_DTB" > "$OUTDIR/SHA256SUMS"
if [ -n "$STOCK_DTB" ]; then
	sha256sum "$STOCK_DTB" >> "$OUTDIR/SHA256SUMS"
fi

printf 'Output DTB: %s\n' "$OUTPUT_DTB"
cat "$OUTDIR/ranges.txt"
cat "$OUTDIR/SHA256SUMS"
