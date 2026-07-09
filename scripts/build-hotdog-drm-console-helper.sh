#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
	cat <<'USAGE'
Usage: build-hotdog-drm-console-helper.sh [options]

Build helpers/hotdog-drm-console.c as an AArch64 Alpine/pmOS binary using the
pmbootstrap aarch64 buildroot. No adb, fastboot, SSH, or phone command is used.

Options:
  --source FILE   Source C file. Default: helpers/hotdog-drm-console.c
  --output FILE   Output binary. Default: build/hotdog-drm-console-aarch64
  -h, --help      Show this help.
USAGE
}

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

note() {
	printf '[build-hotdog-drm-console-helper] %s\n' "$*"
}

require_file() {
	local path="$1"
	[ -f "$path" ] || die "missing required file: $path"
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/env.sh"

source_file="$HOTDOG_ROOT/helpers/hotdog-drm-console.c"
output_file="$HOTDOG_ROOT/build/hotdog-drm-console-aarch64"
deps="build-base,libdrm-dev,pkgconf"

while [ "$#" -gt 0 ]; do
	case "$1" in
		--source)
			[ "$#" -ge 2 ] || die "--source requires a value"
			source_file="$2"
			shift
			;;
		--output)
			[ "$#" -ge 2 ] || die "--output requires a value"
			output_file="$2"
			shift
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			usage >&2
			die "unknown argument: $1"
			;;
	esac
	shift
done

require_file "$source_file"
require_file "$HOTDOG_BIN_ROOT/pmbootstrap"
require_file "$HOTDOG_PMBOOTSTRAP_CONFIG"
[ -d "$HOTDOG_PMAPORTS_SM8150" ] || die "missing pmaports tree: $HOTDOG_PMAPORTS_SM8150"
[ -d "$HOTDOG_PMBOOTSTRAP_WORK" ] || die "missing pmbootstrap work dir: $HOTDOG_PMBOOTSTRAP_WORK"
command -v file >/dev/null 2>&1 || die "missing required command: file"
command -v sha256sum >/dev/null 2>&1 || die "missing required command: sha256sum"

pmb=(
	"$HOTDOG_BIN_ROOT/pmbootstrap"
	-c "$HOTDOG_PMBOOTSTRAP_CONFIG"
	-p "$HOTDOG_PMAPORTS_SM8150"
	-w "$HOTDOG_PMBOOTSTRAP_WORK"
	-y
)

chroot_tmp="$HOTDOG_PMBOOTSTRAP_WORK/chroot_buildroot_aarch64/tmp"
remote_src="/tmp/hotdog-drm-console.c"
remote_bin="/tmp/hotdog-drm-console-aarch64"
host_src="$chroot_tmp/hotdog-drm-console.c"
host_bin="$chroot_tmp/hotdog-drm-console-aarch64"
build_log="${output_file}.build.log"

mkdir -p "$(dirname -- "$output_file")"

note "preparing pmbootstrap aarch64 buildroot"
"${pmb[@]}" chroot --buildroot aarch64 --add "$deps" --output stdout -- true

[ -d "$chroot_tmp" ] || die "pmbootstrap buildroot tmp directory not found: $chroot_tmp"
install -m 0644 "$source_file" "$host_src"
"${pmb[@]}" chroot --buildroot aarch64 --output stdout -- rm -f "$remote_bin"

note "compiling helper in aarch64 buildroot"
if ! "${pmb[@]}" chroot --buildroot aarch64 --output stdout -- sh -c '
	set -eux
	cc -O2 -Wall -Wextra -o "$2" "$1" $(pkg-config --cflags --libs libdrm)
	chmod 0755 "$2"
	file "$2"
	sha256sum "$2"
' sh "$remote_src" "$remote_bin" > "$build_log" 2>&1; then
	sed -n '1,220p' "$build_log" >&2 || true
	die "helper build failed; see $build_log"
fi

[ -s "$host_bin" ] || die "build did not produce expected binary: $host_bin"
install -m 0755 "$host_bin" "$output_file"

file_summary="$(file "$output_file")"
case "$file_summary" in
	*"ARM aarch64"*)
		;;
	*)
		printf '%s\n' "$file_summary" >&2
		die "output is not an AArch64 binary"
		;;
esac

note "done"
printf 'Output: %s\n' "$output_file"
printf 'Build log: %s\n' "$build_log"
printf 'File: %s\n' "$file_summary"
printf 'SHA256: %s\n' "$(sha256sum "$output_file" | awk '{ print $1 }')"
