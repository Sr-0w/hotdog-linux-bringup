#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source "$(dirname "$0")/env.sh"

source_dir="$HOTDOG_ROOT/images/pmos-experiments/2026-08-03-123000-clearstaff616-direct-entry-v19-simplefb-clocks/components"
kernel="$source_dir/kernel"
dtb="$source_dir/dtb"
source_ramdisk="$source_dir/ramdisk"
cmdline="$HOTDOG_ROOT/configs/clearstaff-hotdog-passive.cmdline"
kernel_sha=5978fb51e9386f318b22d6fbc598619d43d31238b123f758fe3de6a7dfa363db
dtb_sha=c84344db53697b013ff4ca9eeb3b01b0277999984c09de70b2100b1a0515bfe0
source_ramdisk_sha=d15cebf6ddf0963b6ec89509f7d27ce5cc1f3f4fd67ab092a66c95f1f9927837
cmdline_sha=902b55b27a157cc6ff14ce5acd155e4b118b1754a9ba8a0707117593071df8f6
gen_init_cpio="$HOTDOG_ROOT/build/experiments/2026-07-10-mainline617-psci-entry-reset-src/usr/gen_init_cpio"
stamp="${HOTDOG_BUILD_STAMP:-$(date +%F-%H%M%S)}"
build_dir="$HOTDOG_ROOT/build/experiments/$stamp-clearstaff616-v20-simplefb-clocks-no-panic"
outdir="$HOTDOG_ROOT/images/pmos-experiments/$stamp-clearstaff616-direct-entry-v20-simplefb-clocks-no-panic"
init_original="$build_dir/init.original"
init_no_panic="$build_dir/init.no-failure-panic"
overlay_list="$build_dir/no-failure-panic.list"
overlay="$build_dir/no-failure-panic-overlay.cpio"
ramdisk="$build_dir/initramfs-pmos-no-failure-panic.cpio"

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

for command in awk cmp grep sha256sum stat; do
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
"$HOTDOG_ROOT/scripts/extract-last-newc-member.py" \
	"$source_ramdisk" init > "$init_original"
grep -q 'HOTDOG_FAILURE_PANIC_ARMED=90' "$init_original" ||
	die "expected inherited 90-second failure panic is absent"

awk '
	/^\/hotdog-userspace-stage 4$/ {
		print
		await_block = 1
		next
	}
	await_block {
		if ($0 != "(")
			exit 42
		await_block = 0
		skipping = 1
		next
	}
	skipping {
		if ($0 == ") &") {
			skipping = 0
			removed++
		}
		next
	}
	{ print }
	END {
		if (removed != 1 || skipping || await_block)
			exit 42
	}
' "$init_original" > "$init_no_panic"
chmod 0755 "$init_no_panic"
if grep -q 'HOTDOG_FAILURE_PANIC_' "$init_no_panic"; then
	die "failure panic code remains in the init override"
fi
[ "$(grep -c '^/hotdog-fb-heartbeat &$' "$init_no_panic")" -eq 1 ] ||
	die "framebuffer heartbeat launch was not preserved"

cat > "$overlay_list" <<EOF
file /init $init_no_panic 0755 0 0
EOF
"$gen_init_cpio" "$overlay_list" > "$overlay"
cat "$source_ramdisk" "$overlay" > "$ramdisk"

source_size="$(stat -c %s "$source_ramdisk")"
cmp -n "$source_size" "$source_ramdisk" "$ramdisk" ||
	die "new ramdisk does not preserve the complete V19 prefix"
"$HOTDOG_ROOT/scripts/extract-last-newc-member.py" \
	"$ramdisk" init > "$build_dir/init.extracted"
"$HOTDOG_ROOT/scripts/extract-last-newc-member.py" \
	"$ramdisk" hotdog-fb-heartbeat > "$build_dir/heartbeat.extracted"
cmp "$init_no_panic" "$build_dir/init.extracted" ||
	die "embedded init differs from its source"
grep -a -q 'HOTDOG_FB_HEARTBEAT_V1' "$build_dir/heartbeat.extracted" ||
	die "framebuffer heartbeat was not preserved"

sha256sum "$kernel" "$dtb" "$source_ramdisk" "$overlay" "$ramdisk" \
	"$cmdline" > "$build_dir/SHA256SUMS"
cat > "$build_dir/change.txt" <<'EOF'
Parent: ClearStaff V19 simplefb GCC clocks
Change: remove the inherited 90-second HOTDOG_FAILURE_PANIC worker from /init.
Purpose: failed candidates must remain passive until one manual reset. This
         prevents a diagnostic timeout from placing the phone in Qualcomm
         crashdump mode and does not alter the first 90 seconds of boot.
EOF

"$HOTDOG_ROOT/scripts/build-mainline-direct-bootimg.sh" \
	--kernel "$kernel" \
	--dtb "$dtb" \
	--ramdisk "$ramdisk" \
	--cmdline-file "$cmdline" \
	--outdir "$outdir" \
	--name boot-clearstaff616-direct-entry-v20-simplefb-clocks-no-panic \
	--partition-size 100663296

printf 'Build directory: %s\nArtifact directory: %s\n' "$build_dir" "$outdir"
