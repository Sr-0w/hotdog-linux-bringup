#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
	cat <<'USAGE'
Usage: publish-public-release.sh --version VERSION --assets DIR --notes FILE [--publish]

Check a prepared release directory, tag the current commit and either print the
GitHub release command (default) or publish a pre-release when --publish is
explicitly supplied. The source tree must be clean before a release tag is made.
USAGE
}

die() {
	printf '[publish-release] ERROR: %s\n' "$*" >&2
	exit 1
}

version=""
assets=""
notes=""
publish=0
while [ "$#" -gt 0 ]; do
	case "$1" in
		--version) version="${2:-}"; shift ;;
		--assets) assets="${2:-}"; shift ;;
		--notes) notes="${2:-}"; shift ;;
		--publish) publish=1 ;;
		-h|--help) usage; exit 0 ;;
		*) usage >&2; die "unknown argument: $1" ;;
	esac
	shift
done

[[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-(alpha|beta)\.[0-9]+$ ]] ||
	die "invalid release version"
[ -d "$assets" ] || die "asset directory not found: $assets"
[ -s "$assets/SHA256SUMS" ] || die "missing SHA256SUMS"
[ -s "$assets/MANIFEST.md" ] || die "missing MANIFEST.md"
[ -s "$notes" ] || die "release notes not found: $notes"
command -v gh >/dev/null 2>&1 || die "missing GitHub CLI"
if ! git diff --quiet || ! git diff --cached --quiet; then
	die "commit or stash local changes before tagging"
fi
git ls-remote --exit-code --tags origin "refs/tags/$version" >/dev/null 2>&1 &&
	die "tag already exists on origin: $version"
(cd "$assets" && sha256sum -c SHA256SUMS)

shopt -s nullglob
asset_files=("$assets"/SHA256SUMS "$assets"/MANIFEST.md "$assets"/*-boot.img \
	"$assets"/*-kernel-*.apk)
rootfs_parts=("$assets"/*-rootfs.img.zst.part*)
if [ "${#rootfs_parts[@]}" -gt 0 ]; then
	asset_files+=("${rootfs_parts[@]}")
else
	asset_files+=("$assets"/*-rootfs.img.zst)
fi
[ "${#asset_files[@]}" -ge 5 ] || die "prepared asset set is incomplete"
printf 'Prepared command:\n'
printf 'gh release create %q --repo Sr-0w/hotdog-linux-bringup --target main --title %q --notes-file %q --prerelease' \
	"$version" "$version" "$notes"
printf ' %q' "${asset_files[@]}"
printf '\n'

[ "$publish" -eq 1 ] || exit 0
git tag -a "$version" -m "Release $version"
git push origin "$version"
gh release create "$version" \
	--repo Sr-0w/hotdog-linux-bringup \
	--target main \
	--title "$version" \
	--notes-file "$notes" \
	--prerelease \
	"${asset_files[@]}"
