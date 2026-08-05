#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=/dev/null
source "$(dirname "$0")/env.sh"

QDL_COMMIT="${QDL_COMMIT:-57a1ae956b1bb97465a5e37a627f75d1fd3fd679}"
QDL_SOURCE="${QDL_SOURCE:-$HOTDOG_SRC_ROOT/qualcomm/qdl-$QDL_COMMIT}"
QDL_BUILD="${QDL_BUILD:-$HOTDOG_TOOLS_ROOT/qdl-build}"
QDL_PREFIX="${QDL_PREFIX:-$HOTDOG_TOOLS_ROOT/qdl-install}"
QDL_PATCH="$HOTDOG_ROOT/patches/qdl-ramdump-skip-reset.patch"

for command_name in git meson ninja; do
	command -v "$command_name" >/dev/null 2>&1 || {
		printf 'Missing command: %s\n' "$command_name" >&2
		exit 127
	}
done

if [ ! -d "$QDL_SOURCE/.git" ]; then
	mkdir -p "$(dirname "$QDL_SOURCE")"
	git clone https://github.com/linux-msm/qdl.git "$QDL_SOURCE"
	git -C "$QDL_SOURCE" switch --detach "$QDL_COMMIT"
fi

actual_commit="$(git -C "$QDL_SOURCE" rev-parse HEAD)"
if [ "$actual_commit" != "$QDL_COMMIT" ]; then
	printf 'QDL source is at %s, expected %s: %s\n' \
		"$actual_commit" "$QDL_COMMIT" "$QDL_SOURCE" >&2
	exit 2
fi

if git -C "$QDL_SOURCE" apply --check "$QDL_PATCH"; then
	git -C "$QDL_SOURCE" apply "$QDL_PATCH"
elif ! git -C "$QDL_SOURCE" apply --reverse --check "$QDL_PATCH"; then
	printf 'QDL source does not match the pinned patch state: %s\n' "$QDL_SOURCE" >&2
	exit 3
fi

meson setup "$QDL_BUILD" "$QDL_SOURCE" \
	--prefix "$QDL_PREFIX" --buildtype debugoptimized --wipe
ninja -C "$QDL_BUILD"
meson test -C "$QDL_BUILD" --print-errorlogs
ninja -C "$QDL_BUILD" install

mkdir -p "$HOTDOG_BIN_ROOT"
ln -sfn "$QDL_PREFIX/bin/qdl" "$HOTDOG_BIN_ROOT/qdl"

"$HOTDOG_BIN_ROOT/qdl" ramdump --help | grep -q -- '--skip-reset'
printf 'QDL ramdump tool ready: %s\n' "$HOTDOG_BIN_ROOT/qdl"
