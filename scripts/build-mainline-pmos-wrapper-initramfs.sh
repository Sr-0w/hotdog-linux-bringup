#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/env.sh"

BASE_CPIO="$HOTDOG_ROOT/build/experiments/2026-07-11-110300-mainline617-pmos-r5-raw-initramfs/initramfs-pmos-r5.cpio"
GEN_INIT_CPIO="$HOTDOG_ROOT/build/experiments/2026-07-10-mainline617-psci-entry-reset-src/usr/gen_init_cpio"
OUTDIR=""
SUPPRESS_FB_PAINT=1
USERSPACE_FB_MARKER=0
WRAPPER_BINARY=""
REBOOT_MODE_HELPER=""

usage() {
	cat <<'USAGE'
Usage: build-mainline-pmos-wrapper-initramfs.sh [options]

Append a small diagnostic CPIO to an uncompressed postmarketOS initramfs.
Boot with rdinit=/hotdog-mainline-wrapper to log userspace entry and then
execute the original /init without modifying the source archive. By default,
the overlay also replaces an inherited hotdog framebuffer paint probe with a
wait-only probe so it cannot overwrite kernel console output while preserving
the validated probe timing. The wrapper accepts
hotdog_wrapper_settle_sec=N on the kernel command line.

Options:
  --base-cpio FILE      Uncompressed postmarketOS newc archive.
  --gen-init-cpio FILE  Kernel gen_init_cpio helper.
  --outdir DIR          Output directory below build/experiments by default.
  --keep-fb-paint       Keep any inherited framebuffer paint probe enabled.
  --large-fb-marker     Add four static white userspace progress bands.
  --wrapper-binary FILE Use a prebuilt static AArch64 wrapper instead of ash.
  --reboot-mode-helper FILE
                        Add a static RESTART2 helper and make the inherited
                        rescue watchdog request bootloader mode before its
                        normal-reboot fallback.
  -h, --help            Show this help.
USAGE
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--base-cpio) BASE_CPIO="$2"; shift ;;
		--gen-init-cpio) GEN_INIT_CPIO="$2"; shift ;;
		--outdir) OUTDIR="$2"; shift ;;
		--keep-fb-paint) SUPPRESS_FB_PAINT=0 ;;
		--large-fb-marker) USERSPACE_FB_MARKER=1 ;;
		--wrapper-binary) WRAPPER_BINARY="$2"; shift ;;
		--reboot-mode-helper) REBOOT_MODE_HELPER="$2"; shift ;;
		-h|--help) usage; exit 0 ;;
		*) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
	esac
	shift
done

OUTDIR="${OUTDIR:-$HOTDOG_ROOT/build/experiments/$(date +%F-%H%M%S)-mainline617-pmos-wrapper-initramfs}"

for command_name in cpio file gzip sha256sum; do
	command -v "$command_name" >/dev/null 2>&1 || {
		printf 'Missing command: %s\n' "$command_name" >&2
		exit 127
	}
done
[ -s "$BASE_CPIO" ] || { printf 'Missing base CPIO: %s\n' "$BASE_CPIO" >&2; exit 2; }
[ -x "$GEN_INIT_CPIO" ] || { printf 'Missing gen_init_cpio: %s\n' "$GEN_INIT_CPIO" >&2; exit 2; }
if [ -n "$WRAPPER_BINARY" ]; then
	[ -x "$WRAPPER_BINARY" ] || {
		printf 'Missing executable wrapper binary: %s\n' "$WRAPPER_BINARY" >&2
		exit 2
	}
	file "$WRAPPER_BINARY" | grep -q 'ELF 64-bit LSB executable, ARM aarch64' || {
		printf 'Wrapper is not an AArch64 executable: %s\n' "$WRAPPER_BINARY" >&2
		exit 2
	}
fi
if [ -n "$REBOOT_MODE_HELPER" ]; then
	[ -x "$REBOOT_MODE_HELPER" ] || {
		printf 'Missing executable reboot-mode helper: %s\n' "$REBOOT_MODE_HELPER" >&2
		exit 2
	}
	file "$REBOOT_MODE_HELPER" | grep -q 'ELF 64-bit LSB executable, ARM aarch64' || {
		printf 'Reboot-mode helper is not an AArch64 executable: %s\n' "$REBOOT_MODE_HELPER" >&2
		exit 2
	}
	[ -x "$HOTDOG_ROOT/scripts/extract-last-newc-member.py" ] || {
		printf 'Missing newc extractor: %s\n' \
			"$HOTDOG_ROOT/scripts/extract-last-newc-member.py" >&2
		exit 2
	}
