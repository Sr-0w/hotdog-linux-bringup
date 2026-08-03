#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source "$(dirname "$0")/env.sh"

repo_url=https://github.com/ClearStaff/linux-sm8150-mainline-hotdog.git
commit=403b56c33e2ccdda25d90378970a5e5b928dee19
target="$HOTDOG_SRC_ROOT/kernel/linux-clearstaff-hotdog"
patch_dir="$HOTDOG_ROOT/patches/clearstaff"
source_manifest="$HOTDOG_ROOT/configs/clearstaff-hotdog-v30-source.sha256"
verify_only=0
preflight_index=

usage() {
	cat <<'USAGE'
Usage: prepare-clearstaff616-source.sh [--target DIR] [--verify-only]

Clone the pinned ClearStaff hotdog kernel and apply the checked-in direct-entry
and native-display patch series. Existing changes are never overwritten.

Options:
  --target DIR    Source checkout path.
  --verify-only   Verify an already prepared checkout without modifying it.
  -h, --help      Show this help.
USAGE
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--target) target="$2"; shift ;;
		--verify-only) verify_only=1 ;;
		-h|--help) usage; exit 0 ;;
		*) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
	esac
	shift
done

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

cleanup() {
	[ -z "$preflight_index" ] || rm -f -- "$preflight_index"
}

trap cleanup EXIT

verify_source() {
	git -C "$target" rev-parse --git-dir >/dev/null 2>&1 ||
		die "not a Git checkout: $target"
	[ "$(git -C "$target" rev-parse HEAD)" = "$commit" ] ||
		die "unexpected ClearStaff base commit in $target"
	(
		cd "$target"
		sha256sum -c "$source_manifest"
		git diff --check
	)
}

for command in git mktemp sha256sum; do
	command -v "$command" >/dev/null 2>&1 || die "missing command: $command"
done
[ -r "$source_manifest" ] || die "missing source manifest: $source_manifest"
mapfile -t patches < <(find "$patch_dir" -maxdepth 1 -type f -name '*.patch' | sort)
[ "${#patches[@]}" -gt 0 ] || die "no ClearStaff patches found in $patch_dir"

if [ "$verify_only" -eq 1 ]; then
	verify_source
	printf 'Verified ClearStaff V30 source: %s\n' "$target"
	exit 0
fi

if [ ! -e "$target" ]; then
	mkdir -p "$(dirname "$target")"
	git clone --filter=blob:none "$repo_url" "$target"
fi
git -C "$target" rev-parse --git-dir >/dev/null 2>&1 ||
	die "target exists but is not a Git checkout: $target"
[ -z "$(git -C "$target" status --porcelain)" ] ||
	die "refusing to overwrite changes in $target"

git -C "$target" fetch origin "$commit"
git -C "$target" checkout --detach "$commit"

# Validate the dependent series against an isolated index before changing the
# clean checkout. This catches a late conflict without requiring a destructive
# rollback of partially applied patches.
preflight_index="$(mktemp "${TMPDIR:-/tmp}/hotdog-clearstaff-index.XXXXXX")"
rm -f -- "$preflight_index"
GIT_INDEX_FILE="$preflight_index" git -C "$target" read-tree HEAD
for patch in "${patches[@]}"; do
	patch_name="$(basename "$patch")"
	apply_flags=()
	case "$patch_name" in
		0012-*) apply_flags+=(--ignore-space-change) ;;
	esac
	GIT_INDEX_FILE="$preflight_index" git -C "$target" apply \
		--cached "${apply_flags[@]}" --check "$patch"
	GIT_INDEX_FILE="$preflight_index" git -C "$target" apply \
		--cached "${apply_flags[@]}" "$patch"
done
rm -f -- "$preflight_index"
preflight_index=

for patch in "${patches[@]}"; do
	patch_name="$(basename "$patch")"
	apply_flags=()
	case "$patch_name" in
		0012-*) apply_flags+=(--ignore-space-change) ;;
	esac
	printf 'Applying %s\n' "$patch_name"
	git -C "$target" apply "${apply_flags[@]}" "$patch"
done
verify_source

printf 'Prepared ClearStaff V30 source: %s\n' "$target"
printf 'Base commit: %s\n' "$commit"
printf 'Applied patches: %s\n' "${#patches[@]}"
