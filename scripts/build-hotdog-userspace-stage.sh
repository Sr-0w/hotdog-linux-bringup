#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source "$(dirname "$0")/env.sh"

SOURCE="$HOTDOG_ROOT/helpers/hotdog-userspace-stage.S"
OUTDIR=""

usage() {
	cat <<'USAGE'
Usage: build-hotdog-userspace-stage.sh [options]

Build the static AArch64 helper used by the diagnostic kernel to display
postmarketOS initramfs progress without a framebuffer device or working USB.

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
	OUTDIR="$HOTDOG_ROOT/build/experiments/$(date +%Y-%m-%d-%H%M%S)-userspace-stage"
fi

for command in clang ld.lld file llvm-readelf sha256sum; do
	command -v "$command" >/dev/null 2>&1 || {
		printf 'Missing required command: %s\n' "$command" >&2
		exit 1
	}
done

[ -r "$SOURCE" ] || {
	printf 'Missing stage helper source: %s\n' "$SOURCE" >&2
	exit 1
}

mkdir -p "$OUTDIR"
object="$OUTDIR/hotdog-userspace-stage.o"
output="$OUTDIR/hotdog-userspace-stage"

clang --target=aarch64-linux-gnu -c -nostdlib "$SOURCE" -o "$object"
ld.lld -static -nostdlib -e _start --build-id=none \
	-z max-page-size=4096 "$object" -o "$output"
chmod 0755 "$output"

file "$output" | tee "$OUTDIR/file.txt"
llvm-readelf -h -l -S "$output" > "$OUTDIR/readelf.txt"
grep -q 'Machine:.*AArch64' "$OUTDIR/readelf.txt"
grep -q 'Type:.*EXEC' "$OUTDIR/readelf.txt"
if grep -q 'INTERP' "$OUTDIR/readelf.txt"; then
	printf 'Unexpected dynamic interpreter in stage helper\n' >&2
	exit 1
fi
grep -a -q 'HOTDOG_USERSPACE_STAGE_V1' "$output"
sha256sum "$SOURCE" "$object" "$output" > "$OUTDIR/SHA256SUMS"

printf 'Static userspace stage helper: %s\n' "$output"
cat "$OUTDIR/SHA256SUMS"
