#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source "$(dirname "$0")/env.sh"

SOURCE="$HOTDOG_ROOT/helpers/hotdog-rescue-supervisor.c"
OUTDIR="${1:-$HOTDOG_ROOT/build/tools/hotdog-rescue-supervisor}"
OUTPUT="$OUTDIR/hotdog-rescue-supervisor"

for command_name in file qemu-aarch64 sha256sum zig; do
	command -v "$command_name" >/dev/null 2>&1 || {
		printf 'Missing command: %s\n' "$command_name" >&2
		exit 127
	}
done
[ -s "$SOURCE" ] || {
	printf 'Missing source: %s\n' "$SOURCE" >&2
	exit 2
}

mkdir -p "$OUTDIR"
zig cc -target aarch64-linux-musl -static -Os -s \
	-Wall -Wextra -Werror \
	-o "$OUTPUT" "$SOURCE"

file "$OUTPUT" |
	grep -q 'ELF 64-bit LSB executable, ARM aarch64' || {
	printf 'Unexpected output architecture: %s\n' "$OUTPUT" >&2
	exit 1
}
file "$OUTPUT" | grep -q 'statically linked' || {
	printf 'Supervisor is not statically linked: %s\n' "$OUTPUT" >&2
	exit 1
}
grep -a -q 'HOTDOG_RESCUE_SUPERVISOR_V1' "$OUTPUT" || {
	printf 'Supervisor identity marker is missing: %s\n' "$OUTPUT" >&2
	exit 1
}
qemu-aarch64 "$OUTPUT" --self-test |
	grep -qx 'HOTDOG_RESCUE_SUPERVISOR_V1 SELF_TEST_OK'

file "$OUTPUT"
sha256sum "$SOURCE" "$OUTPUT" | tee "$OUTDIR/SHA256SUMS"
printf 'Output: %s\n' "$OUTPUT"
