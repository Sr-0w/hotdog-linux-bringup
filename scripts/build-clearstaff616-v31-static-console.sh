#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source "$(dirname "$0")/env.sh"

v30_dir="$HOTDOG_ROOT/images/pmos-experiments/2026-08-03-190000-clearstaff616-direct-entry-v30-dynamic-pps"
kernel="$v30_dir/components/kernel"
dtb="$v30_dir/components/dtb"
source_ramdisk="$v30_dir/components/ramdisk"
cmdline="$v30_dir/components/cmdline.txt"
wrapper_source="$HOTDOG_ROOT/helpers/hotdog-static-console-wrapper.sh"
gen_init_cpio="$HOTDOG_ROOT/build/experiments/2026-07-10-mainline617-psci-entry-reset-src/usr/gen_init_cpio"
kernel_sha=895432d812868fb1eed238cb0a2af4570c7953e1503f38db9b9d7b9bc493bf0d
dtb_sha=1d41e88dbcbfee960eebaf9e2c306b22e43ab05c09eee2f3e5f28106b326bbd4
source_ramdisk_sha=e4c563fcfc6f2a3533fd16539dd22a3fc578bf858e450a9ae7f66d212ae49ec3
cmdline_sha=902b55b27a157cc6ff14ce5acd155e4b118b1754a9ba8a0707117593071df8f6
stamp="${HOTDOG_BUILD_STAMP:-$(date +%F-%H%M%S)}"
build_dir="$HOTDOG_ROOT/build/experiments/$stamp-clearstaff616-v31-static-console"
outdir="$HOTDOG_ROOT/images/pmos-experiments/$stamp-clearstaff616-direct-entry-v31-static-console"
overlay_list="$build_dir/static-console.list"
overlay="$build_dir/static-console-overlay.cpio"
ramdisk="$build_dir/initramfs-pmos-v31-static-console.cpio"

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

for command in awk cmp file grep sha256sum stat; do
	command -v "$command" >/dev/null 2>&1 || die "missing command: $command"
done
check_sha kernel "$kernel" "$kernel_sha"
check_sha DTB "$dtb" "$dtb_sha"
check_sha ramdisk "$source_ramdisk" "$source_ramdisk_sha"
check_sha "kernel command line" "$cmdline" "$cmdline_sha"
[ -x "$gen_init_cpio" ] || die "missing gen_init_cpio: $gen_init_cpio"
[ -x "$wrapper_source" ] || die "missing executable wrapper: $wrapper_source"
[ ! -e "$build_dir" ] || die "refusing to reuse build directory: $build_dir"
[ ! -e "$outdir" ] || die "refusing to reuse output directory: $outdir"

grep -q '^#!/bin/busybox ash$' "$wrapper_source" ||
	die "static console wrapper does not use initramfs BusyBox"
grep -q 'HOTDOG V31 - NATIVE MAINLINE STATIC DISPLAY TEST' "$wrapper_source" ||
	die "static V31 display marker is missing"
grep -q "exec \"\$bb\" ash -i" "$wrapper_source" ||
	die "static V31 tty0 shell is missing"

mkdir -p "$build_dir"
cat > "$overlay_list" <<EOF
file /hotdog-mainline-wrapper $wrapper_source 0755 0 0
EOF
"$gen_init_cpio" "$overlay_list" > "$overlay"
cat "$source_ramdisk" "$overlay" > "$ramdisk"

source_size="$(stat -c %s "$source_ramdisk")"
cmp -n "$source_size" "$source_ramdisk" "$ramdisk" ||
	die "V31 ramdisk does not preserve the complete V30 prefix"
"$HOTDOG_ROOT/scripts/extract-last-newc-member.py" \
	"$ramdisk" hotdog-mainline-wrapper > "$build_dir/hotdog-mainline-wrapper.extracted"
cmp "$wrapper_source" "$build_dir/hotdog-mainline-wrapper.extracted" ||
	die "embedded V31 wrapper differs from its source"

sha256sum "$kernel" "$dtb" "$source_ramdisk" "$wrapper_source" \
	"$overlay" "$ramdisk" "$cmdline" > "$build_dir/SHA256SUMS"
cat > "$build_dir/change.txt" <<'EOF'
Kernel: byte-identical V30 ClearStaff Linux 6.16 native-panel kernel.
DTB: byte-identical V30 native panel + TE graph.
DTBO: unchanged D7 filtered vendor overlay, selected by the launcher.
Command line: byte-identical V30 verbose, passive command line.
Initramfs: append-only replacement of rdinit. After preserving dmesg in RAM,
           it suppresses further console printk, clears tty0, draws five large
           unique static bands at known vertical positions, and leaves an
           interactive BusyBox ash shell alive on tty0. It never reboots.
Purpose: distinguish DSI/DPU scanout repetition from fbcon scroll corruption
         without changing the now-proven V30 display transport.
EOF

"$HOTDOG_ROOT/scripts/build-mainline-direct-bootimg.sh" \
	--kernel "$kernel" \
	--dtb "$dtb" \
	--ramdisk "$ramdisk" \
	--cmdline-file "$cmdline" \
	--outdir "$outdir" \
	--name boot-clearstaff616-direct-entry-v31-static-console \
	--partition-size 100663296

cp "$wrapper_source" "$outdir/components/"
sha256sum "$outdir/components/$(basename "$wrapper_source")" >> "$outdir/SHA256SUMS"
cat >> "$outdir/MANIFEST.md" <<EOF

## V31 static console contract

- Kernel, DTB, and command line are byte-identical to V30.
- Source V30 ramdisk: \`$source_ramdisk\`
- Source V30 ramdisk SHA-256: \`$source_ramdisk_sha\`
- V31 wrapper: \`components/$(basename "$wrapper_source")\`
- Console geometry test: five non-scrolling, color-coded horizontal bands.
- Rescue surface: interactive BusyBox \`ash\` on \`tty0\`.
- Automatic reboot, panic, watchdog, and USB recovery actions: none.
EOF

printf 'Build directory: %s\nArtifact directory: %s\n' "$build_dir" "$outdir"
