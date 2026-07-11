#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/env.sh"

source_file="$HOTDOG_ROOT/helpers/hotdog-reboot-mode.c"
output_file="${1:-$HOTDOG_ROOT/build/hotdog-reboot-mode-aarch64}"

command -v zig >/dev/null 2>&1 || {
  echo "Missing zig compiler" >&2
  exit 127
}
[ -s "$source_file" ] || {
  echo "Missing source: $source_file" >&2
  exit 2
}

mkdir -p "$(dirname "$output_file")"
zig cc \
  -target aarch64-linux-musl \
  -static \
  -Os \
  -s \
  -Wall \
  -Wextra \
  -Werror \
  "$source_file" \
  -o "$output_file"

file "$output_file"
sha256sum "$output_file"
