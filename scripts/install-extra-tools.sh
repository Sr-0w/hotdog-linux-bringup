#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/env.sh"

mkdir -p "$HOTDOG_BIN_ROOT"

echo "== payload-dumper-go =="
if [ -x "$HOTDOG_BIN_ROOT/payload-dumper-go" ]; then
  "$HOTDOG_BIN_ROOT/payload-dumper-go" --help >/dev/null 2>&1 || true
  echo "Already installed: $HOTDOG_BIN_ROOT/payload-dumper-go"
elif command -v go >/dev/null 2>&1; then
  GOBIN="$HOTDOG_BIN_ROOT" go install github.com/ssut/payload-dumper-go@latest
  echo "Installed: $HOTDOG_BIN_ROOT/payload-dumper-go"
else
  echo "Go is missing; cannot install payload-dumper-go." >&2
fi

echo
echo "== pmbootstrap =="
if [ ! -d "$HOTDOG_SRC_ROOT/postmarketos/pmbootstrap/.git" ]; then
  "$HOTDOG_ROOT/scripts/bootstrap-sources.sh"
else
  "$HOTDOG_ROOT/scripts/bootstrap-sources.sh"
fi

if [ -x "$HOTDOG_BIN_ROOT/pmbootstrap" ]; then
  "$HOTDOG_BIN_ROOT/pmbootstrap" --version || true
fi

echo "Done."

