#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source "$(dirname "$0")/env.sh"

v33_dir="$HOTDOG_ROOT/images/pmos-experiments/2026-08-03-200000-clearstaff616-direct-entry-v33-ufs-dma32"
v35_dir="$HOTDOG_ROOT/images/pmos-experiments/2026-08-03-210000-clearstaff616-direct-entry-v35-dwc3-dma32"
source_ramdisk="$v33_dir/components/ramdisk"
kernel="$v35_dir/components/kernel"
dtb="$v33_dir/components/dtb"
cmdline="$v33_dir/components/cmdline.txt"
helper="$HOTDOG_ROOT/helpers/hotdog-v36-staged-usb.sh"
extractor="$HOTDOG_ROOT/scripts/extract-last-newc-member.py"
gen_init_cpio="$HOTDOG_ROOT/build/clearstaff-v35-dwc3-dma32/usr/gen_init_cpio"
kernel_sha=ebd7d558483e9ba4c9a99099898020f3318ca80cb95e573142cbb278a489cf83
dtb_sha=1d41e88dbcbfee960eebaf9e2c306b22e43ab05c09eee2f3e5f28106b326bbd4
source_ramdisk_sha=e4c563fcfc6f2a3533fd16539dd22a3fc578bf858e450a9ae7f66d212ae49ec3
cmdline_sha=902b55b27a157cc6ff14ce5acd155e4b118b1754a9ba8a0707117593071df8f6
stamp="${HOTDOG_BUILD_STAMP:-$(date +%F-%H%M%S)}"
build_dir="$HOTDOG_ROOT/build/experiments/$stamp-clearstaff616-v36-staged-usb"
outdir="$HOTDOG_ROOT/images/pmos-experiments/$stamp-clearstaff616-direct-entry-v36-staged-usb"
init2_original="$build_dir/init_2nd.original"
init2_staged="$build_dir/init_2nd.staged-usb"
overlay_list="$build_dir/staged-usb.list"
overlay="$build_dir/staged-usb-overlay.cpio"
ramdisk="$build_dir/initramfs-pmos-staged-usb.cpio"

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

for command in awk cmp grep python3 sha256sum stat; do
	command -v "$command" >/dev/null 2>&1 || die "missing command: $command"
done

check_sha kernel "$kernel" "$kernel_sha"
check_sha DTB "$dtb" "$dtb_sha"
check_sha ramdisk "$source_ramdisk" "$source_ramdisk_sha"
check_sha "kernel command line" "$cmdline" "$cmdline_sha"
[ -x "$helper" ] || die "missing executable V36 USB helper: $helper"
[ -x "$extractor" ] || die "missing initramfs extractor: $extractor"
[ -x "$gen_init_cpio" ] || die "missing gen_init_cpio: $gen_init_cpio"
[ ! -e "$build_dir" ] || die "refusing to reuse build directory: $build_dir"
[ ! -e "$outdir" ] || die "refusing to reuse output directory: $outdir"

mkdir -p "$build_dir"
"$extractor" "$source_ramdisk" init_2nd.sh > "$init2_original"
grep -q 'HOTDOG_DWC3_PASSIVE_USB_SETUP_SKIPPED' "$init2_original" ||
	die "source init_2nd lacks the passive USB marker"
grep -q 'HOTDOG_DWC3_PASSIVE_DHCP_SKIPPED' "$init2_original" ||
	die "source init_2nd lacks the passive DHCP marker"

awk '
	/HOTDOG_DWC3_PASSIVE_USB_SETUP_SKIPPED/ {
		print ". /hotdog-v36-staged-usb.sh"
		print "hotdog_v36_staged_usb_setup"
		usb_replaced++
		next
	}
	/HOTDOG_DWC3_PASSIVE_DHCP_SKIPPED/ {
		dhcp_removed++
		next
	}
	/# hotdog USB ACM getty begin/ {
		in_acm = 1
		acm_removed++
		print "printf '\''<6>HOTDOG_V36_ACM_RECONFIG_SKIPPED\\n'\'' > /dev/kmsg 2>/dev/null || true"
		next
	}
	in_acm && /# hotdog USB ACM getty end/ {
		in_acm = 0
		next
	}
	!in_acm { print }
	END {
		if (usb_replaced != 1 || dhcp_removed != 1 || acm_removed != 1 || in_acm)
			exit 42
	}
