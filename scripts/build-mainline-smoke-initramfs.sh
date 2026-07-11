#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/env.sh"

SOURCE_TREE="$HOTDOG_ROOT/images/pmos-experiments/2026-07-11-130500-lineage414-r5-kexec-fbwait-nopaint-acm-rootwatchdog/initramfs-tree"
BUSYBOX=""
BUSYBOX_EXTRAS=""
MUSL_LOADER=""
GEN_INIT_CPIO="$HOTDOG_ROOT/build/experiments/2026-07-10-mainline617-psci-entry-reset-src/usr/gen_init_cpio"
OUTDIR=""

usage() {
	cat <<'USAGE'
Usage: build-mainline-smoke-initramfs.sh [options]

Build a minimal arm64 initramfs for proving that mainline reaches userspace.
The raw newc archive avoids testing a decompressor at the same time.

Options:
  --source-tree DIR    Existing arm64 initramfs tree used for BusyBox and musl.
  --busybox FILE       Override the arm64 BusyBox binary.
  --busybox-extras FILE
                       Override the arm64 BusyBox extras binary.
  --musl-loader FILE   Override ld-musl-aarch64.so.1.
  --gen-init-cpio FILE Override the kernel gen_init_cpio helper.
  --outdir DIR         Output directory. Defaults below build/experiments.
  -h, --help           Show this help.
USAGE
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--source-tree) SOURCE_TREE="$2"; shift ;;
		--busybox) BUSYBOX="$2"; shift ;;
		--busybox-extras) BUSYBOX_EXTRAS="$2"; shift ;;
		--musl-loader) MUSL_LOADER="$2"; shift ;;
		--gen-init-cpio) GEN_INIT_CPIO="$2"; shift ;;
		--outdir) OUTDIR="$2"; shift ;;
		-h|--help) usage; exit 0 ;;
		*) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
	esac
	shift
done

BUSYBOX="${BUSYBOX:-$SOURCE_TREE/bin/busybox}"
BUSYBOX_EXTRAS="${BUSYBOX_EXTRAS:-$SOURCE_TREE/usr/bin/busybox-extras}"
MUSL_LOADER="${MUSL_LOADER:-$SOURCE_TREE/usr/lib/ld-musl-aarch64.so.1}"
OUTDIR="${OUTDIR:-$HOTDOG_ROOT/build/experiments/$(date +%F-%H%M%S)-mainline617-smoke-initramfs}"

for command_name in file gzip readelf sha256sum; do
	command -v "$command_name" >/dev/null 2>&1 || {
		printf 'Missing command: %s\n' "$command_name" >&2
		exit 127
	}
done

for input in "$BUSYBOX" "$BUSYBOX_EXTRAS" "$MUSL_LOADER" "$GEN_INIT_CPIO"; do
	[ -s "$input" ] || {
		printf 'Missing input: %s\n' "$input" >&2
		exit 2
	}
done
[ -x "$GEN_INIT_CPIO" ] || {
	printf 'gen_init_cpio is not executable: %s\n' "$GEN_INIT_CPIO" >&2
	exit 2
}

file "$BUSYBOX" | grep -q 'ARM aarch64' || {
	printf 'BusyBox is not an aarch64 executable: %s\n' "$BUSYBOX" >&2
	exit 2
}
readelf -d "$BUSYBOX" | grep -q 'libc.musl-aarch64.so.1' || {
	printf 'BusyBox does not use the expected aarch64 musl runtime: %s\n' "$BUSYBOX" >&2
	exit 2
}
file "$BUSYBOX_EXTRAS" | grep -q 'ARM aarch64' || {
	printf 'BusyBox extras is not an aarch64 executable: %s\n' "$BUSYBOX_EXTRAS" >&2
	exit 2
}
readelf -d "$BUSYBOX_EXTRAS" | grep -q 'libc.musl-aarch64.so.1' || {
	printf 'BusyBox extras does not use the expected aarch64 musl runtime: %s\n' "$BUSYBOX_EXTRAS" >&2
	exit 2
}

mkdir -p "$OUTDIR"
init_file="$OUTDIR/init"
list_file="$OUTDIR/initramfs.list"
raw_archive="$OUTDIR/initramfs-smoke.cpio"
gzip_archive="$OUTDIR/initramfs-smoke.cpio.gz"

cat > "$init_file" <<'INIT'
#!/bin/busybox ash

bb=/bin/busybox
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
export HOME=/root
export TERM=linux

$bb mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
$bb mount -t proc proc /proc 2>/dev/null || true
$bb mount -t sysfs sysfs /sys 2>/dev/null || true
$bb mount -t tmpfs tmpfs /run 2>/dev/null || true
$bb mount -t tmpfs tmpfs /tmp 2>/dev/null || true

