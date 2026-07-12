#!/bin/sh
set -eu

expected_input="44052506301f7fcad9725c77a98323ec283adf1159b7bee941e7ed2ac3447b49"
expected_output="cf63ae7f686bc76b912520f54e14c589b4c23c833069e45ba9097157a0665440"

if [ "$#" -ne 1 ] || [ ! -s "$1" ]; then
	printf 'Usage: %s DTB\n' "$0" >&2
	exit 2
fi

for tool in awk cp fdtput mv rm sha256sum; do
	command -v "$tool" >/dev/null 2>&1 || {
		printf 'Missing command: %s\n' "$tool" >&2
		exit 127
	}
done

dtb="$1"
input_sha="$(sha256sum "$dtb" | awk '{ print $1 }')"
if [ "$input_sha" != "$expected_input" ]; then
	printf 'K1 base DTB hash mismatch\n' >&2
	printf '  expected: %s\n' "$expected_input" >&2
	printf '  actual:   %s\n' "$input_sha" >&2
	exit 3
fi

tmp="${dtb}.k1-transform.$$"
trap 'rm -f "$tmp"' 0 HUP INT TERM
cp "$dtb" "$tmp"

fdtput -t x "$tmp" /memory reg 0 0x80000000 0 0x3bb00000
fdtput -cp "$tmp" /reserved-memory/hotdog-removed-gap@89d00000
fdtput -t x "$tmp" /reserved-memory/hotdog-removed-gap@89d00000 reg \
	0 0x89d00000 0 0x1a00000
fdtput "$tmp" /reserved-memory/hotdog-removed-gap@89d00000 no-map
fdtput -d "$tmp" /soc@0/ufshc@1d84000 iommus
fdtput -d "$tmp" /soc@0/geniqup@ac0000 iommus
fdtput -d "$tmp" /soc@0/ufshc@1d84000 qcom,ice
fdtput -d "$tmp" /soc@0/usb@a6f8800/usb@a600000 iommus

output_sha="$(sha256sum "$tmp" | awk '{ print $1 }')"
if [ "$output_sha" != "$expected_output" ]; then
	printf 'K1 transformed DTB hash mismatch\n' >&2
	printf '  expected: %s\n' "$expected_output" >&2
	printf '  actual:   %s\n' "$output_sha" >&2
	exit 3
fi

mv "$tmp" "$dtb"
