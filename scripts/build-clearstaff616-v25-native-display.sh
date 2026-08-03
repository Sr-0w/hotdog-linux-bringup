#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source "$(dirname "$0")/env.sh"

kernel="$HOTDOG_ROOT/images/pmos-experiments/2026-08-02-221500-clearstaff616-direct-entry-v13-continue/components/kernel"
native_dtb="$HOTDOG_ROOT/images/pmos-experiments/2026-08-02-113800-clearstaff616-direct-baseline/components/dtb"
source_ramdisk="$HOTDOG_ROOT/images/pmos-experiments/2026-08-02-221500-clearstaff616-direct-entry-v13-continue/components/ramdisk"
cmdline="$HOTDOG_ROOT/configs/clearstaff-hotdog-passive.cmdline"
kernel_sha=5978fb51e9386f318b22d6fbc598619d43d31238b123f758fe3de6a7dfa363db
native_dtb_sha=ba9dd9ad3104384b6d659249386d8a233bdd0012ae176d7bfa6dcb488e4489a0
source_ramdisk_sha=9918d137fdbf2fc64dc6185b291eefde631becf72d1aefde7c2c6a2f4a619d4d
cmdline_sha=902b55b27a157cc6ff14ce5acd155e4b118b1754a9ba8a0707117593071df8f6
gen_init_cpio="$HOTDOG_ROOT/build/experiments/2026-07-10-mainline617-psci-entry-reset-src/usr/gen_init_cpio"
stamp="${HOTDOG_BUILD_STAMP:-$(date +%F-%H%M%S)}"
build_dir="$HOTDOG_ROOT/build/experiments/$stamp-clearstaff616-v25-native-display"
outdir="$HOTDOG_ROOT/images/pmos-experiments/$stamp-clearstaff616-direct-entry-v25-native-display"
init_original="$build_dir/init.original"
init_passive="$build_dir/init.passive"
overlay_list="$build_dir/passive-init.list"
overlay="$build_dir/passive-init-overlay.cpio"
ramdisk="$build_dir/initramfs-pmos-passive.cpio"
mdss=/soc@0/display-subsystem@ae00000
dpu="$mdss/display-controller@ae01000"
dsi="$mdss/dsi@ae94000"
panel="$dsi/panel@0"
phy="$mdss/phy@ae94400"

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

for command in awk cmp fdtget grep sha256sum stat; do
	command -v "$command" >/dev/null 2>&1 || die "missing command: $command"
done
check_sha kernel "$kernel" "$kernel_sha"
check_sha "native ClearStaff DTB" "$native_dtb" "$native_dtb_sha"
check_sha ramdisk "$source_ramdisk" "$source_ramdisk_sha"
check_sha "kernel command line" "$cmdline" "$cmdline_sha"
[ -x "$gen_init_cpio" ] || die "missing gen_init_cpio: $gen_init_cpio"
[ ! -e "$build_dir" ] || die "refusing to reuse build directory: $build_dir"
[ ! -e "$outdir" ] || die "refusing to reuse output directory: $outdir"

for node in "$mdss" "$dpu" "$dsi" "$panel" "$phy"; do
	[ "$(fdtget -t s "$native_dtb" "$node" status)" = okay ] ||
		die "native display node is not enabled: $node"
done
[ "$(fdtget -t s "$native_dtb" "$panel" compatible)" = samsung,oneplus-dsc ] ||
	die "native DTB does not select the OnePlus Samsung panel"
[ "$(fdtget -t x "$native_dtb" "$panel" vddio-supply)" = cd ] ||
	die "native panel does not consume PM8150 LDO14"
[ "$(fdtget -t x "$native_dtb" "$panel" reset-gpios)" = "4f 6 1" ] ||
	die "native panel reset GPIO is not TLMM GPIO 6 active-low"
[ "$(fdtget -t x "$native_dtb" "$dsi" vdda-supply)" = 6b ] ||
	die "native DSI controller does not consume PM8009 LDO3"
[ "$(fdtget -t x "$native_dtb" "$phy" vdds-supply)" = 37 ] ||
	die "native DSI PHY does not consume PM8150 LDO5"

mkdir -p "$build_dir"
"$HOTDOG_ROOT/scripts/extract-last-newc-member.py" \
	"$source_ramdisk" init > "$init_original"
grep -q 'HOTDOG_FAILURE_PANIC_ARMED=90' "$init_original" ||
	die "expected inherited 90-second failure panic is absent"
if grep -q '^/hotdog-fb-heartbeat &$' "$init_original"; then
	die "source initramfs unexpectedly starts the simplefb heartbeat"
fi

# Keep the original postmarketOS diagnostic init but remove its only forced
# panic path. Native display probing must remain undisturbed after launch.
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
' "$init_original" > "$init_passive"
chmod 0755 "$init_passive"
if grep -q 'HOTDOG_FAILURE_PANIC_' "$init_passive"; then
	die "failure panic code remains in passive init"
fi
if grep -q '^/hotdog-fb-heartbeat &$' "$init_passive"; then
	die "passive init unexpectedly starts the simplefb heartbeat"
fi

cat > "$overlay_list" <<EOF
file /init $init_passive 0755 0 0
EOF
"$gen_init_cpio" "$overlay_list" > "$overlay"
cat "$source_ramdisk" "$overlay" > "$ramdisk"

source_size="$(stat -c %s "$source_ramdisk")"
cmp -n "$source_size" "$source_ramdisk" "$ramdisk" ||
	die "new ramdisk does not preserve the complete V13 prefix"
"$HOTDOG_ROOT/scripts/extract-last-newc-member.py" \
	"$ramdisk" init > "$build_dir/init.extracted"
cmp "$init_passive" "$build_dir/init.extracted" ||
	die "embedded passive init differs from its source"

sha256sum "$kernel" "$native_dtb" "$source_ramdisk" "$overlay" \
	"$ramdisk" "$cmdline" > "$build_dir/SHA256SUMS"
cat > "$build_dir/change.txt" <<'EOF'
Kernel: ClearStaff V13 entry fix proven to reach kernel and userspace
DTB: untouched ClearStaff hotdog DTB with native MDSS, DPU, DSI, PHY, and
     samsung,oneplus-dsc panel graph enabled
Initramfs: V13 diagnostic postmarketOS init with only its 90-second panic
           worker removed; no simplefb heartbeat is installed or started
DTBO: selected by the launcher; this candidate requires the no-op DTBO
Purpose: test the corrected direct-entry kernel against the complete native
         display description for the first time.
EOF

"$HOTDOG_ROOT/scripts/build-mainline-direct-bootimg.sh" \
	--kernel "$kernel" \
	--dtb "$native_dtb" \
	--ramdisk "$ramdisk" \
	--cmdline-file "$cmdline" \
	--outdir "$outdir" \
	--name boot-clearstaff616-direct-entry-v25-native-display \
	--partition-size 100663296

printf 'Build directory: %s\nArtifact directory: %s\n' "$build_dir" "$outdir"