if [ -c /dev/console ]; then
	exec </dev/console >/dev/console 2>&1
fi

marker='HOTDOG_MAINLINE_INIT_REACHED'
printf '\n%s\n' "$marker"
printf '%s\n' "$marker" >/dev/tty0 2>/dev/null || true
printf '<6>%s\n' "$marker" >/dev/kmsg 2>/dev/null || true
printf '<6>HOTDOG_MAINLINE_CMDLINE: %s\n' "$(cat /proc/cmdline 2>/dev/null)" >/dev/kmsg 2>/dev/null || true

panic_sec=''
for parameter in $($bb cat /proc/cmdline 2>/dev/null); do
	case "$parameter" in
		hotdog_smoke_panic_sec=*) panic_sec="${parameter#*=}" ;;
	esac
done
case "$panic_sec" in
	''|*[!0-9]*) ;;
	*)
		(
			printf '<6>HOTDOG_MAINLINE_PANIC_ARMED=%s\n' "$panic_sec" >/dev/kmsg 2>/dev/null || true
			$bb sleep "$panic_sec"
			if [ -e /run/hotdog-usb-ready ]; then
				printf '<6>HOTDOG_MAINLINE_PANIC_CANCELLED_USB_READY\n' >/dev/kmsg 2>/dev/null || true
				exit 0
			fi
			printf '<0>HOTDOG_MAINLINE_CONTROLLED_PANIC\n' >/dev/kmsg 2>/dev/null || true
			printf '1\n' >/proc/sys/kernel/sysrq 2>/dev/null || true
			printf 'c\n' >/proc/sysrq-trigger 2>/dev/null || $bb reboot -f
		) &
		printf '%s\n' "$!" > /run/hotdog-panic.pid
		;;
esac

$bb mkdir -p /sys/kernel/config
if [ ! -d /sys/kernel/config/usb_gadget ]; then
	$bb mount -t configfs configfs /sys/kernel/config 2>/dev/null || true
fi

gadget=/sys/kernel/config/usb_gadget/hotdog
if [ -d /sys/kernel/config/usb_gadget ]; then
	$bb mkdir -p "$gadget/strings/0x409"
	$bb mkdir -p "$gadget/configs/c.1/strings/0x409"
	printf '0x18d1\n' > "$gadget/idVendor" 2>/dev/null || true
	printf '0xd002\n' > "$gadget/idProduct" 2>/dev/null || true
	printf '0x0200\n' > "$gadget/bcdUSB" 2>/dev/null || true
	printf '0x0100\n' > "$gadget/bcdDevice" 2>/dev/null || true
	printf 'postmarketOS-mainline\n' > "$gadget/strings/0x409/serialnumber" 2>/dev/null || true
	printf 'OnePlus\n' > "$gadget/strings/0x409/manufacturer" 2>/dev/null || true
	printf 'OnePlus 7T Pro mainline\n' > "$gadget/strings/0x409/product" 2>/dev/null || true
	printf 'NCM and ACM rescue\n' > "$gadget/configs/c.1/strings/0x409/configuration" 2>/dev/null || true
	printf '250\n' > "$gadget/configs/c.1/MaxPower" 2>/dev/null || true

	$bb mkdir -p "$gadget/functions/ncm.usb0" 2>/dev/null || true
	$bb mkdir -p "$gadget/functions/acm.GS0" 2>/dev/null || true
	[ -e "$gadget/configs/c.1/ncm.usb0" ] ||
		$bb ln -s "$gadget/functions/ncm.usb0" "$gadget/configs/c.1/ncm.usb0" 2>/dev/null || true
	[ -e "$gadget/configs/c.1/acm.GS0" ] ||
		$bb ln -s "$gadget/functions/acm.GS0" "$gadget/configs/c.1/acm.GS0" 2>/dev/null || true

	udc=''
	wait_count=0
	while [ -z "$udc" ] && [ "$wait_count" -lt 60 ]; do
		for candidate in /sys/class/udc/*; do
			[ -e "$candidate" ] || continue
			udc="${candidate##*/}"
			break
		done
		[ -n "$udc" ] && break
		wait_count=$((wait_count + 1))
		[ $((wait_count % 5)) -ne 0 ] ||
			printf '<6>HOTDOG_MAINLINE_USB_WAIT_UDC=%s\n' "$wait_count" >/dev/kmsg 2>/dev/null || true
		$bb sleep 1
	done

	if [ -n "$udc" ]; then
		printf '<6>HOTDOG_MAINLINE_USB_UDC=%s\n' "$udc" >/dev/kmsg 2>/dev/null || true
		printf '%s\n' "$udc" > "$gadget/UDC" 2>/dev/null || true
		$bb mdev -s 2>/dev/null || true

		(
			while [ ! -c /dev/ttyGS0 ]; do
				$bb mdev -s 2>/dev/null || true
				$bb sleep 1
			done
			while :; do
				$bb setsid $bb sh -c '
					export PATH=/bin:/sbin:/usr/bin:/usr/sbin HOME=/root TERM=vt100
					printf "\nmainline ACM shell ready\n"
					exec /bin/busybox sh
				' </dev/ttyGS0 >/dev/ttyGS0 2>&1
				$bb sleep 1
			done
		) &

		net_wait=0
		while [ ! -e /sys/class/net/usb0 ] && [ "$net_wait" -lt 30 ]; do
			net_wait=$((net_wait + 1))
			$bb sleep 1
		done
		if [ -e /sys/class/net/usb0 ]; then
			$bb ip link set usb0 up 2>/dev/null || true
			$bb ip addr add 172.16.42.1/24 dev usb0 2>/dev/null || true
			/usr/bin/busybox-extras telnetd -F -b 172.16.42.1:23 -l /bin/sh \
				>/run/hotdog-telnetd.log 2>&1 &
			/usr/bin/busybox-extras tcpsvd -E 172.16.42.1 2323 /bin/sh \
				>/run/hotdog-tcpsvd.log 2>&1 &
			printf '%s\n' "$udc" > /run/hotdog-usb-ready
			printf '<6>HOTDOG_MAINLINE_USB_NETWORK_READY=172.16.42.1\n' >/dev/kmsg 2>/dev/null || true
		fi
	else
		printf '<3>HOTDOG_MAINLINE_USB_NO_UDC\n' >/dev/kmsg 2>/dev/null || true
	fi
