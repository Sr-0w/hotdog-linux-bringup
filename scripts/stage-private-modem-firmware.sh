#!/bin/sh

set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
package_rel=device/testing/firmware-oneplus-hotdog-modem-oos10
package_dir="$root/aports/$package_rel"
destination="$package_dir/modem-oos10.0.13.mbn"
pmaports_root=${HOTDOG_PMAPORTS_SM8150:-$root/src/postmarketos/pmaports-sm8150}
expected_source_sha=7920f87d8544d17efbe93ec9d7365190a43016eb9d286b1361de5fc96ca6a7b9
expected_output_sha=559a517c2d4ca5c22d25e0a9b3383bbf7591a632f688b629a19c3e51e3dba9e5
expected_output_size=75953080
expected_build=MPSS.HE.1.0.c11.1-00007-SM8150_GEN_PACK-2.320290.2.328393.1
source_file=${1:-${HOTDOG_MODEM_OOS10_SOURCE:-}}
pil_squasher=${PIL_SQUASHER:-pil-squasher}

if [ -z "$source_file" ]; then
	printf 'Usage: %s /private/path/to/OOS10-NON-HLOS.bin\n' "$0" >&2
	exit 2
fi

for command_name in 7z awk grep install mktemp rm sha256sum stat; do
	command -v "$command_name" >/dev/null 2>&1 || {
		printf 'Missing command: %s\n' "$command_name" >&2
		exit 2
	}
done
command -v "$pil_squasher" >/dev/null 2>&1 || [ -x "$pil_squasher" ] || {
	printf 'Missing pil-squasher: %s\n' "$pil_squasher" >&2
	exit 2
}
[ -f "$source_file" ] || {
	printf 'Missing source file: %s\n' "$source_file" >&2
	exit 2
}

actual_source_sha=$(sha256sum "$source_file" | awk '{ print $1 }')
[ "$actual_source_sha" = "$expected_source_sha" ] || {
	printf 'Source SHA256 mismatch: expected %s, got %s\n' \
		"$expected_source_sha" "$actual_source_sha" >&2
	exit 3
}

work=$(mktemp -d "${TMPDIR:-/tmp}/hotdog-oos10-modem.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM

# The FAT image has trailing geometry that makes 7z return a warning after it
# has extracted valid files. Validate every required output instead of trusting
# that final status.
7z x -y -o"$work" "$source_file" 'image/modem.*' 'verinfo/ver_info.txt' \
	>"$work/7z.log" 2>&1 || true
[ -s "$work/image/modem.mdt" ] || {
	printf 'OOS10 modem.mdt was not extracted\n' >&2
	exit 4
}
[ -s "$work/verinfo/ver_info.txt" ] || {
	printf 'OOS10 ver_info.txt was not extracted\n' >&2
	exit 4
}
grep -Fq "\"modem\": \"$expected_build\"" "$work/verinfo/ver_info.txt" || {
	printf 'Unexpected modem build in ver_info.txt\n' >&2
	exit 4
}

(
	cd "$work/image"
	"$pil_squasher" "$work/modem.mbn" modem.mdt
)

actual_size=$(stat -c %s "$work/modem.mbn")
actual_output_sha=$(sha256sum "$work/modem.mbn" | awk '{ print $1 }')
[ "$actual_size" -eq "$expected_output_size" ] || {
	printf 'Output size mismatch: expected %s, got %s\n' \
		"$expected_output_size" "$actual_size" >&2
	exit 5
}
[ "$actual_output_sha" = "$expected_output_sha" ] || {
	printf 'Output SHA256 mismatch: expected %s, got %s\n' \
		"$expected_output_sha" "$actual_output_sha" >&2
	exit 5
}

install -Dm644 "$work/modem.mbn" "$destination"
printf 'Staged %s\n' "$destination"
printf 'Source SHA256 %s\n' "$actual_source_sha"
printf 'Output SHA256 %s\n' "$actual_output_sha"

if [ -d "$pmaports_root/device/testing" ]; then
	canonical_dir="$pmaports_root/$package_rel"
	install -Dm644 "$package_dir/APKBUILD" "$canonical_dir/APKBUILD"
	install -Dm644 "$package_dir/README.md" "$canonical_dir/README.md"
	install -Dm644 "$destination" "$canonical_dir/modem-oos10.0.13.mbn"
	printf 'Staged local pmaports package %s\n' "$canonical_dir"
fi
