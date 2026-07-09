#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
	cat <<'USAGE'
Usage: sync-aport-snapshots.sh [--apply] [options]

Compare or copy the tracked local aport snapshots from ./aports into the local
pmaports checkout. By default this script is check-only. Use --apply to copy.

Options:
  --apply              Copy snapshots into the pmaports checkout.
  --target-pmaports D  Destination pmaports checkout. Default:
                       $HOTDOG_PMAPORTS_SM8150
  -h, --help           Show this help.
USAGE
}

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

note() {
	printf '[sync-aport-snapshots] %s\n' "$*"
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/env.sh"

apply=0
target_pmaports="$HOTDOG_PMAPORTS_SM8150"
snapshot_root="$HOTDOG_ROOT/aports"

while [ "$#" -gt 0 ]; do
	case "$1" in
		--apply)
			apply=1
			;;
		--target-pmaports)
			[ "$#" -ge 2 ] || die "--target-pmaports requires a value"
			target_pmaports="$2"
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

[ -d "$snapshot_root" ] || die "missing snapshot root: $snapshot_root"
[ -d "$target_pmaports" ] || die "missing target pmaports checkout: $target_pmaports"
command -v diff >/dev/null 2>&1 || die "missing required command: diff"
command -v cp >/dev/null 2>&1 || die "missing required command: cp"

sync_dir() {
	local rel="$1"
	local src="$snapshot_root/$rel"
	local dst="$target_pmaports/$rel"
	local parent
	local backup
	local tmp

	[ -d "$src" ] || die "missing snapshot directory: $src"
	parent="$(dirname -- "$dst")"
	backup="$dst.backup-$(date +%Y%m%d-%H%M%S)"
	tmp="$dst.tmp.$$"

	if [ -d "$dst" ]; then
		if diff -qr "$src" "$dst" >/tmp/hotdog-aport-snapshot-diff.$$ 2>&1; then
			note "$rel: target already matches snapshot"
			rm -f /tmp/hotdog-aport-snapshot-diff.$$
			return 0
		fi
		note "$rel: target differs from snapshot"
		sed -n '1,80p' /tmp/hotdog-aport-snapshot-diff.$$ | sed 's/^/[diff] /'
		rm -f /tmp/hotdog-aport-snapshot-diff.$$
	elif [ -e "$dst" ]; then
		die "destination exists but is not a directory: $dst"
	else
		note "$rel: target is absent"
	fi

	if [ "$apply" -eq 0 ]; then
		note "$rel: check-only; use --apply to copy"
		return 1
	fi

	mkdir -p "$parent"
	rm -rf "$tmp"
	cp -a "$src" "$tmp"
	if [ -d "$dst" ]; then
		mv "$dst" "$backup"
		note "$rel: previous target moved to $backup"
	fi
	mv "$tmp" "$dst"
	note "$rel: snapshot copied to $dst"
}

status=0
sync_dir "device/testing/linux-oneplus-hotdog-lineage414" || status=$?
exit "$status"
