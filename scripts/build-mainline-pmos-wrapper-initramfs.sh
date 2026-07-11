#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/env.sh"

BASE_CPIO="$HOTDOG_ROOT/build/experiments/2026-07-11-110300-mainline617-pmos-r5-raw-initramfs/initramfs-pmos-r5.cpio"
GEN_INIT_CPIO="$HOTDOG_ROOT/build/experiments/2026-07-10-mainline617-psci-entry-reset-src/usr/gen_init_cpio"
OUTDIR=""
SUPPRESS_FB_PAINT=1

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
  -h, --help            Show this help.
USAGE
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--base-cpio) BASE_CPIO="$2"; shift ;;
		--gen-init-cpio) GEN_INIT_CPIO="$2"; shift ;;
		--outdir) OUTDIR="$2"; shift ;;
		--keep-fb-paint) SUPPRESS_FB_PAINT=0 ;;
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
file "$BASE_CPIO" | grep -q 'cpio archive' || {
	printf 'Base file is not an uncompressed CPIO archive: %s\n' "$BASE_CPIO" >&2
	exit 2
}

mkdir -p "$OUTDIR"
wrapper="$OUTDIR/hotdog-mainline-wrapper"
fb_test_override="$OUTDIR/hotdog_fb_test.sh"
list_file="$OUTDIR/wrapper.list"
overlay="$OUTDIR/wrapper-overlay.cpio"
output="$OUTDIR/initramfs-pmos-wrapped.cpio"
output_gzip="$OUTDIR/initramfs-pmos-wrapped.cpio.gz"

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
exec /init "$@"
WRAPPER
chmod 0755 "$wrapper"

cat > "$list_file" <<EOF
file /hotdog-mainline-wrapper $wrapper 0755 0 0
EOF

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

"$GEN_INIT_CPIO" -t 0 "$list_file" > "$overlay"
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
file "$BASE_CPIO" "$overlay" "$output" "$output_gzip" > "$OUTDIR/file-report.txt"
sha256sum "$BASE_CPIO" "$overlay" "$output" "$output_gzip" > "$OUTDIR/SHA256SUMS"

printf 'Output directory: %s\n' "$OUTDIR"
printf 'Wrapped raw initramfs: %s\n' "$output"
printf 'Wrapped gzip initramfs: %s\n' "$output_gzip"
printf 'Inherited framebuffer paint probe suppressed: %s\n' "$SUPPRESS_FB_PAINT"
printf 'Raw size: %s bytes\n' "$(stat -c %s "$output")"
cat "$OUTDIR/SHA256SUMS"
