#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source "$(dirname "$0")/env.sh"

input="$HOTDOG_ROOT/images/pmos-experiments/2026-08-02-143322-clearstaff616-direct-entry-v11-working-dtb/components/kernel"
input_sha=501688778be5dcca4087f5f0b43eefddf581a426caae91588700deda7a169581
dtb="$HOTDOG_ROOT/images/pmos-experiments/2026-08-02-143322-clearstaff616-direct-entry-v11-working-dtb/components/dtb"
ramdisk="$HOTDOG_ROOT/images/pmos-experiments/2026-08-02-143322-clearstaff616-direct-entry-v11-working-dtb/components/ramdisk"
cmdline="$HOTDOG_ROOT/configs/clearstaff-hotdog-passive.cmdline"
stamp="${HOTDOG_BUILD_STAMP:-$(date +%F-%H%M%S)}"
build_dir="$HOTDOG_ROOT/build/experiments/$stamp-clearstaff616-v13-continue"
outdir="$HOTDOG_ROOT/images/pmos-experiments/$stamp-clearstaff616-direct-entry-v13-continue"
output="$build_dir/Image"
patch_offset=$((0x165d104))

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

read_hex() {
	dd if="$1" bs=1 skip="$2" count="$3" status=none |
		od -An -tx1 -v | tr -d ' \n'
}

for command in awk cmp dd od sha256sum stat tr wc; do
	command -v "$command" >/dev/null 2>&1 || die "missing command: $command"
done

[ "$(sha256sum "$input" | awk '{print $1}')" = "$input_sha" ] ||
	die "input Image hash mismatch"
[ ! -e "$build_dir" ] || die "refusing to reuse build directory: $build_dir"
[ ! -e "$outdir" ] || die "refusing to reuse output directory: $outdir"
[ "$(read_hex "$input" "$patch_offset" 4)" = 9f3f03d5 ] ||
	die "expected final canary dsb instruction is absent"

mkdir -p "$build_dir"
cp "$input" "$output"

# Branch over the V9 WFE hold after the validated canary. The two invalid-state
# TBNZ instructions still target that hold, so a bad ABL entry contract remains
# fail-closed without touching further physical addresses.
printf '\x03\x00\x00\x14' |
	dd of="$output" bs=1 seek="$patch_offset" conv=notrunc status=none

[ "$(read_hex "$output" "$patch_offset" 4)" = 03000014 ] ||
	die "patched branch verification failed"
[ "$(stat -c %s "$input")" = "$(stat -c %s "$output")" ] ||
	die "patched Image size changed"

if cmp -s "$input" "$output"; then
	die "patched Image is unexpectedly identical to its input"
fi
cmp -l "$input" "$output" > "$build_dir/cmp-l.txt" || true
[ "$(wc -l < "$build_dir/cmp-l.txt")" -eq 4 ] ||
	die "patched Image differs at more than four byte positions"
sha256sum "$input" "$output" > "$build_dir/SHA256SUMS"
printf 'offset=0x%x\nold=9f3f03d5\nnew=03000014\n' "$patch_offset" \
	> "$build_dir/binary-patch.txt"

"$HOTDOG_ROOT/scripts/build-mainline-direct-bootimg.sh" \
	--kernel "$output" \
	--dtb "$dtb" \
	--ramdisk "$ramdisk" \
	--cmdline-file "$cmdline" \
	--outdir "$outdir" \
	--name boot-clearstaff616-direct-entry-v13-continue \
	--partition-size 100663296

printf 'Build directory: %s\nArtifact directory: %s\n' "$build_dir" "$outdir"