fi
file "$BASE_CPIO" | grep -q 'cpio archive' || {
	printf 'Base file is not an uncompressed CPIO archive: %s\n' "$BASE_CPIO" >&2
	exit 2
}

mkdir -p "$OUTDIR"
wrapper="$OUTDIR/hotdog-mainline-wrapper"
fb_test_override="$OUTDIR/hotdog_fb_test.sh"
fb_marker="$OUTDIR/hotdog-userspace-fb-marker"
fb_marker_hook="$OUTDIR/01-hotdog-userspace-fb-marker.sh"
fb_marker_cleanup_hook="$OUTDIR/01-hotdog-userspace-root-marker.sh"
watchdog_override="$OUTDIR/hotdog_rescue_watchdog.sh"
list_file="$OUTDIR/wrapper.list"
overlay="$OUTDIR/wrapper-overlay.cpio"
output="$OUTDIR/initramfs-pmos-wrapped.cpio"
output_gzip="$OUTDIR/initramfs-pmos-wrapped.cpio.gz"

if [ -n "$WRAPPER_BINARY" ]; then
	cp "$WRAPPER_BINARY" "$wrapper"
else
	cat > "$wrapper" <<'WRAPPER'
#!/bin/busybox ash

bb=/bin/busybox
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
export HOME=/root
export TERM=linux

$bb mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
$bb mount -t proc proc /proc 2>/dev/null || true
$bb mount -t sysfs sysfs /sys 2>/dev/null || true

if [ -c /dev/console ]; then
	exec </dev/console >/dev/console 2>&1
fi

marker='HOTDOG_MAINLINE_PMOS_WRAPPER_REACHED'
printf '\n%s\n' "$marker"
printf '%s\n' "$marker" >/dev/tty0 2>/dev/null || true
printf '<6>%s\n' "$marker" >/dev/kmsg 2>/dev/null || true
[ -x /hotdog-userspace-fb-marker ] &&
	/hotdog-userspace-fb-marker wrapper-entry || true

panic_sec=''
settle_sec=''
for parameter in $($bb cat /proc/cmdline 2>/dev/null); do
	case "$parameter" in
		hotdog_wrapper_panic_sec=*) panic_sec="${parameter#*=}" ;;
		hotdog_wrapper_settle_sec=*) settle_sec="${parameter#*=}" ;;
	esac
done
case "$settle_sec" in
	''|*[!0-9]*) ;;
	*)
		printf '<6>HOTDOG_MAINLINE_PMOS_SETTLE_START=%s\n' "$settle_sec" >/dev/kmsg 2>/dev/null || true
		$bb sleep "$settle_sec"
		printf '<6>HOTDOG_MAINLINE_PMOS_SETTLE_DONE=%s\n' "$settle_sec" >/dev/kmsg 2>/dev/null || true
		;;
esac
case "$panic_sec" in
	''|*[!0-9]*) ;;
	*)
		(
			printf '<6>HOTDOG_MAINLINE_PMOS_PANIC_ARMED=%s\n' "$panic_sec" >/dev/kmsg 2>/dev/null || true
			$bb sleep "$panic_sec"
			printf '<0>HOTDOG_MAINLINE_PMOS_CONTROLLED_PANIC\n' >/dev/kmsg 2>/dev/null || true
			printf '1\n' >/proc/sys/kernel/sysrq 2>/dev/null || true
			printf 'c\n' >/proc/sysrq-trigger 2>/dev/null || $bb reboot -f
		) &
		;;
esac

printf '<6>HOTDOG_MAINLINE_PMOS_EXEC_INIT\n' >/dev/kmsg 2>/dev/null || true
[ -x /hotdog-userspace-fb-marker ] &&
	/hotdog-userspace-fb-marker wrapper-exec-init || true
exec /init "$@"
WRAPPER
fi
chmod 0755 "$wrapper"

cat > "$list_file" <<EOF
file /hotdog-mainline-wrapper $wrapper 0755 0 0
EOF

if [ "$USERSPACE_FB_MARKER" -eq 1 ]; then
	cat > "$fb_marker" <<'FB_MARKER'
#!/bin/busybox ash

bb=/bin/busybox
stage="${1:-unknown}"
height=120
stride=5760

case "$stage" in
	wrapper-entry) start=500 ;;
	wrapper-exec-init) start=700 ;;
	init2-post-usb) start=900 ;;
	root-mounted) start=1100 ;;
	*) exit 2 ;;
