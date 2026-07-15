#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/env.sh"

SOURCE="$HOTDOG_ROOT/helpers/hotdog-apss-wdt-control.c"
OUTDIR="${1:-$HOTDOG_ROOT/build/tools/hotdog-apss-wdt-control}"
OUTPUT="$OUTDIR/hotdog-apss-wdt-control"

command -v zig >/dev/null 2>&1 || {
	printf 'Missing zig compiler\n' >&2
	exit 127
}
[ -s "$SOURCE" ] || {
	printf 'Missing source: %s\n' "$SOURCE" >&2
	exit 2
}

mkdir -p "$OUTDIR"
zig cc -target aarch64-linux-musl -static -Os -s \
	-Wall -Wextra -Werror \
	-o "$OUTPUT" "$SOURCE"

file "$OUTPUT"
sha256sum "$SOURCE" "$OUTPUT" | tee "$OUTDIR/SHA256SUMS"
printf 'Output: %s\n' "$OUTPUT"
