#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/env.sh"

base_commit=8d24be3f898eb8c717678ceb881972cc6b1c76f9
source_repo="$HOTDOG_PMAPORTS_SM8150"
output=""

usage() {
	cat <<'USAGE'
Usage: prepare-hotdog-pmaports-current.sh --output DIR [--source REPO]

Create a clean pmaports worktree at the pinned current upstream commit, apply
the Hotdog initramfs/OpenRC integration commit, and overlay the public aports
from this repository. The output path must not already exist.
USAGE
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--output) output=${2:-}; shift ;;
		--source) source_repo=${2:-}; shift ;;
		-h|--help) usage; exit 0 ;;
		*) usage >&2; exit 2 ;;
	esac
	shift
done

[ -n "$output" ] || { usage >&2; exit 2; }
git -C "$source_repo" rev-parse --git-dir >/dev/null 2>&1 || {
	echo "Not a Git repository: $source_repo" >&2
	exit 2
}
[ ! -e "$output" ] || { echo "Output already exists: $output" >&2; exit 2; }

output=$(realpath -m "$output")
patch="$HOTDOG_ROOT/patches/pmaports/0001-initramfs-provision-optional-ACM-before-UDC-bind.patch"
[ -s "$patch" ] || { echo "Missing pmaports patch: $patch" >&2; exit 2; }

git -C "$source_repo" cat-file -e "$base_commit^{commit}"
git -C "$source_repo" worktree add --detach "$output" "$base_commit"
git -C "$output" am --committer-date-is-author-date "$patch"

for section in device main temp; do
	[ -d "$HOTDOG_ROOT/aports/$section" ] || continue
	rsync -a "$HOTDOG_ROOT/aports/$section/" "$output/$section/"
done

git -C "$output" diff --check
printf 'pmaports_base=%s\n' "$base_commit"
printf 'pmaports_integration=%s\n' "$(git -C "$output" rev-parse HEAD)"
printf 'output=%s\n' "$output"