esac

fb=''
for candidate in /dev/fb0 /dev/graphics/fb0; do
	if [ -e "$candidate" ]; then
		fb="$candidate"
		break
	fi
done
if [ -z "$fb" ]; then
	printf '<4>HOTDOG_USERSPACE_FB_MARKER_NO_FB=%s\n' "$stage" \
		>/dev/kmsg 2>/dev/null || true
	exit 3
fi

bytes=$((stride * height))
if $bb dd if=/dev/zero bs="$bytes" count=1 status=none 2>/dev/null |
	$bb tr '\000' '\377' |
	$bb dd of="$fb" bs="$stride" seek="$start" count="$height" \
		conv=notrunc status=none 2>/dev/null; then
	printf '<6>HOTDOG_USERSPACE_FB_MARKER_OK=%s\n' "$stage" \
		>/dev/kmsg 2>/dev/null || true
	$bb sync
	exit 0
fi

printf '<3>HOTDOG_USERSPACE_FB_MARKER_FAILED=%s\n' "$stage" \
	>/dev/kmsg 2>/dev/null || true
exit 4
FB_MARKER
	chmod 0755 "$fb_marker"

	cat > "$fb_marker_hook" <<'FB_MARKER_HOOK'
#!/bin/busybox ash
/hotdog-userspace-fb-marker init2-post-usb || true
FB_MARKER_HOOK
	chmod 0755 "$fb_marker_hook"

	cat > "$fb_marker_cleanup_hook" <<'FB_MARKER_CLEANUP_HOOK'
#!/bin/busybox ash
/hotdog-userspace-fb-marker root-mounted || true
FB_MARKER_CLEANUP_HOOK
	chmod 0755 "$fb_marker_cleanup_hook"

	cat >> "$list_file" <<EOF
nod /dev/zero 0600 0 0 c 1 5
nod /dev/fb0 0600 0 0 c 29 0
file /hotdog-userspace-fb-marker $fb_marker 0755 0 0
file /hooks/01-hotdog-userspace-fb-marker.sh $fb_marker_hook 0755 0 0
file /hooks-cleanup/01-hotdog-userspace-root-marker.sh $fb_marker_cleanup_hook 0755 0 0
EOF
fi

if [ -n "$REBOOT_MODE_HELPER" ]; then
	"$HOTDOG_ROOT/scripts/extract-last-newc-member.py" \
		"$BASE_CPIO" hotdog_rescue_watchdog.sh |
		awk '
			/sync 2>\/dev\/null \|\| true/ && !inserted {
				print
				print "\t\t\thotdog_rescue_watchdog_log \"requesting bootloader through RESTART2\""
				print "\t\t\tif /hotdog-reboot-mode bootloader; then"
				print "\t\t\t\texit 0"
				print "\t\t\tfi"
				print "\t\t\thotdog_rescue_watchdog_log \"RESTART2 failed; falling back to normal reboot\""
				inserted = 1
				next
			}
			{ print }
			END {
				if (!inserted)
					exit 42
			}
		' > "$watchdog_override"
	chmod 0755 "$watchdog_override"
	cat >> "$list_file" <<EOF
file /hotdog-reboot-mode $REBOOT_MODE_HELPER 0755 0 0
file /hotdog_rescue_watchdog.sh $watchdog_override 0755 0 0
EOF
fi

if [ "$SUPPRESS_FB_PAINT" -eq 1 ]; then
	cat > "$fb_test_override" <<'FB_TEST_OVERRIDE'
#!/bin/busybox ash

hotdog_fb_test_log() {
	local msg="$*"
	if [ -e /dev/kmsg ]; then
		printf '%s\n' "[hotdog-fb-test] $msg" > /dev/kmsg 2>/dev/null || true
	fi
	printf '%s\n' "[hotdog-fb-test] $msg" 2>/dev/null || true
}

hotdog_fb_test_dev() {
	local dev
	for dev in /dev/fb0 /dev/graphics/fb0; do
		[ -e "$dev" ] || continue
		printf '%s\n' "$dev"
		return 0
	done
	return 1
}

