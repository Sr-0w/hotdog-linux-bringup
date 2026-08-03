#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source "$(dirname "$0")/env.sh"

source_dir="$HOTDOG_ROOT/images/pmos-experiments/2026-08-02-231500-clearstaff616-direct-entry-v14-simplefb-nomap/components"
kernel="$source_dir/kernel"
dtb="$source_dir/dtb"
ramdisk="$source_dir/ramdisk"
base_cmdline="$HOTDOG_ROOT/configs/clearstaff-hotdog-passive.cmdline"
cmdline="$HOTDOG_ROOT/configs/clearstaff-hotdog-firmware-console.cmdline"
kernel_sha=5978fb51e9386f318b22d6fbc598619d43d31238b123f758fe3de6a7dfa363db
dtb_sha=9510099d9a8eed0e1f368427ec17ce8595e81c992cc3b88eeca3883580870fad
ramdisk_sha=9918d137fdbf2fc64dc6185b291eefde631becf72d1aefde7c2c6a2f4a619d4d
base_cmdline_sha=902b55b27a157cc6ff14ce5acd155e4b118b1754a9ba8a0707117593071df8f6
cmdline_sha=b5d1c8487b5c7d35f36d2b2ae89143b49199763c9aa01ac950192f1f80b4c689
stamp="${HOTDOG_BUILD_STAMP:-$(date +%F-%H%M%S)}"
build_dir="$HOTDOG_ROOT/build/experiments/$stamp-clearstaff616-v15-firmware-console"
outdir="$HOTDOG_ROOT/images/pmos-experiments/$stamp-clearstaff616-direct-entry-v15-firmware-console"

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

check_sha() {
	local label="$1" path="$2" expected="$3" actual
	[ -s "$path" ] || die "missing $label: $path"
	actual="$(sha256sum "$path" | awk '{print $1}')"
	[ "$actual" = "$expected" ] ||
		die "$label hash mismatch: expected $expected, got $actual"
}

for command in awk cmp grep sha256sum wc; do
	command -v "$command" >/dev/null 2>&1 || die "missing command: $command"
done

check_sha kernel "$kernel" "$kernel_sha"
check_sha DTB "$dtb" "$dtb_sha"
check_sha ramdisk "$ramdisk" "$ramdisk_sha"
check_sha "base command line" "$base_cmdline" "$base_cmdline_sha"
check_sha "firmware-console command line" "$cmdline" "$cmdline_sha"
[ ! -e "$build_dir" ] || die "refusing to reuse build directory: $build_dir"
[ ! -e "$outdir" ] || die "refusing to reuse output directory: $outdir"

base="$(awk '{$1=$1; print}' "$base_cmdline")"
candidate="$(awk '{$1=$1; print}' "$cmdline")"
[ "$candidate" = "$base nomodeset" ] ||
	die "candidate command line is not exactly V14 plus nomodeset"
[ "$(printf '%s' "$candidate" | wc -c)" -eq 498 ] ||
	die "candidate command line has an unexpected length"
printf '%s\n' "$candidate" | grep -Eq '(^|[[:space:]])nomodeset([[:space:]]|$)' ||
	die "candidate command line lacks nomodeset"

mkdir -p "$build_dir"
cat > "$build_dir/change.txt" <<'EOF'
Parent: ClearStaff V14 simplefb no-map
Change: append the nomodeset kernel parameter
Purpose: retain the working firmware framebuffer and prevent an incomplete
         MSM DRM takeover from removing the visible fbcon console.
EOF
sha256sum "$kernel" "$dtb" "$ramdisk" "$base_cmdline" "$cmdline" \
	> "$build_dir/SHA256SUMS"

"$HOTDOG_ROOT/scripts/build-mainline-direct-bootimg.sh" \
	--kernel "$kernel" \
	--dtb "$dtb" \
	--ramdisk "$ramdisk" \
	--cmdline-file "$cmdline" \
	--outdir "$outdir" \
	--name boot-clearstaff616-direct-entry-v15-firmware-console \
	--partition-size 100663296

printf 'Build directory: %s\nArtifact directory: %s\n' "$build_dir" "$outdir"
