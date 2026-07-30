#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source "$(dirname "$0")/env.sh"

SOURCE="$HOTDOG_ROOT/helpers/hotdog-bounded-exec.c"
OUTDIR="${1:-$HOTDOG_ROOT/build/tools/hotdog-bounded-exec}"
OUTPUT="$OUTDIR/hotdog-bounded-exec"
RUNTIME_LOG="$OUTDIR/runtime-test.log"

expect_status() {
	local expected="$1"
	local status=0

	shift
	set +e
	qemu-aarch64 "$OUTPUT" "$@" > "$RUNTIME_LOG" 2>&1
	status=$?
	set -e
	if [ "$status" -ne "$expected" ]; then
		cat "$RUNTIME_LOG" >&2
		printf 'Expected status %s, got %s for: %s\n' \
			"$expected" "$status" "$*" >&2
		exit 1
	fi
}

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
	printf 'Bounded exec helper is not statically linked: %s\n' "$OUTPUT" >&2
	exit 1
}
grep -a -q 'HOTDOG_BOUNDED_EXEC_V1' "$OUTPUT" || {
	printf 'Bounded exec identity marker is missing: %s\n' "$OUTPUT" >&2
	exit 1
}
qemu-aarch64 "$OUTPUT" --self-test |
	grep -qx 'HOTDOG_BOUNDED_EXEC_V1 SELF_TEST_OK'
expect_status 0 --timeout 2 -- /bin/true
expect_status 37 --timeout 2 -- /bin/sh -c 'exit 37'
expect_status 124 --timeout 1 -- /bin/sleep 30
grep -qx \
	'HOTDOG_BOUNDED_EXEC_V1 TIMEOUT command=/bin/sleep seconds=1' \
	"$RUNTIME_LOG"

file "$OUTPUT"
sha256sum "$SOURCE" "$OUTPUT" | tee "$OUTDIR/SHA256SUMS"
printf 'Output: %s\n' "$OUTPUT"
