#!/usr/bin/env bash
set -Eeuo pipefail

STOCK_DTBO=""
K1_DTB=""
OUT=""

STOCK_SHA=95a111deb5302d0fc677c3d58f880a049461ffcaba856c75471d2789040ae672
K1_DTB_SHA=cf63ae7f686bc76b912520f54e14c589b4c23c833069e45ba9097157a0665440
OUTPUT_SHA=339e55adaf591f114d8a39a86cb0a0e664e26bc7c7b7f2227e0bee794d10c5fb
PARTITION_SIZE=25165824
ENTRY5_PADDING=319412
AVB_SALT=6bae7a0e8c3e12307c5f7d0b2638f81411f70d4a820cc47ab922876705bacf92
AVB_PROP='com.android.build.dtbo.fingerprint:OnePlus/lineage_hotdog/hotdog:15/BP1A.250505.005/2e7a70d9d2:userdebug/release-keys'

usage() {
  cat <<'USAGE'
Usage: build-d3-noop-dtbo.sh --stock-dtbo FILE --k1-dtb FILE --out DIR

Rebuild the pinned D3 partition image from the exact tested stock dtbo_b dump
and K1 DTB. The inputs and final output are accepted only at their recorded
SHA256 values. No phone command is executed.
USAGE
}

die() {
  printf 'ERROR: %s\n' "$1" >&2
  exit "${2:-1}"
}

check_sha() {
  local label="$1"
  local path="$2"
  local expected="$3"
  local actual=""

  [ -s "$path" ] || die "Missing $label: $path" 2
  actual="$(sha256sum "$path" | awk '{ print $1 }')"
  [ "$actual" = "$expected" ] ||
    die "$label SHA256 mismatch: expected $expected, got $actual" 3
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --stock-dtbo) STOCK_DTBO="$2"; shift 2 ;;
    --k1-dtb) K1_DTB="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" 2 ;;
  esac
done

[ -n "$STOCK_DTBO" ] || die "--stock-dtbo is required" 2
[ -n "$K1_DTB" ] || die "--k1-dtb is required" 2
[ -n "$OUT" ] || die "--out is required" 2
for command in mkdtboimg avbtool dtc fdtoverlay sha256sum cmp stat awk; do
  command -v "$command" >/dev/null 2>&1 || die "Missing command: $command" 127
done

check_sha "stock dtbo_b" "$STOCK_DTBO" "$STOCK_SHA"
check_sha "K1 DTB" "$K1_DTB" "$K1_DTB_SHA"

mkdir -p "$OUT/source/stock-entries" "$OUT/components" "$OUT/verify"
cat > "$OUT/source/noop-entry5.dtso" <<'DTS'
/dts-v1/;
/plugin/;

/ {
	model = "SM8150 MTP 19801 EVT PVT DVT";
	compatible = "qcom,sm8150-mtp", "qcom,sm8150", "qcom,mtp";
	qcom,board-id = <0x08 0x00>;
	oplus,dtsi_no = <0x4d59>;
	oplus,pcb_range = <0x0c 0x37>;

	fragment@0 {
		target-path = "/";

		__overlay__ {
		};
	};
};
DTS

mkdtboimg dump "$STOCK_DTBO" -o "$OUT/source/stock-table.txt" \
  -b "$OUT/source/stock-entries/entry"
dtc -@ -I dts -O dtb -p "$ENTRY5_PADDING" \
  -o "$OUT/components/noop-entry5.dtbo" "$OUT/source/noop-entry5.dtso"

mkdtboimg create "$OUT/components/dtbo_b-d3-table.img" \
  --dt_type=dtb --page_size=4096 --version=0 \
  --id=0 --rev=0 --flags=0 \
  --custom0=0 --custom1=0 --custom2=0 --custom3=0 \
  "$OUT/source/stock-entries/entry.0" \
  "$OUT/source/stock-entries/entry.1" \
  "$OUT/source/stock-entries/entry.2" \
  "$OUT/source/stock-entries/entry.3" \
  "$OUT/source/stock-entries/entry.4" \
  "$OUT/components/noop-entry5.dtbo" \
  "$OUT/source/stock-entries/entry.6" \
  "$OUT/source/stock-entries/entry.7" \
  "$OUT/source/stock-entries/entry.8" \
  "$OUT/source/stock-entries/entry.9"

cp --force "$OUT/components/dtbo_b-d3-table.img" "$OUT/dtbo_b-d3-entry5-noop.img"
avbtool add_hash_footer \
  --image "$OUT/dtbo_b-d3-entry5-noop.img" \
  --partition_name dtbo --partition_size "$PARTITION_SIZE" \
  --hash_algorithm sha256 --salt "$AVB_SALT" \
  --algorithm NONE --rollback_index 0 --rollback_index_location 0 --flags 0 \
  --prop "$AVB_PROP"

fdtoverlay -i "$K1_DTB" -o "$OUT/verify/k1-plus-noop.dtb" \
  "$OUT/components/noop-entry5.dtbo"
cmp "$K1_DTB" "$OUT/verify/k1-plus-noop.dtb"
check_sha "D3 dtbo_b" "$OUT/dtbo_b-d3-entry5-noop.img" "$OUTPUT_SHA"
[ "$(stat -c %s "$OUT/dtbo_b-d3-entry5-noop.img")" = "$PARTITION_SIZE" ] ||
  die "D3 dtbo_b has an unexpected size" 3

printf '%s  %s\n' "$OUTPUT_SHA" "dtbo_b-d3-entry5-noop.img" > "$OUT/SHA256SUMS"
printf 'D3 dtbo_b reproduced: %s\n' "$OUT/dtbo_b-d3-entry5-noop.img"
