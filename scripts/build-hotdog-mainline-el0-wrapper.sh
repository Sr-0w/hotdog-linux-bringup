#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/env.sh"

SOURCE="$HOTDOG_ROOT/helpers/hotdog-mainline-el0-wrapper.S"
OUTDIR=""

usage() {
	cat <<'USAGE'
Usage: build-hotdog-mainline-el0-wrapper.sh [options]

Build the static AArch64 initramfs wrapper used to prove the first EL0
instructions without relying on BusyBox, libc, or a dynamic linker.

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
	OUTDIR="$HOTDOG_ROOT/build/experiments/$(date +%Y-%m-%d-%H%M%S)-mainline-el0-wrapper"
fi

for command in clang ld.lld file llvm-readelf sha256sum; do
	command -v "$command" >/dev/null 2>&1 || {
		printf 'Missing required command: %s\n' "$command" >&2
		exit 1
	}
done

[ -r "$SOURCE" ] || {
	printf 'Missing wrapper source: %s\n' "$SOURCE" >&2
	exit 1
}

mkdir -p "$OUTDIR"
object="$OUTDIR/hotdog-mainline-el0-wrapper.o"
output="$OUTDIR/hotdog-mainline-el0-wrapper"

clang --target=aarch64-linux-gnu -c -nostdlib "$SOURCE" -o "$object"
ld.lld -static -nostdlib -e _start --build-id=none \
	-z max-page-size=4096 "$object" -o "$output"
chmod 0755 "$output"

file "$output" | tee "$OUTDIR/file.txt"
llvm-readelf -h -l -S "$output" > "$OUTDIR/readelf.txt"
grep -q 'Machine:.*AArch64' "$OUTDIR/readelf.txt"
grep -q 'Type:.*EXEC' "$OUTDIR/readelf.txt"
if grep -q 'INTERP' "$OUTDIR/readelf.txt"; then
	printf 'Unexpected dynamic interpreter in static wrapper\n' >&2
	exit 1
fi
grep -a -q 'HOTDOG_EL0_STATIC_WRAPPER' "$output"
sha256sum "$SOURCE" "$object" "$output" > "$OUTDIR/SHA256SUMS"

printf 'Static EL0 wrapper: %s\n' "$output"
cat "$OUTDIR/SHA256SUMS"
