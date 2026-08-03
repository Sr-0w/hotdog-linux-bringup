#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source "$(dirname "$0")/env.sh"

source_dir="$HOTDOG_ROOT/images/pmos-experiments/2026-08-03-114000-clearstaff616-direct-entry-v17-dispcc-off/components"
kernel="$source_dir/kernel"
dtb="$source_dir/dtb"
source_ramdisk="$source_dir/ramdisk"
cmdline="$HOTDOG_ROOT/configs/clearstaff-hotdog-passive.cmdline"
kernel_sha=5978fb51e9386f318b22d6fbc598619d43d31238b123f758fe3de6a7dfa363db
dtb_sha=574450adec3cd81b49a4373b6078af4e6dc497badc38cc4dc123559733431d5a
source_ramdisk_sha=9918d137fdbf2fc64dc6185b291eefde631becf72d1aefde7c2c6a2f4a619d4d
cmdline_sha=902b55b27a157cc6ff14ce5acd155e4b118b1754a9ba8a0707117593071df8f6
gen_init_cpio="$HOTDOG_ROOT/build/experiments/2026-07-10-mainline617-psci-entry-reset-src/usr/gen_init_cpio"
stamp="${HOTDOG_BUILD_STAMP:-$(date +%F-%H%M%S)}"
build_dir="$HOTDOG_ROOT/build/experiments/$stamp-clearstaff616-v18-fb-heartbeat"
outdir="$HOTDOG_ROOT/images/pmos-experiments/$stamp-clearstaff616-direct-entry-v18-fb-heartbeat"
helper_dir="$build_dir/helper"
helper="$helper_dir/hotdog-fb-heartbeat"
init_original="$build_dir/init.original"
init_instrumented="$build_dir/init.fb-heartbeat"
overlay_list="$build_dir/fb-heartbeat.list"
overlay="$build_dir/fb-heartbeat-overlay.cpio"
ramdisk="$build_dir/initramfs-pmos-fb-heartbeat.cpio"

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
[ ! -e "$build_dir" ] || die "refusing to reuse build directory: $build_dir"
[ ! -e "$outdir" ] || die "refusing to reuse output directory: $outdir"

mkdir -p "$build_dir"
"$HOTDOG_ROOT/scripts/build-hotdog-fb-heartbeat.sh" --outdir "$helper_dir"
file "$helper" | grep -q 'ARM aarch64' || die "heartbeat is not AArch64"
file "$helper" | grep -q 'statically linked' || die "heartbeat is not static"

"$HOTDOG_ROOT/scripts/extract-last-newc-member.py" \
	"$source_ramdisk" init > "$init_original"
awk '
	{ print }
	/^\/hotdog-userspace-stage 0$/ && !inserted {
		print "/hotdog-fb-heartbeat &"
		inserted = 1
	}
	END { if (!inserted) exit 42 }
' "$init_original" > "$init_instrumented"
chmod 0755 "$init_instrumented"
[ "$(grep -c '^/hotdog-fb-heartbeat &$' "$init_instrumented")" -eq 1 ] ||
	die "heartbeat launch was not injected exactly once"

cat > "$overlay_list" <<EOF
file /hotdog-fb-heartbeat $helper 0755 0 0
file /init $init_instrumented 0755 0 0
EOF
"$gen_init_cpio" "$overlay_list" > "$overlay"
cat "$source_ramdisk" "$overlay" > "$ramdisk"

source_size="$(stat -c %s "$source_ramdisk")"
cmp -n "$source_size" "$source_ramdisk" "$ramdisk" ||
	die "new ramdisk does not preserve the complete V17 prefix"
"$HOTDOG_ROOT/scripts/extract-last-newc-member.py" \
	"$ramdisk" hotdog-fb-heartbeat > "$build_dir/heartbeat.extracted"
"$HOTDOG_ROOT/scripts/extract-last-newc-member.py" \
	"$ramdisk" init > "$build_dir/init.extracted"
cmp "$helper" "$build_dir/heartbeat.extracted" ||
	die "embedded heartbeat differs from its source"
cmp "$init_instrumented" "$build_dir/init.extracted" ||
	die "embedded init differs from its source"

sha256sum "$kernel" "$dtb" "$source_ramdisk" "$overlay" "$ramdisk" \
	"$helper" "$cmdline" > "$build_dir/SHA256SUMS"
cat > "$build_dir/change.txt" <<'EOF'
Parent: ClearStaff V17 DISPCC disabled
Change: append a two-file initramfs overlay containing a static AArch64
        framebuffer heartbeat and an /init override that starts it after the
        first userspace checkpoint.
Purpose: distinguish framebuffer clearing from loss of firmware scanout. The
         helper repaints a wide magenta/green/cyan/white band four times per
         second and never requests a reboot or writes phone storage.
EOF

"$HOTDOG_ROOT/scripts/build-mainline-direct-bootimg.sh" \
	--kernel "$kernel" \
	--dtb "$dtb" \
	--ramdisk "$ramdisk" \
	--cmdline-file "$cmdline" \
	--outdir "$outdir" \
	--name boot-clearstaff616-direct-entry-v18-fb-heartbeat \
	--partition-size 100663296

printf 'Build directory: %s\nArtifact directory: %s\n' "$build_dir" "$outdir"
