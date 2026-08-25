#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$root"

. ./metadata.env

sha256sum -c SHA256SUMS

series_count=$(wc -l < series)
patch_count=$(find patches -maxdepth 1 -type f -name '*.patch' | wc -l)
unapplied_count=$(find unapplied -maxdepth 1 -type f -name '*.patch' | wc -l)
[ "$series_count" -eq "$PATCH_COUNT" ] || {
	echo "series contains $series_count entries, expected $PATCH_COUNT" >&2
	exit 1
}
[ "$patch_count" -eq "$PATCH_COUNT" ] || {
	echo "patches contains $patch_count files, expected $PATCH_COUNT" >&2
	exit 1
}
[ "$unapplied_count" -eq "$UNAPPLIED_PATCH_COUNT" ] || {
	echo "unapplied contains $unapplied_count files, expected $UNAPPLIED_PATCH_COUNT" >&2
	exit 1
}
[ -f "unapplied/$UNAPPLIED_PATCH" ] || {
	echo "missing preserved unapplied patch: $UNAPPLIED_PATCH" >&2
	exit 1
}

while IFS= read -r patch_name; do
	case "$patch_name" in
		''|*/*)
			echo "invalid series entry: $patch_name" >&2
			exit 1
			;;
	esac
	[ -f "patches/$patch_name" ] || {
		echo "missing patch: $patch_name" >&2
		exit 1
	}
done < series

[ "$(wc -c < cumulative.patch)" -eq "$CUMULATIVE_PATCH_SIZE" ] || {
	echo "cumulative.patch size mismatch" >&2
	exit 1
}

echo "checkpoint $CHECKPOINT_NAME: verified ($PATCH_COUNT patches, final tree $FINAL_SOURCE_TREE)"
