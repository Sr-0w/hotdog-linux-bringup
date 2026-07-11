#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/env.sh"

version="2.0.32-r2"
url="https://dl-cdn.alpinelinux.org/alpine/edge/community/aarch64/kexec-tools-${version}.apk"
apk="$HOTDOG_ROOT/tools/aarch64/kexec-tools-${version}.apk"
extract_dir="$HOTDOG_ROOT/tools/aarch64/kexec-tools-${version}"
apk_sha="dadaf7c275f162fe07b6a8b131085f3295c36c13a7b68fee02fc536e0b821320"
binary_sha="0e0524a41579c38a741ce53a2d44b77743135b2ada988d10e2ec3943f54f43f5"

command -v curl >/dev/null 2>&1 || {
  echo "Missing curl" >&2
  exit 127
}
command -v sha256sum >/dev/null 2>&1 || {
  echo "Missing sha256sum" >&2
  exit 127
}
command -v tar >/dev/null 2>&1 || {
  echo "Missing tar" >&2
  exit 127
}

mkdir -p "$(dirname "$apk")"
if [ ! -s "$apk" ] || [ "$(sha256sum "$apk" | awk '{ print $1 }')" != "$apk_sha" ]; then
  curl --fail --location --retry 3 --output "$apk.tmp" "$url"
  mv "$apk.tmp" "$apk"
fi

actual_apk_sha="$(sha256sum "$apk" | awk '{ print $1 }')"
[ "$actual_apk_sha" = "$apk_sha" ] || {
  echo "APK sha256 mismatch: $actual_apk_sha" >&2
  exit 1
}

rm -rf "$extract_dir"
mkdir -p "$extract_dir"
tar -xzf "$apk" -C "$extract_dir"

binary="$extract_dir/usr/sbin/kexec"
[ -s "$binary" ] || {
  echo "Missing extracted binary: $binary" >&2
  exit 1
}
actual_binary_sha="$(sha256sum "$binary" | awk '{ print $1 }')"
[ "$actual_binary_sha" = "$binary_sha" ] || {
  echo "kexec sha256 mismatch: $actual_binary_sha" >&2
  exit 1
}

printf 'APK:    %s\n' "$apk"
printf 'sha256: %s\n' "$actual_apk_sha"
printf 'binary: %s\n' "$binary"
printf 'sha256: %s\n' "$actual_binary_sha"
file "$binary"
