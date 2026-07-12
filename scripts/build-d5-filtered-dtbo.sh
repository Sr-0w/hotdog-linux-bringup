#!/usr/bin/env bash
set -Eeuo pipefail

STOCK_DTBO=""
STOCK_BASE_DTB=""
K1_DTB=""
OUT=""
UFS_SYMBOL_BRIDGE=0

STOCK_DTBO_SHA=95a111deb5302d0fc677c3d58f880a049461ffcaba856c75471d2789040ae672
STOCK_BASE_DTB_SHA=44a22657c1dd751ba062060941af02758a7ae8a656e5cd4e8ac1f2a164c04ee9
K1_DTB_SHA=cf63ae7f686bc76b912520f54e14c589b4c23c833069e45ba9097157a0665440
PARTITION_SIZE=25165824
AVB_SALT=6bae7a0e8c3e12307c5f7d0b2638f81411f70d4a820cc47ab922876705bacf92
AVB_PROP='com.android.build.dtbo.fingerprint:OnePlus/lineage_hotdog/hotdog:15/BP1A.250505.005/2e7a70d9d2:userdebug/release-keys'
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"

usage() {
  cat <<'USAGE'
Usage: build-d5-filtered-dtbo.sh --stock-dtbo FILE --stock-base-dtb FILE \
  --k1-dtb FILE --out DIR [--ufs-symbol-bridge]

Build a stock-derived DTBO partition whose selected entry retains only overlay
fragments and references that resolve against the pinned K1 mainline DTB. The
filtered overlay must apply successfully to both downstream and mainline base
DTBs. With --ufs-symbol-bridge, the K1 DTB receives vendor-compatible aliases
for the UFS controller, PHY, and their regulators before filtering. No phone
command is executed.
USAGE
}

die() {
  printf 'ERROR: %s\n' "$1" >&2
  exit "${2:-1}"
}

check_sha() {
  local label="$1" path="$2" expected="$3" actual
  [ -s "$path" ] || die "Missing $label: $path" 2
  actual="$(sha256sum "$path" | awk '{ print $1 }')"
  [ "$actual" = "$expected" ] ||
    die "$label SHA256 mismatch: expected $expected, got $actual" 3
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --stock-dtbo) STOCK_DTBO="$2"; shift 2 ;;
    --stock-base-dtb) STOCK_BASE_DTB="$2"; shift 2 ;;
    --k1-dtb) K1_DTB="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --ufs-symbol-bridge) UFS_SYMBOL_BRIDGE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" 2 ;;
  esac
done

[ -n "$STOCK_DTBO" ] || die "--stock-dtbo is required" 2
[ -n "$STOCK_BASE_DTB" ] || die "--stock-base-dtb is required" 2
[ -n "$K1_DTB" ] || die "--k1-dtb is required" 2
[ -n "$OUT" ] || die "--out is required" 2
for command in mkdtboimg avbtool fdtoverlay fdtget fdtput python3 sha256sum awk stat; do
  command -v "$command" >/dev/null 2>&1 || die "Missing command: $command" 127
done

check_sha "stock dtbo_b" "$STOCK_DTBO" "$STOCK_DTBO_SHA"
check_sha "stock downstream base DTB" "$STOCK_BASE_DTB" "$STOCK_BASE_DTB_SHA"
check_sha "K1 mainline DTB" "$K1_DTB" "$K1_DTB_SHA"

mkdir -p "$OUT/source/stock-entries" "$OUT/components" "$OUT/verify"
mkdtboimg dump "$STOCK_DTBO" -o "$OUT/source/stock-table.txt" \
  -b "$OUT/source/stock-entries/entry"
cp --force "$OUT/source/stock-entries/entry.5" "$OUT/components/filtered-entry5.dtbo"

FILTER_BASE="$K1_DTB"
VARIANT="d5-filtered"
if [ "$UFS_SYMBOL_BRIDGE" -eq 1 ]; then
  FILTER_BASE="$OUT/components/k1-ufs-symbol-bridge.dtb"
  VARIANT="d6-ufs-bridge-filtered"
  cp --force "$K1_DTB" "$FILTER_BASE"
  while read -r vendor_symbol mainline_symbol; do
    target_path="$(fdtget -t s "$FILTER_BASE" /__symbols__ "$mainline_symbol")"
    [ -n "$target_path" ] || die "Missing K1 symbol target: $mainline_symbol" 3
    fdtput -t s "$FILTER_BASE" /__symbols__ "$vendor_symbol" "$target_path"
  done <<'EOF'
ufsphy_mem ufs_mem_phy
ufshc_mem ufs_mem_hc
pm8150_l5 vreg_l5a_0p875
pm8150l_l3 vreg_l3c_1p2
pm8150_l10 vreg_l10a_2p5
pm8150_l9 vreg_l9a_1p2
pm8150_s4 vreg_s4a_1p8
pm8150l_s8 vreg_s8c_1p3
EOF
fi
python3 "$SCRIPT_DIR/filter-dtbo-overlay.py" \
  --overlay "$OUT/components/filtered-entry5.dtbo" --base "$FILTER_BASE" \
  | tee "$OUT/verify/filter-summary.txt"

fdtoverlay -i "$STOCK_BASE_DTB" -o "$OUT/verify/downstream-plus-filtered.dtb" \
  "$OUT/components/filtered-entry5.dtbo"
fdtoverlay -i "$FILTER_BASE" -o "$OUT/verify/k1-plus-filtered.dtb" \
  "$OUT/components/filtered-entry5.dtbo"

mkdtboimg create "$OUT/components/dtbo_b-$VARIANT-table.img" \
  --dt_type=dtb --page_size=4096 --version=0 \
  --id=0 --rev=0 --flags=0 \
  --custom0=0 --custom1=0 --custom2=0 --custom3=0 \
  "$OUT/source/stock-entries/entry.0" \
  "$OUT/source/stock-entries/entry.1" \
  "$OUT/source/stock-entries/entry.2" \
  "$OUT/source/stock-entries/entry.3" \
  "$OUT/source/stock-entries/entry.4" \
  "$OUT/components/filtered-entry5.dtbo" \
  "$OUT/source/stock-entries/entry.6" \
  "$OUT/source/stock-entries/entry.7" \
  "$OUT/source/stock-entries/entry.8" \
  "$OUT/source/stock-entries/entry.9"

cp --force "$OUT/components/dtbo_b-$VARIANT-table.img" "$OUT/dtbo_b-$VARIANT.img"
avbtool add_hash_footer \
  --image "$OUT/dtbo_b-$VARIANT.img" \
  --partition_name dtbo --partition_size "$PARTITION_SIZE" \
  --hash_algorithm sha256 --salt "$AVB_SALT" \
  --algorithm NONE --rollback_index 0 --rollback_index_location 0 --flags 0 \
  --prop "$AVB_PROP"

[ "$(stat -c %s "$OUT/dtbo_b-$VARIANT.img")" = "$PARTITION_SIZE" ] ||
  die "Filtered dtbo_b has an unexpected size" 3
sha256sum "$OUT/dtbo_b-$VARIANT.img" > "$OUT/SHA256SUMS"
printf 'Filtered dtbo_b built: %s\n' "$OUT/dtbo_b-$VARIANT.img"
