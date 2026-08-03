#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source "$(dirname "$0")/env.sh"

source_dir="$HOTDOG_ROOT/images/pmos-experiments/2026-08-03-133000-clearstaff616-direct-entry-v20-simplefb-clocks-no-panic/components"
kernel="$source_dir/kernel"
dtb="$source_dir/dtb"
ramdisk="$source_dir/ramdisk"
baseline_cmdline="$HOTDOG_ROOT/configs/clearstaff-hotdog-passive.cmdline"
cmdline="$HOTDOG_ROOT/configs/clearstaff-hotdog-passive-regulators.cmdline"
kernel_sha=5978fb51e9386f318b22d6fbc598619d43d31238b123f758fe3de6a7dfa363db
dtb_sha=c84344db53697b013ff4ca9eeb3b01b0277999984c09de70b2100b1a0515bfe0
ramdisk_sha=bc13a04577f65e7812267b96cbd8a5cfb79652397408edbf8104b5d14b8e631a
baseline_cmdline_sha=902b55b27a157cc6ff14ce5acd155e4b118b1754a9ba8a0707117593071df8f6
cmdline_sha=00e356443607007a6f0092f7c911dce691c558ecbb3dc6ecd3ec5a4f1a4fe42e
stamp="${HOTDOG_BUILD_STAMP:-$(date +%F-%H%M%S)}"
build_dir="$HOTDOG_ROOT/build/experiments/$stamp-clearstaff616-v22-regulator-retention"
outdir="$HOTDOG_ROOT/images/pmos-experiments/$stamp-clearstaff616-direct-entry-v22-regulator-retention"

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

for command in awk diff grep sha256sum sort tr wc; do
	command -v "$command" >/dev/null 2>&1 || die "missing command: $command"
done
check_sha kernel "$kernel" "$kernel_sha"
check_sha DTB "$dtb" "$dtb_sha"
check_sha ramdisk "$ramdisk" "$ramdisk_sha"
check_sha "baseline kernel command line" "$baseline_cmdline" "$baseline_cmdline_sha"
check_sha "regulator-retention kernel command line" "$cmdline" "$cmdline_sha"
[ ! -e "$build_dir" ] || die "refusing to reuse build directory: $build_dir"
[ ! -e "$outdir" ] || die "refusing to reuse output directory: $outdir"

cmdline_size="$(wc -c < "$cmdline")"
[ "$cmdline_size" -le 511 ] ||
	die "kernel command line is $cmdline_size bytes; bootloader limit is 511"
[ "$(grep -oE '(^|[[:space:]])regulator_ignore_unused([[:space:]]|$)' "$cmdline" | wc -l)" -eq 1 ] ||
	die "regulator_ignore_unused must occur exactly once"
if grep -Eq '(^|[[:space:]])ignore_loglevel([[:space:]]|$)' "$cmdline"; then
	die "redundant ignore_loglevel token was not removed"
fi

mkdir -p "$build_dir"
tr ' ' '\n' < "$baseline_cmdline" | sort > "$build_dir/baseline.tokens"
tr ' ' '\n' < "$cmdline" | sort > "$build_dir/regulator-retention.tokens"
diff -u "$build_dir/baseline.tokens" "$build_dir/regulator-retention.tokens" \
	> "$build_dir/cmdline-semantic.diff" || true
[ "$(awk '/^[+-]/ && !/^(---|\+\+\+)/ { count++ } END { print count + 0 }' \
	"$build_dir/cmdline-semantic.diff")" -eq 2 ] ||
	die "kernel command line semantic diff is not exactly two token changes"
grep -Fxq -- '-ignore_loglevel' "$build_dir/cmdline-semantic.diff" ||
	die "kernel command line diff does not remove ignore_loglevel"
grep -Fxq -- '+regulator_ignore_unused' "$build_dir/cmdline-semantic.diff" ||
	die "kernel command line diff does not add regulator_ignore_unused"

sha256sum "$kernel" "$dtb" "$ramdisk" "$baseline_cmdline" "$cmdline" \
	> "$build_dir/SHA256SUMS"
cat > "$build_dir/change.txt" <<'EOF'
Parent: ClearStaff V20 simplefb GCC clocks, passive failure
Change: replace redundant ignore_loglevel with regulator_ignore_unused.
Purpose: prevent the regulator core's init-complete cleanup from disabling
         firmware-enabled panel supplies which the incomplete mainline hotdog
         display description does not yet claim. No DTB or executable payload
         changes; panic=0 and passive failure behavior remain unchanged.
EOF

"$HOTDOG_ROOT/scripts/build-mainline-direct-bootimg.sh" \
	--kernel "$kernel" \
	--dtb "$dtb" \
	--ramdisk "$ramdisk" \
	--cmdline-file "$cmdline" \
	--outdir "$outdir" \
	--name boot-clearstaff616-direct-entry-v22-regulator-retention \
	--partition-size 100663296

printf 'Build directory: %s\nArtifact directory: %s\n' "$build_dir" "$outdir"