' "$init2_original" > "$init2_staged"
chmod 0755 "$init2_staged"
grep -q '^hotdog_v36_staged_usb_setup$' "$init2_staged" ||
	die "V36 setup call is absent"
grep -q 'HOTDOG_V36_ACM_RECONFIG_SKIPPED' "$init2_staged" ||
	die "V36 ACM skip marker is absent"
if grep -q 'HOTDOG_DWC3_PASSIVE_USB_SETUP_SKIPPED\|HOTDOG_DWC3_PASSIVE_DHCP_SKIPPED\|hotdog_usb_acm_getty_start initramfs' \
		"$init2_staged"; then
	die "an excluded passive or ACM action remains in V36 init_2nd"
fi

cat > "$overlay_list" <<EOF
file /init_2nd.sh $init2_staged 0755 0 0
file /hotdog-v36-staged-usb.sh $helper 0755 0 0
EOF
"$gen_init_cpio" "$overlay_list" > "$overlay"
cat "$source_ramdisk" "$overlay" > "$ramdisk"

source_size="$(stat -c %s "$source_ramdisk")"
cmp -n "$source_size" "$source_ramdisk" "$ramdisk" ||
	die "V36 ramdisk does not preserve the complete V33 prefix"
"$extractor" "$ramdisk" init_2nd.sh > "$build_dir/init_2nd.extracted"
"$extractor" "$ramdisk" hotdog-v36-staged-usb.sh > "$build_dir/helper.extracted"
cmp "$init2_staged" "$build_dir/init_2nd.extracted" ||
	die "embedded init_2nd differs from its source"
cmp "$helper" "$build_dir/helper.extracted" ||
	die "embedded V36 helper differs from its source"

sha256sum "$kernel" "$dtb" "$source_ramdisk" "$helper" "$overlay" \
	"$ramdisk" "$cmdline" > "$build_dir/SHA256SUMS"
cat > "$build_dir/change.txt" <<'EOF'
Kernel: byte-identical to V35 with SM8150 DWC3 coherent DMA below 4 GiB.
DTB and source initramfs: byte-identical to the hardware-validated V33 path.
Initramfs: create NCM configfs state without binding, wait two seconds, bind
           the UDC exactly once, then start DHCP only if binding returns.
ACM reconfiguration: disabled to keep the UDC bind test causal.
Automatic reboot, watchdog, and recovery actions: none.
EOF

"$HOTDOG_ROOT/scripts/build-mainline-direct-bootimg.sh" \
	--kernel "$kernel" \
	--dtb "$dtb" \
	--ramdisk "$ramdisk" \
	--cmdline-file "$cmdline" \
	--outdir "$outdir" \
	--name boot-clearstaff616-direct-entry-v36-staged-usb \
	--partition-size 100663296

cp "$build_dir/change.txt" "$outdir/components/"
sha256sum "$outdir/components/change.txt" >> "$outdir/SHA256SUMS"
cat >> "$outdir/MANIFEST.md" <<EOF

## V36 staged DWC3 gadget contract

- Kernel: byte-identical to V35 (\`$kernel_sha\`).
- DTB: byte-identical to V33 (\`$dtb_sha\`).
- Source initramfs: byte-identical to V33 (\`$source_ramdisk_sha\`).
- Functional delta: staged configfs creation, one UDC bind, then DHCP.
- Isolation: no ACM function creation, UDC unbind, or UDC rebind.
- Reset behavior: entirely manual.
EOF

printf 'Build directory: %s\nArtifact directory: %s\n' "$build_dir" "$outdir"
