#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/env.sh"

needle="qcom/sm8150-oneplus-hotdog.dtb"
pkgdir="$HOTDOG_PMBOOTSTRAP_WORK/packages/edge/aarch64"
kernel_apk="$(find "$pkgdir" -maxdepth 1 -type f -name 'linux-postmarketos-sm8150-staging-*.apk' \
  | sort -V \
  | tail -n 1)"

echo "== Kernel APK DTB status =="
if [ ! -f "$kernel_apk" ]; then
  echo "missing kernel apk: $kernel_apk"
  exit 1
fi

if tar --warning=no-unknown-keyword -tf "$kernel_apk" \
  | awk -v target="boot/dtbs/$needle" '$0 == target { found=1 } END { exit found ? 0 : 1 }'; then
  echo "OK: $needle is present in $kernel_apk"
  exit 0
fi

echo "MISSING: $needle"
echo
echo "Available SM8150 DTBs:"
tar --warning=no-unknown-keyword -tf "$kernel_apk" \
  | grep 'boot/dtbs/qcom/sm8150.*\.dtb$' \
  | sed 's#^boot/dtbs/##' \
  | sort

echo
echo "Source tree hits for hotdog:"
grep -R "oneplus,hotdog\|sm8150-oneplus-hotdog\|hotdog" \
  "$HOTDOG_SRC_ROOT/kernel/linux-sm8150-6.8.7/arch/arm64/boot/dts/qcom" \
  "$HOTDOG_SRC_ROOT/kernel/linux-sm8150-mainline/arch/arm64/boot/dts/qcom" \
  "$HOTDOG_SRC_ROOT/kernel/linux-mainline/arch/arm64/boot/dts/qcom" \
  "$HOTDOG_SRC_ROOT/kernel/linux-next/arch/arm64/boot/dts/qcom" \
  2>/dev/null || true

exit 1
