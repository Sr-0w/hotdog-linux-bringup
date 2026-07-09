#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/env.sh"

exec "$HOTDOG_BIN_ROOT/pmbootstrap" \
  -c "$HOTDOG_PMBOOTSTRAP_CONFIG" \
  -p "$HOTDOG_PMAPORTS_SM8150" \
  -w "$HOTDOG_PMBOOTSTRAP_WORK" \
  "$@"
