#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
	cat <<'EOF'
Usage: compare-hotdog-edl-states.sh CAPTURE_A CAPTURE_B [BYTE_DIFFERENCES]

Verify both capture manifests, compare SHA256 by partition path, then print the
first BYTE_DIFFERENCES byte-level changes only for files whose hashes changed.
Default: 64 byte differences per changed file.
EOF
}

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

[ "$#" -ge 2 ] && [ "$#" -le 3 ] || { usage >&2; exit 2; }
capture_a="$(realpath "$1")"
capture_b="$(realpath "$2")"
byte_differences="${3:-64}"
[[ "$byte_differences" =~ ^[0-9]+$ ]] || die "BYTE_DIFFERENCES must be numeric"

for capture in "$capture_a" "$capture_b"; do
	[ -s "$capture/SHA256SUMS" ] || die "missing SHA256SUMS: $capture"
	( cd "$capture" && sha256sum -c SHA256SUMS >/dev/null ) || die "capture verification failed: $capture"
done

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
awk '{ print $2, $1 }' "$capture_a/SHA256SUMS" | sort > "$tmp_dir/a"
awk '{ print $2, $1 }' "$capture_b/SHA256SUMS" | sort > "$tmp_dir/b"
join -a1 -a2 -e MISSING -o 0,1.2,2.2 "$tmp_dir/a" "$tmp_dir/b" > "$tmp_dir/joined"

printf 'capture_a=%s\n' "$capture_a"
printf 'capture_b=%s\n' "$capture_b"
printf '\nSHA256 changes\n'
awk '$2 != $3 { print $1, $2, $3 }' "$tmp_dir/joined" | tee "$tmp_dir/changed"

printf '\nByte-level changes (changed files only, first %s differences)\n' "$byte_differences"
while read -r path hash_a hash_b; do
	file_a="$capture_a/$path"
	file_b="$capture_b/$path"
	printf '\n[%s]\n' "$path"
	if [ "$hash_a" = MISSING ] || [ "$hash_b" = MISSING ]; then
		printf 'file missing from one capture\n'
		continue
	fi
	printf 'size_a=%s size_b=%s\n' "$(stat -c '%s' "$file_a")" "$(stat -c '%s' "$file_b")"
	cmp -l "$file_a" "$file_b" | head -n "$byte_differences" || true
done < "$tmp_dir/changed"