else
	printf '<3>HOTDOG_MAINLINE_USB_NO_CONFIGFS\n' >/dev/kmsg 2>/dev/null || true
fi

if [ -c /dev/tty0 ]; then
	(
		while :; do
			$bb setsid $bb sh -c '
				export PATH=/bin:/sbin:/usr/bin:/usr/sbin HOME=/root TERM=linux
				printf "\nmainline smoke shell ready\n"
				exec /bin/busybox sh
			' </dev/tty0 >/dev/tty0 2>&1
			$bb sleep 1
		done
	) &
fi

heartbeat=0
while :; do
	printf '<6>HOTDOG_MAINLINE_INIT_HEARTBEAT=%s\n' "$heartbeat" >/dev/kmsg 2>/dev/null || true
	heartbeat=$((heartbeat + 1))
	$bb sleep 5
done
INIT
chmod 0755 "$init_file"

cat > "$list_file" <<EOF
dir /bin 0755 0 0
file /bin/busybox $BUSYBOX 0755 0 0
slink /bin/sh busybox 0777 0 0
dir /sbin 0755 0 0
slink /sbin/init /init 0777 0 0
dir /usr 0755 0 0
dir /usr/bin 0755 0 0
file /usr/bin/busybox-extras $BUSYBOX_EXTRAS 0755 0 0
dir /usr/lib 0755 0 0
file /usr/lib/ld-musl-aarch64.so.1 $MUSL_LOADER 0755 0 0
slink /usr/lib/libc.musl-aarch64.so.1 ld-musl-aarch64.so.1 0777 0 0
slink /lib usr/lib 0777 0 0
dir /dev 0755 0 0
nod /dev/console 0600 0 0 c 5 1
nod /dev/null 0666 0 0 c 1 3
nod /dev/kmsg 0600 0 0 c 1 11
nod /dev/tty0 0600 0 0 c 4 0
dir /proc 0555 0 0
dir /sys 0555 0 0
dir /run 0755 0 0
dir /tmp 01777 0 0
dir /root 0700 0 0
file /init $init_file 0755 0 0
EOF

"$GEN_INIT_CPIO" -t 0 "$list_file" > "$raw_archive"
gzip -9n -c "$raw_archive" > "$gzip_archive"

file "$raw_archive" "$gzip_archive" "$BUSYBOX" "$BUSYBOX_EXTRAS" "$MUSL_LOADER" > "$OUTDIR/file-report.txt"
sha256sum "$raw_archive" "$gzip_archive" "$BUSYBOX" "$BUSYBOX_EXTRAS" "$MUSL_LOADER" > "$OUTDIR/SHA256SUMS"

printf 'Output directory: %s\n' "$OUTDIR"
printf 'Raw initramfs:    %s\n' "$raw_archive"
printf 'Gzip initramfs:   %s\n' "$gzip_archive"
printf 'Raw size:         %s bytes\n' "$(stat -c %s "$raw_archive")"
printf 'Gzip size:        %s bytes\n' "$(stat -c %s "$gzip_archive")"
cat "$OUTDIR/SHA256SUMS"
