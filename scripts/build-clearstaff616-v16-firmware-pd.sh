#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source "$(dirname "$0")/env.sh"

source_dir="$HOTDOG_ROOT/images/pmos-experiments/2026-08-02-231500-clearstaff616-direct-entry-v14-simplefb-nomap/components"
kernel="$source_dir/kernel"
dtb="$source_dir/dtb"
ramdisk="$source_dir/ramdisk"
base_cmdline="$HOTDOG_ROOT/configs/clearstaff-hotdog-passive.cmdline"
cmdline="$HOTDOG_ROOT/configs/clearstaff-hotdog-firmware-pd.cmdline"
kernel_sha=5978fb51e9386f318b22d6fbc598619d43d31238b123f758fe3de6a7dfa363db
dtb_sha=9510099d9a8eed0e1f368427ec17ce8595e81c992cc3b88eeca3883580870fad
ramdisk_sha=9918d137fdbf2fc64dc6185b291eefde631becf72d1aefde7c2c6a2f4a619d4d
base_cmdline_sha=902b55b27a157cc6ff14ce5acd155e4b118b1754a9ba8a0707117593071df8f6
cmdline_sha=0076bbd6f2247608e952594e066b0ed3a7026f4d0439ae2226f0de8ccf5b76ab
stamp="${HOTDOG_BUILD_STAMP:-$(date +%F-%H%M%S)}"
build_dir="$HOTDOG_ROOT/build/experiments/$stamp-clearstaff616-v16-firmware-pd"
outdir="$HOTDOG_ROOT/images/pmos-experiments/$stamp-clearstaff616-direct-entry-v16-firmware-pd"
mdss_node=/soc@0/display-subsystem@ae00000

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

for command in awk fdtget grep sha256sum wc; do
	command -v "$command" >/dev/null 2>&1 || die "missing command: $command"
done

check_sha kernel "$kernel" "$kernel_sha"
check_sha DTB "$dtb" "$dtb_sha"
check_sha ramdisk "$ramdisk" "$ramdisk_sha"
check_sha "base command line" "$base_cmdline" "$base_cmdline_sha"
check_sha "firmware-power command line" "$cmdline" "$cmdline_sha"
[ ! -e "$build_dir" ] || die "refusing to reuse build directory: $build_dir"
[ ! -e "$outdir" ] || die "refusing to reuse output directory: $outdir"

base="$(awk '{$1=$1; print}' "$base_cmdline")"
candidate="$(awk '{$1=$1; print}' "$cmdline")"
[ "$candidate" = "$base pd_ignore_unused" ] ||
	die "candidate command line is not exactly V14 plus pd_ignore_unused"
[ "$(printf '%s' "$candidate" | wc -c)" -eq 505 ] ||
	die "candidate command line has an unexpected length"
printf '%s\n' "$candidate" | grep -Eq '(^|[[:space:]])pd_ignore_unused([[:space:]]|$)' ||
	die "candidate command line lacks pd_ignore_unused"
if printf '%s\n' "$candidate" | grep -Eq '(^|[[:space:]])nomodeset([[:space:]]|$)'; then
	die "candidate command line unexpectedly retains nomodeset"
fi
[ "$(fdtget -t s "$dtb" "$mdss_node" status)" = disabled ] ||
	die "MDSS is not disabled in the pinned V14 DTB"

mkdir -p "$build_dir"
cat > "$build_dir/change.txt" <<'EOF'
Parent: ClearStaff V14 simplefb no-map
Change: append only the pd_ignore_unused kernel parameter
Purpose: keep firmware-enabled display power domains alive after late init.
         The V14 DTB already disables MDSS/DPU/DSI, so no native display
         consumer prevents genpd from powering their inherited domain down.
EOF
sha256sum "$kernel" "$dtb" "$ramdisk" "$base_cmdline" "$cmdline" \
	> "$build_dir/SHA256SUMS"

"$HOTDOG_ROOT/scripts/build-mainline-direct-bootimg.sh" \
	--kernel "$kernel" \
	--dtb "$dtb" \
	--ramdisk "$ramdisk" \
	--cmdline-file "$cmdline" \
	--outdir "$outdir" \
	--name boot-clearstaff616-direct-entry-v16-firmware-pd \
	--partition-size 100663296

printf 'Build directory: %s\nArtifact directory: %s\n' "$build_dir" "$outdir"
