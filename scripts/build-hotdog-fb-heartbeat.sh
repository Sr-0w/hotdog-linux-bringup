#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source "$(dirname "$0")/env.sh"

SOURCE="$HOTDOG_ROOT/helpers/hotdog-fb-heartbeat.S"
OUTDIR=""

usage() {
	cat <<'USAGE'
Usage: build-hotdog-fb-heartbeat.sh [options]

Build the static AArch64 framebuffer heartbeat used to distinguish a cleared
framebuffer from loss of firmware scanout during early userspace.

Options:
  --source FILE  Assembly source.
  --outdir DIR   Output directory below build/experiments by default.
  -h, --help     Show this help.
USAGE
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--source) SOURCE="$2"; shift ;;
		--outdir) OUTDIR="$2"; shift ;;
		-h|--help) usage; exit 0 ;;
		*) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
	esac
	shift
done

if [ -z "$OUTDIR" ]; then
	OUTDIR="$HOTDOG_ROOT/build/experiments/$(date +%Y-%m-%d-%H%M%S)-fb-heartbeat"
fi

for command in clang file ld.lld llvm-readelf sha256sum; do
	command -v "$command" >/dev/null 2>&1 || {
		printf 'Missing required command: %s\n' "$command" >&2
		exit 1
	}
done

[ -r "$SOURCE" ] || {
	printf 'Missing heartbeat source: %s\n' "$SOURCE" >&2
	exit 1
}

mkdir -p "$OUTDIR"
object="$OUTDIR/hotdog-fb-heartbeat.o"
output="$OUTDIR/hotdog-fb-heartbeat"

clang --target=aarch64-linux-gnu -c -nostdlib "$SOURCE" -o "$object"
ld.lld -static -nostdlib -e _start --build-id=none \
	-z max-page-size=4096 "$object" -o "$output"
chmod 0755 "$output"

file "$output" | tee "$OUTDIR/file.txt"
llvm-readelf -h -l -S "$output" > "$OUTDIR/readelf.txt"
grep -q 'Machine:.*AArch64' "$OUTDIR/readelf.txt"
grep -q 'Type:.*EXEC' "$OUTDIR/readelf.txt"
if grep -q 'INTERP' "$OUTDIR/readelf.txt"; then
	printf 'Unexpected dynamic interpreter in static heartbeat\n' >&2
	exit 1
fi
grep -a -q 'HOTDOG_FB_HEARTBEAT_V1' "$output"
sha256sum "$SOURCE" "$object" "$output" > "$OUTDIR/SHA256SUMS"

printf 'Static framebuffer heartbeat: %s\n' "$output"
cat "$OUTDIR/SHA256SUMS"
