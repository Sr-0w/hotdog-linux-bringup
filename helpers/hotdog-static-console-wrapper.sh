#!/bin/busybox ash

# Keep this wrapper self-contained: it is PID 1 in the postmarketOS initramfs.
bb=/bin/busybox
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
export HOME=/root
export TERM=linux

$bb mkdir -p /dev /proc /sys /run /tmp
$bb mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
$bb mount -t proc proc /proc 2>/dev/null || true
$bb mount -t sysfs sysfs /sys 2>/dev/null || true

tty=/dev/tty0
[ -c "$tty" ] || tty=/dev/console
exec <"$tty" >"$tty" 2>&1

# Preserve the verbose boot in RAM, then stop new kernel messages from
# disturbing the static geometry test and the rescue shell below.
$bb dmesg > /tmp/hotdog-v31-dmesg.txt 2>/dev/null || true
{
	printf 'variant=V31-static-console\n'
	for attribute in name modes virtual_size stride bits_per_pixel; do
		path="/sys/class/graphics/fb0/$attribute"
		[ -r "$path" ] && printf '%s=%s\n' "$attribute" "$($bb cat "$path")"
	done
} > /tmp/hotdog-v31-display.txt 2>/dev/null
printf '1 1 1 1\n' > /proc/sys/kernel/printk 2>/dev/null || true

cursor()
{
	printf '\033[%s;%sH' "$1" "$2"
}

paint_band()
{
	row="$1"
	color="$2"
	end=$((row + 7))
	while [ "$row" -le "$end" ]; do
		cursor "$row" 6
		printf '\033[%sm%160s\033[0;37;40m' "$color" ''
		row=$((row + 1))
	done
}

# A non-scrolling image with unique markers at known framebuffer rows. If a
# marker is duplicated or displaced, the fault is in scanout rather than fbcon
# scrolling. The large bands remain legible through the test webcam.
printf '\033c\033[2J\033[H\033[0;37;40m'
cursor 2 6
printf 'HOTDOG V31 - NATIVE MAINLINE STATIC DISPLAY TEST'
cursor 3 6
printf 'No scrolling. Five unique bands span the 1440x3120 framebuffer.'

cursor 5 6
printf 'A / TOP / ROW 006 / RED'
paint_band 6 41

cursor 43 6
printf 'B / QUARTER 1 / ROW 044 / GREEN'
paint_band 44 42

cursor 88 6
printf 'C / MIDDLE / ROW 089 / CYAN'
paint_band 89 46

cursor 133 6
printf 'D / QUARTER 3 / ROW 134 / YELLOW'
paint_band 134 43

cursor 177 6
printf 'E / BOTTOM / ROW 178 / MAGENTA'
paint_band 178 45

cursor 188 6
printf 'Kernel log: /tmp/hotdog-v31-dmesg.txt'
cursor 189 6
printf 'Framebuffer info: /tmp/hotdog-v31-display.txt'
cursor 191 6
printf 'Initramfs shell is alive on tty0.'
cursor 193 1
printf '\033[0;37;40m\033[?25h'

export PS1='hotdog-v31:/ # '
cd /
exec "$bb" ash -i
