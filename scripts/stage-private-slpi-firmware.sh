#!/bin/sh

set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
destination="$root/aports/device/testing/firmware-oneplus-hotdog-slpi/slpi-oos10.0.13.mbn"
expected_sha=1b17eb7bd003af9092e074645d88b92474a1cf3c2ad97356bdd3b36430c8e249
source_file=${1:-${HOTDOG_SLPI_00083_SOURCE:-}}

if [ -z "$source_file" ]; then
	printf 'Usage: %s /private/path/to/slpi-oos10.0.13.mbn\n' "$0" >&2
	exit 2
fi

[ -f "$source_file" ] || {
	printf 'Missing source file: %s\n' "$source_file" >&2
	exit 2
}

actual_sha=$(sha256sum "$source_file" | awk '{ print $1 }')
[ "$actual_sha" = "$expected_sha" ] || {
	printf 'SHA256 mismatch: expected %s, got %s\n' \
		"$expected_sha" "$actual_sha" >&2
	exit 3
}

install -Dm644 "$source_file" "$destination"
printf 'Staged %s\n' "$destination"
printf 'SHA256 %s\n' "$actual_sha"
