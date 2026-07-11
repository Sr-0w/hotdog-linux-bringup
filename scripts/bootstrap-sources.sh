#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/env.sh"

include_kernel_mainline=0
include_linux_next=0
include_sm8150_k1=0

usage() {
  cat <<'USAGE'
Usage: bootstrap-sources.sh [--kernel-mainline] [--linux-next] [--sm8150-k1]

Clones or updates the useful source trees. Mainline kernel trees are optional
because they are much larger than the Android/postmarketOS references.

  --sm8150-k1       Fetch the pinned Qualcomm SM8150 kernel repository used to
                    reproduce the K1 kernel and hotdog DTB.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --kernel-mainline) include_kernel_mainline=1 ;;
    --linux-next) include_linux_next=1 ;;
    --sm8150-k1) include_sm8150_k1=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

clone_or_update() {
  local url="$1"
  local dest="$2"
  local extra="${3:-}"

  if [ -d "$dest/.git" ]; then
    echo "== update $dest"
    git -C "$dest" fetch --all --prune
  else
    echo "== clone $url -> $dest"
    mkdir -p "$(dirname "$dest")"
    # shellcheck disable=SC2086
    git clone $extra "$url" "$dest"
  fi
}

clone_or_update https://gitlab.postmarketos.org/postmarketOS/pmbootstrap.git \
  "$HOTDOG_SRC_ROOT/postmarketos/pmbootstrap" "--filter=blob:none"

clone_or_update https://gitlab.postmarketos.org/postmarketOS/pmaports.git \
  "$HOTDOG_SRC_ROOT/postmarketos/pmaports" "--filter=blob:none"

clone_or_update https://github.com/sm8150-linux-mainline/pmaports.git \
  "$HOTDOG_SRC_ROOT/postmarketos/pmaports-sm8150" "--filter=blob:none"

clone_or_update https://github.com/OnePlusOSS/android_kernel_oneplus_sm8150.git \
  "$HOTDOG_SRC_ROOT/android/android_kernel_oneplus_sm8150" "--filter=blob:none"

clone_or_update https://github.com/LineageOS/android_device_oneplus_hotdog.git \
  "$HOTDOG_SRC_ROOT/lineage/android_device_oneplus_hotdog" "--filter=blob:none"

clone_or_update https://github.com/LineageOS/android_kernel_oneplus_sm8150.git \
  "$HOTDOG_SRC_ROOT/lineage/android_kernel_oneplus_sm8150" "--filter=blob:none"

if [ "$include_kernel_mainline" -eq 1 ]; then
  clone_or_update https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git \
    "$HOTDOG_SRC_ROOT/kernel/linux-mainline" "--filter=blob:none"
fi

if [ "$include_linux_next" -eq 1 ]; then
  clone_or_update https://git.kernel.org/pub/scm/linux/kernel/git/next/linux-next.git \
    "$HOTDOG_SRC_ROOT/kernel/linux-next" "--filter=blob:none"
fi

if [ "$include_sm8150_k1" -eq 1 ]; then
  clone_or_update https://gitlab.postmarketos.org/soc/qualcomm-sm8150/linux.git \
    "$HOTDOG_SRC_ROOT/kernel/linux-postmarketos-qcom-sm8150-k1" "--filter=blob:none"
fi

mkdir -p "$HOTDOG_BIN_ROOT"
pmbootstrap_py="$HOTDOG_SRC_ROOT/postmarketos/pmbootstrap/pmbootstrap.py"
if [ -f "$pmbootstrap_py" ]; then
  ln -sfn "$pmbootstrap_py" "$HOTDOG_BIN_ROOT/pmbootstrap"
  chmod +x "$pmbootstrap_py"
  echo "pmbootstrap wrapper: $HOTDOG_BIN_ROOT/pmbootstrap"
else
  echo "pmbootstrap.py not found yet: $pmbootstrap_py" >&2
fi

echo "Done."