hotdog_fb_test_start() {
	local stage="${1:-unknown}"

	[ -e /tmp/hotdog_fb_test.started ] && return 0
	: > /tmp/hotdog_fb_test.started 2>/dev/null || true

	(
		waited=0
		while [ "$waited" -lt 45 ]; do
			if hotdog_fb_test_dev >/dev/null 2>&1; then
				hotdog_fb_test_log "fb0 appeared at stage=$stage after ${waited}s; wait-only mode"
				: > /tmp/hotdog_fb_test.ok 2>/dev/null || true
				exit 0
			fi
			sleep 1
			waited=$((waited + 1))
		done
		hotdog_fb_test_log "no framebuffer appeared by stage=$stage"
	) &
}
FB_TEST_OVERRIDE
	chmod 0755 "$fb_test_override"
	printf 'file /hotdog_fb_test.sh %s 0755 0 0\n' "$fb_test_override" >> "$list_file"
fi

gen_init_cpio_log="$OUTDIR/gen-init-cpio.txt"
if ! "$GEN_INIT_CPIO" -t 0 "$list_file" > "$overlay" 2> "$gen_init_cpio_log"; then
	printf 'gen_init_cpio failed; see %s\n' "$gen_init_cpio_log" >&2
	exit 1
fi
if grep -Eq '^(ERROR:|unknown file type|File .* could not be opened)' \
		"$gen_init_cpio_log"; then
	cat "$gen_init_cpio_log" >&2
	exit 1
fi
[ -s "$overlay" ] || {
	printf 'gen_init_cpio produced an empty overlay\n' >&2
	exit 1
}
cp "$BASE_CPIO" "$output"
cat "$overlay" >> "$output"
gzip -9n -c "$output" > "$output_gzip"

cpio -it < "$BASE_CPIO" >/dev/null 2> "$OUTDIR/base-cpio-verify.txt"
cpio -it < "$overlay" > "$OUTDIR/overlay-contents.txt" 2> "$OUTDIR/overlay-cpio-verify.txt"
grep -qx 'hotdog-mainline-wrapper' "$OUTDIR/overlay-contents.txt"
if [ "$SUPPRESS_FB_PAINT" -eq 1 ]; then
	grep -qx 'hotdog_fb_test.sh' "$OUTDIR/overlay-contents.txt"
	grep -q 'wait-only mode' "$fb_test_override"
	if grep -Eq 'hotdog_fb_test_fill|color=(red|green|blue|white)' "$fb_test_override"; then
		printf 'Framebuffer paint override still contains RGB paint code\n' >&2
		exit 1
	fi
fi
if [ "$USERSPACE_FB_MARKER" -eq 1 ]; then
	grep -qx 'dev/zero' "$OUTDIR/overlay-contents.txt"
	grep -qx 'dev/fb0' "$OUTDIR/overlay-contents.txt"
	grep -qx 'hotdog-userspace-fb-marker' "$OUTDIR/overlay-contents.txt"
	grep -qx 'hooks/01-hotdog-userspace-fb-marker.sh' "$OUTDIR/overlay-contents.txt"
	grep -qx 'hooks-cleanup/01-hotdog-userspace-root-marker.sh' \
		"$OUTDIR/overlay-contents.txt"
	grep -a -q 'wrapper-entry' "$wrapper"
	grep -a -q 'wrapper-exec-init' "$wrapper"
fi
if [ -n "$REBOOT_MODE_HELPER" ]; then
	grep -qx 'hotdog-reboot-mode' "$OUTDIR/overlay-contents.txt"
	grep -qx 'hotdog_rescue_watchdog.sh' "$OUTDIR/overlay-contents.txt"
	grep -q 'requesting bootloader through RESTART2' "$watchdog_override"
	grep -q '/hotdog-reboot-mode bootloader' "$watchdog_override"
fi
file "$BASE_CPIO" "$overlay" "$output" "$output_gzip" > "$OUTDIR/file-report.txt"
sha256sum "$BASE_CPIO" "$overlay" "$output" "$output_gzip" > "$OUTDIR/SHA256SUMS"

printf 'Output directory: %s\n' "$OUTDIR"
printf 'Wrapped raw initramfs: %s\n' "$output"
printf 'Wrapped gzip initramfs: %s\n' "$output_gzip"
printf 'Inherited framebuffer paint probe suppressed: %s\n' "$SUPPRESS_FB_PAINT"
printf 'Large userspace framebuffer marker: %s\n' "$USERSPACE_FB_MARKER"
printf 'Prebuilt wrapper binary: %s\n' "${WRAPPER_BINARY:-none}"
printf 'RESTART2 rescue helper: %s\n' "${REBOOT_MODE_HELPER:-none}"
printf 'Raw size: %s bytes\n' "$(stat -c %s "$output")"
cat "$OUTDIR/SHA256SUMS"
