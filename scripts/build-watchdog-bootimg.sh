#!/usr/bin/env bash
set -euo pipefail

usage() {
	cat <<'EOF'
Usage: build-watchdog-bootimg.sh [options]

Build a hotdog no-EFI Android boot image candidate from the current no-EFI
postmarketOS experiment, with an early initramfs rescue watchdog.

No adb, fastboot, scrcpy, USB reset, or phone command is used.

Options:
  --watchdog-sec N   Append hotdog_rescue_watchdog_sec=N to the boot cmdline.
                     Default: 90
  --watchdog-success MODE
                     Success condition for the rescue watchdog:
                     usb  = current behavior, USB gadget or later stage.
                     root = require root mount or switch-root.
                     Default: usb
  --source-boot IMG  Source Android boot image. Default:
                     $HOTDOG_STABLE_PMOS_BOOT_B
  --kernel FILE      Override the kernel payload extracted from source boot.
  --dtb FILE         Override the DTB payload extracted from source boot.
  --extra-cmdline S  Extra kernel cmdline text appended after the source
                     cmdline and before hotdog_rescue_watchdog_sec=N.
  --with-ramoops-cmdline
                     Append pstore/ramoops capture args, replacing any
                     existing values for the same cmdline keys.
  --direct-debug-shell
                     Start a direct telnet shell on 172.16.42.1:23 after
                     USB networking, without relying on the pmOS debug hook.
  --fb-test
                     Paint /dev/fb0 from initramfs when it appears. This is
                     an opt-in visual diagnostic for simplefb/fbcon bring-up.
  --drm-console
                     Start a DRM text console from initramfs as soon as
                     /dev/dri/card0 appears, then stop it before switch_root.
  --drm-console-userspace
                     Install a persistent OpenRC local.d DRM command console
                     into the mounted rootfs before switch_root. Implies
                     --drm-console.
  --tty-kmsg-console
                     Start an initramfs /dev/tty0 dmesg/status follower before
                     the DRM helper, to test simplefb/fbcon screen output.
  --visible-tty-shell
                     Install an OpenRC local.d shell/status follower on tty1
                     after switch_root, for screen-only rootfs diagnostics.
  --drm-console-helper FILE
                     AArch64 hotdog-drm-console binary to inject. Default:
                     $HOTDOG_ROOT/build/hotdog-drm-console-aarch64.
  --strip-drm-console
                     Remove inherited hotdog DRM console hooks from the source
                     initramfs before adding this candidate's hooks. Useful for
                     fbcon-only isolation tests built from a DRM-console source.
  --os-version V     Set Android boot image OS version, e.g. 15.0.0.
  --os-patch-level D Set Android boot image patch level, e.g. 2025-08.
  --base HEX         Android boot image base address. Default: 0x00000000
  --kernel-offset HEX
                     Android boot image kernel offset. Default: 0x00008000
  --ramdisk-offset HEX
                     Android boot image ramdisk offset. Default: 0x01000000
  --second-offset HEX
                     Android boot image second offset. Default: 0x00000000
  --tags-offset HEX  Android boot image tags offset. Default: 0x00000100
  --dtb-offset HEX   Android boot image DTB offset. Default: 0x01f00000
  --outdir DIR       New artifact directory under images/pmos-experiments/.
                     Default: timestamped *-noefi-watchdog directory
  -h, --help         Show this help.
EOF
}

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

note() {
	printf '[build-watchdog-bootimg] %s\n' "$*"
}

require_file() {
	local path="$1"
	[ -f "$path" ] || die "missing required file: $path"
}

require_cmd() {
	local cmd="$1"
	command -v "$cmd" >/dev/null 2>&1 || die "missing required command: $cmd"
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/env.sh"

source_boot_default="$HOTDOG_STABLE_PMOS_BOOT_B"
source_boot="$source_boot_default"
kernel_override=""
dtb_override=""
watchdog_sec="90"
watchdog_success="usb"
extra_cmdline=""
with_ramoops_cmdline=0
direct_debug_shell=0
fb_test=0
drm_console=0
drm_console_userspace=0
tty_kmsg_console=0
visible_tty_shell=0
strip_drm_console=0
default_drm_console_helper="$HOTDOG_ROOT/build/hotdog-drm-console-aarch64"
drm_console_helper="$default_drm_console_helper"
os_version=""
os_patch_level=""
outdir=""
ramoops_cmdline="printk.always_kmsg_dump=1 ramoops.mem_address=0xa9800000 ramoops.mem_size=0x400000 ramoops.record_size=0x40000 ramoops.console_size=0x40000 ramoops.ftrace_size=0x40000 ramoops.pmsg_size=0x200000 ramoops.ecc=0"
boot_base="0x00000000"
kernel_offset="0x00008000"
ramdisk_offset="0x01000000"
second_offset="0x00000000"
tags_offset="0x00000100"
dtb_offset="0x01f00000"

while [ "$#" -gt 0 ]; do
	case "$1" in
		--watchdog-sec)
			[ "$#" -ge 2 ] || die "--watchdog-sec requires a value"
			watchdog_sec="$2"
			shift
			;;
		--watchdog-success)
			[ "$#" -ge 2 ] || die "--watchdog-success requires a value"
			watchdog_success="$2"
			shift
			;;
		--source-boot)
			[ "$#" -ge 2 ] || die "--source-boot requires a path"
			source_boot="$2"
			shift
			;;
		--kernel)
			[ "$#" -ge 2 ] || die "--kernel requires a file"
			kernel_override="$2"
			shift
			;;
		--dtb)
			[ "$#" -ge 2 ] || die "--dtb requires a file"
			dtb_override="$2"
			shift
			;;
		--extra-cmdline)
			[ "$#" -ge 2 ] || die "--extra-cmdline requires a string"
			extra_cmdline="$2"
			shift
			;;
		--with-ramoops-cmdline)
			with_ramoops_cmdline=1
			;;
		--direct-debug-shell)
			direct_debug_shell=1
			;;
		--fb-test)
			fb_test=1
			;;
		--drm-console)
			drm_console=1
			;;
		--drm-console-userspace)
			drm_console=1
			drm_console_userspace=1
			;;
		--tty-kmsg-console)
			tty_kmsg_console=1
			;;
		--visible-tty-shell)
			visible_tty_shell=1
			;;
		--drm-console-helper)
			[ "$#" -ge 2 ] || die "--drm-console-helper requires a file"
			drm_console_helper="$2"
			shift
			;;
		--strip-drm-console)
			strip_drm_console=1
			;;
		--os-version)
			[ "$#" -ge 2 ] || die "--os-version requires a value"
			os_version="$2"
			shift
			;;
		--os-patch-level)
			[ "$#" -ge 2 ] || die "--os-patch-level requires a value"
			os_patch_level="$2"
			shift
			;;
		--base)
			[ "$#" -ge 2 ] || die "--base requires a value"
			boot_base="$2"
			shift
			;;
		--kernel-offset)
			[ "$#" -ge 2 ] || die "--kernel-offset requires a value"
			kernel_offset="$2"
			shift
			;;
		--ramdisk-offset)
			[ "$#" -ge 2 ] || die "--ramdisk-offset requires a value"
			ramdisk_offset="$2"
			shift
			;;
		--second-offset)
			[ "$#" -ge 2 ] || die "--second-offset requires a value"
			second_offset="$2"
			shift
			;;
		--tags-offset)
			[ "$#" -ge 2 ] || die "--tags-offset requires a value"
			tags_offset="$2"
			shift
			;;
		--dtb-offset)
			[ "$#" -ge 2 ] || die "--dtb-offset requires a value"
			dtb_offset="$2"
			shift
			;;
		--outdir)
			[ "$#" -ge 2 ] || die "--outdir requires a path"
			outdir="$2"
			shift
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			die "unknown argument: $1"
			;;
	esac
	shift
done

case "$watchdog_sec" in
	""|*[!0-9]*)
		die "--watchdog-sec must be a positive integer"
		;;
esac
[ "$watchdog_sec" -gt 0 ] || die "--watchdog-sec must be greater than zero"
case "$watchdog_success" in
	usb|root)
		;;
	*)
		die "--watchdog-success must be one of: usb, root"
		;;
esac
for boot_hex in "$boot_base" "$kernel_offset" "$ramdisk_offset" "$second_offset" "$tags_offset" "$dtb_offset"; do
	case "$boot_hex" in
		0x[0-9a-fA-F]*)
			;;
		*)
			die "boot header address/offset values must be hexadecimal with 0x prefix: $boot_hex"
			;;
	esac
done

require_file "$source_boot"
[ -z "$kernel_override" ] || require_file "$kernel_override"
[ -z "$dtb_override" ] || require_file "$dtb_override"
if [ "$drm_console" -eq 1 ]; then
	if [ ! -f "$drm_console_helper" ] && [ "$drm_console_helper" = "$default_drm_console_helper" ]; then
		"$script_dir/build-hotdog-drm-console-helper.sh" --output "$drm_console_helper"
	fi
	require_file "$drm_console_helper"
fi
require_file "$HOTDOG_BIN_ROOT/pmbootstrap"
require_file "$HOTDOG_PMBOOTSTRAP_CONFIG"
require_dir() {
	local path="$1"
	[ -d "$path" ] || die "missing required directory: $path"
}
require_dir "$HOTDOG_PMAPORTS_SM8150"
require_dir "$HOTDOG_PMBOOTSTRAP_WORK"

for cmd in awk cpio file find gzip mkdir sha256sum sort unpack_bootimg; do
	require_cmd "$cmd"
done

artifact_root="$HOTDOG_ROOT/images/pmos-experiments"
require_dir "$artifact_root"

if [ -z "$outdir" ]; then
	stamp="$(date +%Y-%m-%d-%H%M%S)"
	outdir="$artifact_root/${stamp}-noefi-watchdog"
fi

case "$outdir" in
	"$artifact_root"/*)
		;;
	*)
		die "--outdir must be a new directory below $artifact_root"
		;;
esac

[ ! -e "$outdir" ] || die "refusing to reuse existing artifact directory: $outdir"

components_dir="$outdir/components"
initramfs_tree="$outdir/initramfs-tree"
mkbootimg_dir="$outdir/mkbootimg"
verify_dir="$outdir/verify-unpack"
mkdir -p "$components_dir" "$initramfs_tree" "$mkbootimg_dir" "$verify_dir"

pmb=(
	"$HOTDOG_BIN_ROOT/pmbootstrap"
	-c "$HOTDOG_PMBOOTSTRAP_CONFIG"
	-p "$HOTDOG_PMAPORTS_SM8150"
	-w "$HOTDOG_PMBOOTSTRAP_WORK"
	-y
)

extract_field() {
	local field="$1"
	local file="$2"
	awk -v field="$field" -F': ' '$1 == field { print $2; exit }' "$file"
}

append_watchdog_cmdline() {
	local input="$1"
	local sec="$2"
	awk -v sec="$sec" '
		{
			out = ""
			for (i = 1; i <= NF; i++) {
				if ($i ~ /^hotdog_rescue_watchdog_sec=/) {
					continue
				}
				out = out ? out " " $i : $i
			}
			print out " hotdog_rescue_watchdog_sec=" sec
		}
	' <<EOF
$input
EOF
}

append_extra_cmdline() {
	local input="$1"
	local extra="$2"

	if [ -n "$extra" ]; then
		printf '%s %s\n' "$input" "$extra"
	else
		printf '%s\n' "$input"
	fi
}

append_dedup_keyed_cmdline() {
	local input="$1"
	local extra="$2"

	awk -v extra="$extra" '
		BEGIN {
			split(extra, extra_words, /[[:space:]]+/)
			for (i in extra_words) {
				if (extra_words[i] == "") {
					continue
				}
				key = extra_words[i]
				sub(/=.*/, "", key)
				replace[key] = 1
			}
		}
		{
			out = ""
			for (i = 1; i <= NF; i++) {
				key = $i
				sub(/=.*/, "", key)
				if (replace[key]) {
					continue
				}
				out = out ? out " " $i : $i
			}
			print out (out && extra ? " " : "") extra
		}
	' <<EOF
$input
EOF
}

replace_preserving_mode() {
	local tmp="$1"
	local file="$2"

	chmod --reference="$file" "$tmp"
	mv "$tmp" "$file"
}

insert_after_once() {
	local file="$1"
	local pattern="$2"
	local marker="$3"
	local snippet="$4"
	local tmp="$file.tmp.$$"

	grep -Fq "$marker" "$file" && return 0
	awk -v pattern="$pattern" -v snippet="$snippet" '
		{
			print
			if (!done && index($0, pattern)) {
				print snippet
				done = 1
			}
		}
		END {
			if (!done) {
				exit 42
			}
		}
	' "$file" > "$tmp" || {
		rm -f "$tmp"
		die "failed to inject after pattern '$pattern' in $file"
	}
	replace_preserving_mode "$tmp" "$file"
}

insert_before_once() {
	local file="$1"
	local pattern="$2"
	local marker="$3"
	local snippet="$4"
	local tmp="$file.tmp.$$"

	grep -Fq "$marker" "$file" && return 0
	awk -v pattern="$pattern" -v snippet="$snippet" '
		{
			if (!done && index($0, pattern)) {
				print snippet
				done = 1
			}
			print
		}
		END {
			if (!done) {
				exit 42
			}
		}
	' "$file" > "$tmp" || {
		rm -f "$tmp"
		die "failed to inject before pattern '$pattern' in $file"
	}
	replace_preserving_mode "$tmp" "$file"
}

write_watchdog_helper() {
	local helper="$initramfs_tree/hotdog_rescue_watchdog.sh"

cat > "$helper" <<'WATCHDOG_SH'
#!/bin/busybox ash

HOTDOG_RESCUE_WATCHDOG_SUCCESS_MODE="__HOTDOG_RESCUE_WATCHDOG_SUCCESS_MODE__"
HOTDOG_RESCUE_DIRECT_DEBUG_SHELL="__HOTDOG_RESCUE_DIRECT_DEBUG_SHELL__"

hotdog_rescue_watchdog_log() {
	local msg="$*"
	if [ -e /dev/kmsg ]; then
		printf '%s\n' "[hotdog-watchdog] $msg" > /dev/kmsg 2>/dev/null || true
	fi
	printf '%s\n' "[hotdog-watchdog] $msg" 2>/dev/null || true
}

hotdog_rescue_watchdog_cmdline_sec() {
	local word sec
	[ -r /proc/cmdline ] || return 1

	for word in $(cat /proc/cmdline); do
		case "$word" in
			hotdog_rescue_watchdog_sec=*)
				sec="${word#hotdog_rescue_watchdog_sec=}"
				;;
		esac
	done

	case "$sec" in
		""|*[!0-9]*)
			return 1
			;;
	esac

	[ "$sec" -gt 0 ] || return 1
	printf '%s\n' "$sec"
}

hotdog_rescue_watchdog_usb_seen() {
	local iface udc

	for iface in /sys/class/net/usb* /sys/class/net/rndis* /sys/class/net/enx* /sys/class/net/eth*; do
		[ -e "$iface" ] || continue
		[ "$(basename "$iface")" = "lo" ] && continue
		return 0
	done

	if [ -r /sys/kernel/config/usb_gadget/g1/UDC ]; then
		udc="$(cat /sys/kernel/config/usb_gadget/g1/UDC 2>/dev/null || true)"
		[ -n "$udc" ] && return 0
	fi

	for udc in /sys/class/udc/*; do
		[ -e "$udc" ] && return 0
	done

	return 1
}

hotdog_rescue_watchdog_success_seen() {
	[ -e /tmp/hotdog_rescue_watchdog.ok ] && return 0
	[ -e /tmp/hotdog_rescue_watchdog.switch-root ] && return 0
	[ -e /tmp/hotdog_rescue_watchdog.root-mounted ] && return 0

	if mountpoint -q /sysroot 2>/dev/null && [ -e /sysroot/etc/os-release ]; then
		return 0
	fi

	if [ "$HOTDOG_RESCUE_WATCHDOG_SUCCESS_MODE" = "usb" ]; then
		[ -e /tmp/hotdog_rescue_watchdog.usb-iface ] && return 0
		hotdog_rescue_watchdog_usb_seen && return 0
	fi

	return 1
}

hotdog_rescue_watchdog_mark() {
	local name="$1"
	mkdir -p /tmp 2>/dev/null || true
	: > "/tmp/hotdog_rescue_watchdog.$name" 2>/dev/null || true
	hotdog_rescue_watchdog_log "marker: $name"
}

hotdog_rescue_watchdog_mark_if_usb() {
	local name="$1"
	if hotdog_rescue_watchdog_usb_seen; then
		hotdog_rescue_watchdog_mark "usb-iface"
		hotdog_rescue_watchdog_log "usb marker from $name"
	fi
}

hotdog_rescue_direct_debug_shell_start() {
	[ "$HOTDOG_RESCUE_DIRECT_DEBUG_SHELL" = "1" ] || return 0
	[ -e /tmp/hotdog_rescue_direct_debug_shell.started ] && return 0
	: > /tmp/hotdog_rescue_direct_debug_shell.started 2>/dev/null || true

	cat > /README.hotdog-debug <<-EOF 2>/dev/null || true
	hotdog direct initramfs debug shell
	Useful commands:
	  cat /pmOS_init.log
	  cat /proc/cmdline
	  blkid
	  ls -l /dev/disk/by-uuid /dev/disk/by-partlabel /dev/mapper
	  mount
	  pmos_continue_boot
	EOF

	cat > /sbin/hotdog_debug_shell <<-'EOF' 2>/dev/null || true
	#!/bin/sh
	[ -r /etc/profile ] && . /etc/profile
	[ -r /README.hotdog-debug ] && cat /README.hotdog-debug
	exec /bin/sh -l
	EOF
	chmod +x /sbin/hotdog_debug_shell 2>/dev/null || true

	cat > /sbin/pmos_continue_boot <<-'EOF' 2>/dev/null || true
	#!/bin/sh
	echo "Continuing boot..."
	touch /tmp/continue_boot
	pkill -f 'telnetd.*:23' 2>/dev/null || true
	while sleep 1; do :; done
	EOF
	chmod +x /sbin/pmos_continue_boot 2>/dev/null || true

	hotdog_rescue_watchdog_log "starting direct telnet debug shell on ${HOST_IP:-172.16.42.1}:23"
	if [ -x /usr/bin/busybox-extras ]; then
		/usr/bin/busybox-extras telnetd -b "${HOST_IP:-172.16.42.1}:23" -l /sbin/hotdog_debug_shell >/tmp/hotdog_telnetd.log 2>&1 &
		/usr/bin/busybox-extras tcpsvd -E 0.0.0.0 2323 /sbin/hotdog_debug_shell >/tmp/hotdog_tcpsvd.log 2>&1 &
	else
		telnetd -b "${HOST_IP:-172.16.42.1}:23" -l /sbin/hotdog_debug_shell >/tmp/hotdog_telnetd.log 2>&1 &
	fi
}

hotdog_rescue_watchdog_try_modules() {
	local mod
	for mod in qcom_wdt pm8916_wdt; do
		if modprobe "$mod" >/dev/null 2>&1; then
			hotdog_rescue_watchdog_log "loaded module: $mod"
		else
			hotdog_rescue_watchdog_log "module unavailable or built-in: $mod"
		fi
	done
}

hotdog_rescue_watchdog_start() {
	local stage="$1"
	local sec

	[ -e /tmp/hotdog_rescue_watchdog.started ] && return 0

	sec="$(hotdog_rescue_watchdog_cmdline_sec)" || return 0
	mkdir -p /tmp 2>/dev/null || true
	: > /tmp/hotdog_rescue_watchdog.started 2>/dev/null || true

	hotdog_rescue_watchdog_log "armed at $stage for ${sec}s"
	hotdog_rescue_watchdog_try_modules
	if [ -w /proc/sys/kernel/sysrq ]; then
		echo 1 > /proc/sys/kernel/sysrq 2>/dev/null || true
	fi

	(
		slept=0
		while [ "$slept" -lt "$sec" ]; do
			if hotdog_rescue_watchdog_success_seen; then
				hotdog_rescue_watchdog_log "success marker seen before deadline"
				exit 0
			fi
			sleep 1
			slept=$((slept + 1))
		done

		if hotdog_rescue_watchdog_success_seen; then
			hotdog_rescue_watchdog_log "success marker seen at deadline"
			exit 0
		fi

		hotdog_rescue_watchdog_log "no ${HOTDOG_RESCUE_WATCHDOG_SUCCESS_MODE} success marker after ${sec}s; forcing reboot"
		sync 2>/dev/null || true
		reboot -f 2>/dev/null || true
		sleep 3
		hotdog_rescue_watchdog_log "reboot -f failed or returned; triggering sysrq panic"
		if [ -w /proc/sysrq-trigger ]; then
			echo c > /proc/sysrq-trigger
		fi
		hotdog_rescue_watchdog_log "sysrq panic trigger failed or unavailable"
	) &
}
WATCHDOG_SH
	sed -i "s/__HOTDOG_RESCUE_WATCHDOG_SUCCESS_MODE__/$watchdog_success/g" "$helper"
	sed -i "s/__HOTDOG_RESCUE_DIRECT_DEBUG_SHELL__/$direct_debug_shell/g" "$helper"
	chmod 0755 "$helper"
}

write_hotdog_super_loop_hook() {
	local hook_dir="$initramfs_tree/hooks"
	local hook="$hook_dir/00-hotdog-super-loop-fix.sh"

	mkdir -p "$hook_dir"
	cat > "$hook" <<'HOTDOG_SUPER_LOOP_SH'
#!/bin/busybox ash

log() {
	printf '%s\n' "[hotdog-super-loop] $*"
	[ -e /dev/kmsg ] && printf '%s\n' "[hotdog-super-loop] $*" > /dev/kmsg 2>/dev/null || true
}

ensure_basic_dev() {
	mkdir -p /dev /dev/block /dev/disk/by-partlabel /dev/disk/by-name /dev/disk/by-uuid /dev/mapper 2>/dev/null || true
	[ -e /dev/null ] || mknod /dev/null c 1 3 2>/dev/null || true
	[ -e /dev/zero ] || mknod /dev/zero c 1 5 2>/dev/null || true
	[ -e /dev/console ] || mknod /dev/console c 5 1 2>/dev/null || true
	[ -e /dev/ptmx ] || mknod /dev/ptmx c 5 2 2>/dev/null || true
	mdev -s >/tmp/hotdog-super-loop-mdev.log 2>&1 || true
}

seed_partition_symlinks() {
	local uevent devname partname major minor line key value

	for uevent in /sys/class/block/*/uevent; do
		[ -r "$uevent" ] || continue
		devname=""
		partname=""
		major=""
		minor=""
		while IFS='=' read -r key value; do
			case "$key" in
				DEVNAME) devname="$value" ;;
				PARTNAME) partname="$value" ;;
				MAJOR) major="$value" ;;
				MINOR) minor="$value" ;;
			esac
		done < "$uevent"
		[ -n "$devname" ] || continue
		if [ ! -b "/dev/$devname" ] && [ -n "$major" ] && [ -n "$minor" ]; then
			mknod "/dev/$devname" b "$major" "$minor" 2>/dev/null || true
		fi
		[ -n "$partname" ] || continue
		ln -sf "../../$devname" "/dev/disk/by-partlabel/$partname" 2>/dev/null || true
		ln -sf "../../$devname" "/dev/disk/by-name/$partname" 2>/dev/null || true
	done
}

find_super_partition() {
	local uevent devname partname key value

	for uevent in /sys/class/block/*/uevent; do
		[ -r "$uevent" ] || continue
		devname=""
		partname=""
		while IFS='=' read -r key value; do
			case "$key" in
				DEVNAME) devname="$value" ;;
				PARTNAME) partname="$value" ;;
			esac
		done < "$uevent"
		if [ "$partname" = "super" ] && [ -b "/dev/$devname" ]; then
			printf '%s\n' "/dev/$devname"
			return 0
		fi
	done

	[ -b /dev/disk/by-partlabel/super ] && printf '%s\n' /dev/disk/by-partlabel/super && return 0
	[ -b /dev/disk/by-name/super ] && printf '%s\n' /dev/disk/by-name/super && return 0
	return 1
}

partition_span_bytes() {
	local dev="$1"
	local partno="$2"
	local sector_size line start end

	sector_size="$(fdisk -l "$dev" 2>/dev/null | awk '/Logical sector size/ { print $4; exit }')"
	[ -n "$sector_size" ] || sector_size=512
	line="$(fdisk -l "$dev" 2>/dev/null | awk -v partno="$partno" '$1 == partno { print $2 " " $3; exit }')"
	[ -n "$line" ] || return 1
	set -- $line
	start="$1"
	end="$2"
	printf '%s %s\n' "$((start * sector_size))" "$(((end - start + 1) * sector_size))"
}

link_loop_identity() {
	local loop="$1"
	local info uuid label name

	[ -b "$loop" ] || return 1
	info="$(blkid -p "$loop" 2>/dev/null || true)"
	uuid="$(printf '%s\n' "$info" | sed -n 's/.*UUID="\([^"]*\)".*/\1/p')"
	label="$(printf '%s\n' "$info" | sed -n 's/.*LABEL="\([^"]*\)".*/\1/p')"
	name="${loop##*/}"

	[ -n "$uuid" ] && ln -sf "../../$name" "/dev/disk/by-uuid/$uuid" 2>/dev/null || true
	[ -n "$label" ] && ln -sf "../../$name" "/dev/disk/by-partlabel/$label" 2>/dev/null || true
	[ -n "$label" ] && ln -sf "../../$name" "/dev/disk/by-name/$label" 2>/dev/null || true
	log "$loop: ${label:-no-label} ${uuid:-no-uuid}"
}

create_offset_loop() {
	local super="$1"
	local partno="$2"
	local span offset size loop

	span="$(partition_span_bytes "$super" "$partno")" || return 1
	set -- $span
	offset="$1"
	size="$2"
	loop="$(losetup -f --show -o "$offset" --sizelimit "$size" "$super" 2>/dev/null)" || return 1
	printf '%s\n' "$loop"
}

grow_root_partition_to_super() {
	local super="$1"

	command -v parted >/dev/null 2>&1 || {
		log "parted missing; root GPT resize skipped"
		return 0
	}

	log "resizing nested pmOS_root partition to fill $super"
	if parted -f -s "$super" resizepart 2 100% >/tmp/hotdog-super-loop-resizepart.log 2>&1; then
		sync
	else
		log "resizepart failed or was unnecessary"
		sed -n '1,80p' /tmp/hotdog-super-loop-resizepart.log 2>/dev/null || true
	fi
}

ensure_basic_dev
seed_partition_symlinks

if blkid --label pmOS_root >/dev/null 2>&1 && blkid --label pmOS_boot >/dev/null 2>&1; then
	log "pmOS loop devices already visible"
	exit 0
fi

super="$(find_super_partition)" || {
	log "super partition not found; skipping"
	exit 0
}

if [ "$(fdisk -l "$super" 2>/dev/null | grep -cE '^ +[0-9]')" -ne 2 ]; then
	log "$super does not look like a two-partition pmOS image; skipping"
	exit 0
fi

log "creating offset loops from $super"
grow_root_partition_to_super "$super"
boot_loop="$(create_offset_loop "$super" 1)" || {
	log "failed to create boot loop"
	exit 0
}
root_loop="$(create_offset_loop "$super" 2)" || {
	log "failed to create root loop"
	exit 0
}

link_loop_identity "$boot_loop"
link_loop_identity "$root_loop"
HOTDOG_SUPER_LOOP_SH
	chmod 0755 "$hook"
}

write_hotdog_rootfs_postmount_helper() {
	local helper="$initramfs_tree/hotdog_rootfs_postmount.sh"

	cat > "$helper" <<'HOTDOG_ROOTFS_POSTMOUNT_SH'
#!/bin/busybox ash

log() {
	printf '%s\n' "[hotdog-rootfs-postmount] $*"
	[ -e /dev/kmsg ] && printf '%s\n' "[hotdog-rootfs-postmount] $*" > /dev/kmsg 2>/dev/null || true
}

[ -d /sysroot/etc ] || exit 0

mkdir -p /sysroot/etc/local.d /sysroot/dev/pts 2>/dev/null || true
ln -sf pts/ptmx /sysroot/dev/ptmx 2>/dev/null || true

cat > /sysroot/etc/local.d/hotdog-ptmx.start <<'EOF' 2>/dev/null || true
#!/bin/sh
mkdir -p /dev/pts
mount -o remount,ptmxmode=666 /dev/pts 2>/dev/null || \
	mount -t devpts -o gid=5,mode=620,ptmxmode=666 devpts /dev/pts 2>/dev/null || true
ln -sf pts/ptmx /dev/ptmx 2>/dev/null || true
EOF
chmod 0755 /sysroot/etc/local.d/hotdog-ptmx.start 2>/dev/null || true
log "installed local.d ptmx repair"
HOTDOG_ROOTFS_POSTMOUNT_SH
	if [ "$drm_console_userspace" -eq 1 ]; then
		cat >> "$helper" <<'HOTDOG_ROOTFS_DRM_CONSOLE_SH'

install_drm_console_userspace() {
	local bin_dir="/sysroot/usr/local/bin"
	local data_dir="/sysroot/usr/local/share/hotdog"
	local locald="/sysroot/etc/local.d/hotdog-drm-console.start"
	local runlevel="/sysroot/etc/runlevels/default"
	local initd="/sysroot/etc/init.d/local"

	[ -x /usr/bin/hotdog-drm-console ] || {
		log "missing initramfs hotdog-drm-console binary"
		return 0
	}

	mkdir -p "$bin_dir" "$data_dir" /sysroot/etc/local.d 2>/dev/null || true
	cp /usr/bin/hotdog-drm-console "$bin_dir/hotdog-drm-console" 2>/dev/null || {
		log "could not copy hotdog-drm-console into rootfs"
		return 0
	}
	chmod 0755 "$bin_dir/hotdog-drm-console" 2>/dev/null || true

	if [ -r /usr/share/consolefonts/ter-v32n.psf.gz ]; then
		gzip -dc /usr/share/consolefonts/ter-v32n.psf.gz > "$data_dir/ter-v32n.psf" 2>/dev/null || true
	fi
	if [ ! -s "$data_dir/ter-v32n.psf" ] && [ -r /tmp/hotdog-ter-v32n.psf ]; then
		cp /tmp/hotdog-ter-v32n.psf "$data_dir/ter-v32n.psf" 2>/dev/null || true
	fi
	[ -s "$data_dir/ter-v32n.psf" ] || {
		log "missing DRM console PSF font for rootfs"
		return 0
	}

	cat > "$locald" <<'EOF' 2>/dev/null || true
#!/bin/sh
bin=/usr/local/bin/hotdog-drm-console
font=/usr/local/share/hotdog/ter-v32n.psf
fifo=/tmp/hotdog-drm-console.in
transcript=/tmp/hotdog-drm-console.transcript

[ -x "$bin" ] || exit 0
[ -r "$font" ] || exit 0

if [ -r /tmp/hotdog-drm-console.pid ]; then
	pid="$(cat /tmp/hotdog-drm-console.pid 2>/dev/null || true)"
	[ -n "$pid" ] && kill "$pid" 2>/dev/null || true
	sleep 1
	[ -z "$pid" ] || [ ! -d "/proc/$pid" ] || kill -KILL "$pid" 2>/dev/null || true
	rm -f /tmp/hotdog-drm-console.pid
fi
pidof hotdog-drm-console 2>/dev/null | tr ' ' '\n' | while read -r p; do
	[ -n "$p" ] && kill -KILL "$p" 2>/dev/null || true
done
pgrep -x modetest 2>/dev/null | while read -r p; do kill "$p" 2>/dev/null || true; done
pkill plymouthd 2>/dev/null || true

for d in /sys/class/backlight/*; do
	[ -w "$d/bl_power" ] && echo 0 > "$d/bl_power" || true
	if [ -r "$d/max_brightness" ] && [ -w "$d/brightness" ]; then
		cat "$d/max_brightness" > "$d/brightness" || true
	fi
done

i=0
while [ "$i" -lt 60 ] && [ ! -e /dev/dri/card0 ]; do
	sleep 1
	i=$((i + 1))
done
[ -e /dev/dri/card0 ] || exit 0

nohup "$bin" --font "$font" --fifo "$fifo" --transcript "$transcript" \
	>/tmp/hotdog-drm-console.log 2>&1 &
echo $! >/tmp/hotdog-drm-console.pid
EOF
	chmod 0755 "$locald" 2>/dev/null || true
	if [ -d "$runlevel" ] && [ -e "$initd" ]; then
		ln -sf /etc/init.d/local "$runlevel/local" 2>/dev/null || true
	fi
	log "installed persistent DRM console local.d hook"
}

install_drm_console_userspace
HOTDOG_ROOTFS_DRM_CONSOLE_SH
	fi
	if [ "$visible_tty_shell" -eq 1 ]; then
		cat >> "$helper" <<'HOTDOG_VISIBLE_TTY_SHELL_SH'

install_visible_tty_shell() {
	local bin_dir="/sysroot/usr/local/bin"
	local bin="$bin_dir/hotdog-visible-tty-shell"
	local locald="/sysroot/etc/local.d/hotdog-visible-tty-shell.start"
	local runlevel="/sysroot/etc/runlevels/default"
	local initd="/sysroot/etc/init.d/local"

	mkdir -p "$bin_dir" /sysroot/etc/local.d 2>/dev/null || true
	cat > "$bin" <<'EOF' 2>/dev/null || true
#!/bin/sh
tty="${1:-tty1}"
dev="/dev/$tty"

if [ ! -e "$dev" ] && [ -e /dev/tty0 ]; then
	tty="tty0"
	dev="/dev/tty0"
fi
[ -e "$dev" ] || exit 0

exec <"$dev" >"$dev" 2>&1

printf '\033c'
printf 'hotdog visible rootfs shell\n'
printf 'tty: %s\n' "$tty"
printf 'date: '; date 2>/dev/null || true
printf 'uname: '; uname -a 2>/dev/null || true
printf 'cmdline: '; cat /proc/cmdline 2>/dev/null || true
printf '\n--- initial network ---\n'
ip -br addr 2>/dev/null || ip addr 2>/dev/null || true
printf '\n--- initial display/fb ---\n'
ls -la /dev/fb* /dev/dri /sys/class/graphics 2>/dev/null || true
printf '\n--- initial dmesg tail ---\n'
dmesg | tail -120 2>/dev/null || true
printf '\n--- buttons: Vol+ full status, Vol- network/display, Power dmesg tail ---\n'
printf '--- status follower every 20s; shell prompt below if input exists ---\n'

print_full_status() {
	reason="$1"
	printf '\033c'
	printf 'hotdog visible rootfs shell\n'
	printf 'reason: %s\n' "$reason"
	printf 'tty: %s\n' "$tty"
	printf 'date: '; date 2>/dev/null || true
	printf 'uptime: '; uptime 2>/dev/null || true
	printf 'cmdline: '; cat /proc/cmdline 2>/dev/null || true
	printf '\n--- network ---\n'
	ip -br addr 2>/dev/null || ip addr 2>/dev/null || true
	printf '\n--- display/fb ---\n'
	ls -la /dev/fb* /dev/dri /sys/class/graphics /sys/class/graphics/fb0 2>/dev/null || true
	for d in /sys/class/backlight/*; do
		[ -e "$d" ] || continue
		printf '%s brightness=' "$d"
		cat "$d/brightness" 2>/dev/null || true
		printf '%s max_brightness=' "$d"
		cat "$d/max_brightness" 2>/dev/null || true
	done
	printf '\n--- input devices ---\n'
	for ev in /sys/class/input/event*; do
		[ -e "$ev" ] || continue
		printf '%s ' "${ev##*/}"
		cat "$ev/device/name" 2>/dev/null || true
	done
	printf '\n--- process tail ---\n'
	ps 2>/dev/null | tail -30 || true
	printf '\n--- dmesg tail ---\n'
	dmesg | tail -120 2>/dev/null || true
}

print_short_status() {
	reason="$1"
	printf '\n--- visible tty status: %s ---\n' "$reason"
	date 2>/dev/null || true
	uptime 2>/dev/null || true
	ip -br addr 2>/dev/null || true
	dmesg | tail -50 2>/dev/null || true
}

print_display_network() {
	reason="$1"
	printf '\033c'
	printf 'hotdog visible display/network page\n'
	printf 'reason: %s\n' "$reason"
	printf '\n--- network ---\n'
	ip -br addr 2>/dev/null || ip addr 2>/dev/null || true
	printf '\n--- routes ---\n'
	ip route 2>/dev/null || true
	printf '\n--- display/fb ---\n'
	ls -la /dev/fb* /dev/dri /sys/class/graphics /sys/class/graphics/fb0 2>/dev/null || true
	printf '\n--- drm/fb dmesg ---\n'
	dmesg 2>/dev/null | grep -Ei 'drm|dsi|sde|mdss|panel|fb|framebuffer|simplefb|console|tty|backlight' | tail -120 || true
}

button_action() {
	code="$1"
	dev="$2"
	name="$3"
	case "$code" in
		115)
			print_full_status "Vol+ from $dev $name"
			;;
		114)
			print_display_network "Vol- from $dev $name"
			;;
		116)
			print_short_status "Power from $dev $name"
			;;
	esac
}

monitor_input_device() {
	dev="$1"
	name="$(cat "/sys/class/input/${dev##*/}/device/name" 2>/dev/null || true)"
	[ -n "$name" ] || name="$dev"
	while :; do
		event="$(dd if="$dev" bs=24 count=1 2>/dev/null | od -An -tu2 -w24 2>/dev/null | awk 'NF >= 11 { print $9, $10, $11; exit }')"
		[ -n "$event" ] || break
		set -- $event
		type="$1"
		code="$2"
		value="$3"
		[ "$type" = 1 ] || continue
		[ "$value" = 1 ] || continue
		button_action "$code" "$dev" "$name"
	done
}

(
	i=0
	while :; do
		sleep 20
		print_short_status "periodic $i"
		i=$((i + 1))
	done
) &

for evdev in /dev/input/event*; do
	[ -r "$evdev" ] || continue
	monitor_input_device "$evdev" &
done

export TERM=linux
export PS1='screen# '
exec /bin/sh -i
EOF
	chmod 0755 "$bin" 2>/dev/null || true

	cat > "$locald" <<'EOF' 2>/dev/null || true
#!/bin/sh
bin=/usr/local/bin/hotdog-visible-tty-shell
[ -x "$bin" ] || exit 0

log() {
	printf '%s\n' "[hotdog-visible-tty-shell] $*" > /dev/kmsg 2>/dev/null || true
}

pick_tty() {
	for tty in tty1 tty0; do
		[ -e "/dev/$tty" ] && {
			printf '%s\n' "$tty"
			return 0
		}
	done
	return 1
}

stop_getty_on_tty() {
	local tty="$1"
	local proc cmd

	for proc in /proc/[0-9]*; do
		[ -r "$proc/cmdline" ] || continue
		cmd="$(tr '\0' ' ' < "$proc/cmdline" 2>/dev/null || true)"
		case "$cmd" in
			*getty*" $tty"*|*getty*"/dev/$tty"*|*agetty*" $tty"*|*agetty*"/dev/$tty"*)
				kill "${proc##*/}" 2>/dev/null || true
				;;
		esac
	done
}

(
	i=0
	while [ "$i" -lt 60 ]; do
		tty="$(pick_tty)" && break
		sleep 1
		i=$((i + 1))
	done
	[ -n "${tty:-}" ] || {
		log "no visible tty found"
		exit 0
	}

	stop_getty_on_tty "$tty"
	for d in /sys/class/backlight/*; do
		[ -w "$d/bl_power" ] && echo 0 > "$d/bl_power" || true
		if [ -r "$d/max_brightness" ] && [ -w "$d/brightness" ]; then
			cat "$d/max_brightness" > "$d/brightness" || true
		fi
	done

	log "starting $bin on $tty"
	if command -v setsid >/dev/null 2>&1; then
		setsid "$bin" "$tty" &
	else
		"$bin" "$tty" &
	fi
) &
EOF
	chmod 0755 "$locald" 2>/dev/null || true
	if [ -d "$runlevel" ] && [ -e "$initd" ]; then
		ln -sf /etc/init.d/local "$runlevel/local" 2>/dev/null || true
	fi
	log "installed visible tty shell local.d hook"
}

install_visible_tty_shell
HOTDOG_VISIBLE_TTY_SHELL_SH
	fi
	chmod 0755 "$helper"
}

write_hotdog_fb_test_helper() {
	local helper="$initramfs_tree/hotdog_fb_test.sh"

	cat > "$helper" <<'HOTDOG_FB_TEST_SH'
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

hotdog_fb_test_bytes() {
	local fbdir="/sys/class/graphics/fb0"
	local bpp height line_length virtual_size width

	virtual_size="$(cat "$fbdir/virtual_size" 2>/dev/null || true)"
	width="${virtual_size%,*}"
	height="${virtual_size#*,}"
	bpp="$(cat "$fbdir/bits_per_pixel" 2>/dev/null || true)"
	line_length="$(cat "$fbdir/stride" 2>/dev/null || cat "$fbdir/line_length" 2>/dev/null || true)"

	case "$height" in ""|*[!0-9]*) height=3120 ;; esac
	case "$width" in ""|*[!0-9]*) width=1440 ;; esac
	case "$bpp" in ""|*[!0-9]*) bpp=32 ;; esac
	case "$line_length" in ""|*[!0-9]*) line_length=$((width * bpp / 8)) ;; esac

	bytes=$((line_length * height))
	if [ "$bytes" -lt 4096 ] || [ "$bytes" -gt 33554432 ]; then
		bytes=$((1440 * 3120 * 4))
	fi
	printf '%s\n' "$bytes"
}

hotdog_fb_test_make_chunk() {
	local color="$1"
	local chunk="$2"
	local i=0

	rm -f "$chunk"
	while [ "$i" -lt 1024 ]; do
		case "$color" in
			red) printf '\000\000\377\000' ;;
			green) printf '\000\377\000\000' ;;
			blue) printf '\377\000\000\000' ;;
			white) printf '\377\377\377\000' ;;
			*) printf '\000\000\000\000' ;;
		esac
		i=$((i + 1))
	done > "$chunk"
}

hotdog_fb_test_fill() {
	local color="$1"
	local stage="$2"
	local bytes chunk count dev i remainder

	dev="$(hotdog_fb_test_dev)" || return 1
	bytes="$(hotdog_fb_test_bytes)"
	chunk="/tmp/hotdog_fb_${color}.chunk"
	hotdog_fb_test_make_chunk "$color" "$chunk"
	count=$((bytes / 4096))
	remainder=$((bytes % 4096))
	i=0

	hotdog_fb_test_log "painting $dev color=$color stage=$stage bytes=$bytes"
	{
		while [ "$i" -lt "$count" ]; do
			cat "$chunk"
			i=$((i + 1))
		done
		if [ "$remainder" -gt 0 ]; then
			dd if="$chunk" bs=1 count="$remainder" 2>/dev/null || true
		fi
	} > "$dev" 2>/tmp/hotdog_fb_test_last_error.log || return 1

	return 0
}

hotdog_fb_test_start() {
	local stage="$1"

	[ -e /tmp/hotdog_fb_test.started ] && return 0
	: > /tmp/hotdog_fb_test.started 2>/dev/null || true

	(
		waited=0
		while [ "$waited" -lt 45 ]; do
			if hotdog_fb_test_dev >/dev/null 2>&1; then
				hotdog_fb_test_fill red "$stage" || true
				sleep 1
				hotdog_fb_test_fill green "$stage" || true
				sleep 1
				hotdog_fb_test_fill blue "$stage" || true
				sleep 1
				hotdog_fb_test_fill white "$stage" || true
				: > /tmp/hotdog_fb_test.ok 2>/dev/null || true
				exit 0
			fi
			sleep 1
			waited=$((waited + 1))
		done
		hotdog_fb_test_log "no framebuffer appeared by stage=$stage"
	) &
}
HOTDOG_FB_TEST_SH
	chmod 0755 "$helper"
}

write_hotdog_tty_kmsg_console_helper() {
	local helper="$initramfs_tree/hotdog_tty_kmsg_console.sh"

	cat > "$helper" <<'HOTDOG_TTY_KMSG_CONSOLE_SH'
#!/bin/busybox ash

hotdog_tty_kmsg_console_log() {
	local msg="$*"
	[ -e /dev/kmsg ] && printf '%s\n' "[hotdog-tty-kmsg] $msg" > /dev/kmsg 2>/dev/null || true
	printf '%s\n' "[hotdog-tty-kmsg] $msg" 2>/dev/null || true
}

hotdog_tty_kmsg_console_pick_tty() {
	local tty

	for tty in /dev/tty0 /dev/tty1 /dev/console; do
		[ -e "$tty" ] || continue
		printf '%s\n' "$tty"
		return 0
	done
	return 1
}

hotdog_tty_kmsg_console_prepare_fb() {
	local d fbdir mode waited

	waited=0
	while [ "$waited" -lt 30 ]; do
		[ -e /dev/fb0 ] && break
		sleep 1
		waited=$((waited + 1))
	done

	if [ -e /dev/fb0 ]; then
		hotdog_tty_kmsg_console_log "fb0 visible before tty output after ${waited}s"
		fbdir="/sys/class/graphics/fb0"
		if [ -r "$fbdir/modes" ] && [ -w "$fbdir/mode" ]; then
			mode="$(cat "$fbdir/mode" 2>/dev/null || true)"
			if [ -z "$mode" ]; then
				mode="$(sed -n '1p' "$fbdir/modes" 2>/dev/null || true)"
				[ -n "$mode" ] && echo "$mode" > "$fbdir/mode" 2>/dev/null || true
			fi
		fi
	else
		hotdog_tty_kmsg_console_log "fb0 not visible before tty output"
	fi

	for d in /sys/class/backlight/*; do
		[ -w "$d/bl_power" ] && echo 0 > "$d/bl_power" 2>/dev/null || true
		if [ -r "$d/max_brightness" ] && [ -w "$d/brightness" ]; then
			cat "$d/max_brightness" > "$d/brightness" 2>/dev/null || true
		fi
	done
}

hotdog_tty_kmsg_console_start() {
	local stage="$1"

	[ -e /tmp/hotdog_tty_kmsg_console.started ] && return 0
	: > /tmp/hotdog_tty_kmsg_console.started 2>/dev/null || true

	(
		waited=0
		tty=""
		while [ "$waited" -lt 90 ]; do
			tty="$(hotdog_tty_kmsg_console_pick_tty 2>/dev/null || true)"
			[ -n "$tty" ] && break
			sleep 1
			waited=$((waited + 1))
		done
		[ -n "$tty" ] || {
			hotdog_tty_kmsg_console_log "no tty after ${waited}s at $stage"
			exit 0
		}

		hotdog_tty_kmsg_console_log "starting tty kmsg console on $tty at $stage after ${waited}s"
		hotdog_tty_kmsg_console_prepare_fb
		{
			echo "8 4 1 7" > /proc/sys/kernel/printk 2>/dev/null || true
			echo on > /proc/sys/kernel/printk_devkmsg 2>/dev/null || true
		} >/dev/null 2>&1

		if command -v setsid >/dev/null 2>&1; then
			setsid /bin/busybox ash -c '
				stage="$1"
				tty="$2"
				exec <"$tty" >"$tty" 2>&1
				printf "\033c"
				printf "hotdog tty kernel log console\n"
				printf "stage: %s\n" "$stage"
				printf "tty: %s\n" "$tty"
				printf "active console: "
				cat /sys/devices/virtual/tty/console/active 2>/dev/null || true
				printf "\ncmdline: "
				cat /proc/cmdline 2>/dev/null || true
				printf "\n--- framebuffer state ---\n"
				ls -la /dev/fb* /sys/class/graphics /sys/class/graphics/fb0 2>/dev/null || true
				printf "\n--- dmesg tail ---\n"
				dmesg | tail -140 2>/dev/null || true
				i=0
				while :; do
					sleep 4
					printf "\n--- tty kmsg refresh %s ---\n" "$i"
					date 2>/dev/null || true
					printf "active console: "
					cat /sys/devices/virtual/tty/console/active 2>/dev/null || true
					printf "\n"
					ls -la /dev/fb* /sys/class/graphics/fb0 2>/dev/null || true
					dmesg | tail -90 2>/dev/null || true
					i=$((i + 1))
				done
			' sh "$stage" "$tty" &
		else
			/bin/busybox ash -c '
				stage="$1"
				tty="$2"
				exec <"$tty" >"$tty" 2>&1
				printf "\033c"
				printf "hotdog tty kernel log console\n"
				printf "stage: %s\n" "$stage"
				printf "tty: %s\n" "$tty"
				printf "cmdline: "
				cat /proc/cmdline 2>/dev/null || true
				printf "\n--- dmesg tail ---\n"
				dmesg | tail -140 2>/dev/null || true
				while :; do
					sleep 4
					printf "\n--- tty kmsg refresh ---\n"
					dmesg | tail -90 2>/dev/null || true
				done
			' sh "$stage" "$tty" &
		fi
	) &
}
HOTDOG_TTY_KMSG_CONSOLE_SH
	chmod 0755 "$helper"
}

remove_marked_block() {
	local file="$1"
	local begin_marker="$2"
	local end_marker="$3"
	local tmp="$file.tmp.$$"

	[ -f "$file" ] || return 0
	grep -Fq "$begin_marker" "$file" || return 0

	awk -v begin="$begin_marker" -v end="$end_marker" '
		index($0, begin) {
			skip = 1
			next
		}
		skip && index($0, end) {
			skip = 0
			next
		}
		!skip {
			print
		}
	' "$file" > "$tmp"
	replace_preserving_mode "$tmp" "$file"
}

strip_inherited_drm_console() {
	local init_file

	rm -f \
		"$initramfs_tree/hotdog_drm_console_start.sh" \
		"$initramfs_tree/usr/bin/hotdog-drm-console" \
		2>/dev/null || true

	for init_file in "$initramfs_tree/init" "$initramfs_tree/init_2nd" "$initramfs_tree/init_2nd.sh"; do
		remove_marked_block "$init_file" "hotdog DRM console begin" "hotdog DRM console end"
		remove_marked_block "$init_file" "hotdog DRM console switch-root stop begin" "hotdog DRM console switch-root stop end"
	done
}

write_hotdog_drm_console_helper() {
	local helper="$initramfs_tree/hotdog_drm_console_start.sh"

	install -m 0755 "$drm_console_helper" "$initramfs_tree/usr/bin/hotdog-drm-console"

	cat > "$helper" <<'HOTDOG_DRM_CONSOLE_SH'
#!/bin/busybox ash

hotdog_drm_console_log() {
	local msg="$*"
	[ -e /dev/kmsg ] && printf '%s\n' "[hotdog-drm-console] $msg" > /dev/kmsg 2>/dev/null || true
	printf '%s\n' "[hotdog-drm-console] $msg" 2>/dev/null || true
}

hotdog_drm_console_make_node() {
	local dev major minor node

	[ -e /dev/dri/card0 ] && return 0
	mkdir -p /dev/dri 2>/dev/null || true
	mdev -s >/tmp/hotdog-drm-console-mdev.log 2>&1 || true
	[ -e /dev/dri/card0 ] && return 0

	for node in /sys/class/drm/card0/dev /sys/class/drm/card0/device/drm/card0/dev; do
		[ -r "$node" ] || continue
		dev="$(cat "$node" 2>/dev/null || true)"
		major="${dev%:*}"
		minor="${dev#*:}"
		case "$major:$minor" in
			*[!0-9:]*|:|*:)
				continue
				;;
		esac
		mknod /dev/dri/card0 c "$major" "$minor" 2>/dev/null || true
		[ -e /dev/dri/card0 ] && return 0
	done

	return 1
}

hotdog_drm_console_stop() {
	local pid

	if [ -r /tmp/hotdog_drm_console.pid ]; then
		pid="$(cat /tmp/hotdog_drm_console.pid 2>/dev/null || true)"
		[ -n "$pid" ] && kill -KILL "$pid" 2>/dev/null || true
		rm -f /tmp/hotdog_drm_console.pid
	fi
	pidof hotdog-drm-console 2>/dev/null | tr ' ' '\n' | while read -r pid; do
		[ -n "$pid" ] && kill -KILL "$pid" 2>/dev/null || true
	done
}

hotdog_drm_console_start() {
	local stage="$1"

	[ -x /usr/bin/hotdog-drm-console ] || {
		hotdog_drm_console_log "missing /usr/bin/hotdog-drm-console"
		return 0
	}
	[ -e /tmp/hotdog_drm_console.waiting ] && return 0
	: > /tmp/hotdog_drm_console.waiting 2>/dev/null || true

	(
		waited=0
		while [ "$waited" -lt 90 ]; do
			if hotdog_drm_console_make_node; then
				gzip -dc /usr/share/consolefonts/ter-v32n.psf.gz > /tmp/hotdog-ter-v32n.psf 2>/dev/null || true
				[ -r /tmp/hotdog-ter-v32n.psf ] || {
					hotdog_drm_console_log "missing PSF font"
					exit 0
				}
				hotdog_drm_console_log "starting DRM command shell at $stage after ${waited}s"
				/usr/bin/hotdog-drm-console \
					--font /tmp/hotdog-ter-v32n.psf \
					--fifo /tmp/hotdog-drm-console.in \
					--transcript /tmp/hotdog-drm-console.transcript \
					--command "export TERM=dumb; PS1='initramfs# '; export PS1; printf '\n--- hotdog initramfs DRM command shell ---\n'; printf 'stage: $stage\n'; printf 'cmdline: '; cat /proc/cmdline; printf '\n--- initial dmesg snapshot ---\n'; dmesg | tail -80; printf '\n--- starting background dmesg follower every 5s ---\n'; (i=0; while :; do sleep 5; printf '\n--- dmesg follow %s ---\n' \"\$i\"; dmesg | tail -60; i=\$((i + 1)); done) & printf 'follower pid: %s\n' \"\$!\"; printf '\n--- ready: commands are read from /tmp/hotdog-drm-console.in ---\n'" \
					>/tmp/hotdog-drm-console.log 2>&1 &
				echo $! > /tmp/hotdog_drm_console.pid
				exit 0
			fi
			sleep 1
			waited=$((waited + 1))
		done
		hotdog_drm_console_log "no /dev/dri/card0 by $stage"
	) &
}
HOTDOG_DRM_CONSOLE_SH
	chmod 0755 "$helper"
}

patch_init_scripts() {
	local init_file="$initramfs_tree/init"
	local init2_file
	local fb_snippet
	local drm_snippet
	local drm_stop_snippet
	local tty_kmsg_snippet
	local stage1_snippet
	local stage2_snippet
	local usb_snippet
	local root_snippet
	local switch_snippet

	require_file "$init_file"

	stage1_snippet='
# hotdog rescue watchdog stage1 begin
if [ -r /hotdog_rescue_watchdog.sh ]; then
	. /hotdog_rescue_watchdog.sh
	hotdog_rescue_watchdog_start stage1
fi
# hotdog rescue watchdog stage1 end'

	stage2_snippet='
# hotdog rescue watchdog stage2 begin
if [ -r /hotdog_rescue_watchdog.sh ]; then
	. /hotdog_rescue_watchdog.sh
	hotdog_rescue_watchdog_start stage2
fi
# hotdog rescue watchdog stage2 end'

	usb_snippet='
# hotdog rescue watchdog usb marker begin
if [ -r /hotdog_rescue_watchdog.sh ]; then
	. /hotdog_rescue_watchdog.sh
	hotdog_rescue_watchdog_mark_if_usb usb-network
	hotdog_rescue_direct_debug_shell_start
fi
# hotdog rescue watchdog usb marker end'

	root_snippet='
# hotdog rescue watchdog root marker begin
if [ -r /hotdog_rescue_watchdog.sh ]; then
	. /hotdog_rescue_watchdog.sh
	hotdog_rescue_watchdog_mark root-mounted
fi
[ -r /hotdog_rootfs_postmount.sh ] && sh /hotdog_rootfs_postmount.sh
# hotdog rescue watchdog root marker end'

	switch_snippet='
# hotdog rescue watchdog switch-root marker begin
if [ -r /hotdog_rescue_watchdog.sh ]; then
	. /hotdog_rescue_watchdog.sh
	hotdog_rescue_watchdog_mark switch-root
fi
if [ -r /hotdog_drm_console_start.sh ]; then
	. /hotdog_drm_console_start.sh
	hotdog_drm_console_stop
fi
# hotdog rescue watchdog switch-root marker end'

	fb_snippet='
# hotdog framebuffer paint test begin
if [ -r /hotdog_fb_test.sh ]; then
	. /hotdog_fb_test.sh
	hotdog_fb_test_start initramfs
fi
# hotdog framebuffer paint test end'

	tty_kmsg_snippet='
# hotdog tty kmsg console begin
if [ -r /hotdog_tty_kmsg_console.sh ]; then
	. /hotdog_tty_kmsg_console.sh
	hotdog_tty_kmsg_console_start initramfs
fi
# hotdog tty kmsg console end'

	drm_snippet='
# hotdog DRM console begin
if [ -r /hotdog_drm_console_start.sh ]; then
	. /hotdog_drm_console_start.sh
	hotdog_drm_console_start initramfs
fi
# hotdog DRM console end'

	drm_stop_snippet='
# hotdog DRM console switch-root stop begin
if [ -r /hotdog_drm_console_start.sh ]; then
	. /hotdog_drm_console_start.sh
	hotdog_drm_console_stop
fi
# hotdog DRM console switch-root stop end'

	insert_after_once "$init_file" "mount_proc_sys_dev" "hotdog rescue watchdog stage1 begin" "$stage1_snippet"
	if [ "$tty_kmsg_console" -eq 1 ]; then
		insert_after_once "$init_file" "hotdog rescue watchdog stage1 end" "hotdog tty kmsg console begin" "$tty_kmsg_snippet"
	fi
	if [ "$drm_console" -eq 1 ]; then
		insert_after_once "$init_file" "hotdog rescue watchdog stage1 end" "hotdog DRM console begin" "$drm_snippet"
	fi
	insert_after_once "$init_file" "start_unudhcpd" "hotdog rescue watchdog usb marker begin" "$usb_snippet"
	if [ "$fb_test" -eq 1 ]; then
		insert_before_once "$init_file" "mount_subpartitions" "hotdog framebuffer paint test begin" "$fb_snippet"
	fi

	for init2_file in "$initramfs_tree/init_2nd" "$initramfs_tree/init_2nd.sh"; do
		[ -f "$init2_file" ] || continue
		insert_after_once "$init2_file" "trap 'reboot -f' TERM" "hotdog rescue watchdog stage2 begin" "$stage2_snippet"
		if [ "$tty_kmsg_console" -eq 1 ]; then
			insert_after_once "$init2_file" "hotdog rescue watchdog stage2 end" "hotdog tty kmsg console begin" "$tty_kmsg_snippet"
		fi
		if [ "$drm_console" -eq 1 ]; then
			insert_after_once "$init2_file" "hotdog rescue watchdog stage2 end" "hotdog DRM console begin" "$drm_snippet"
		fi
		insert_after_once "$init2_file" "start_unudhcpd" "hotdog rescue watchdog usb marker begin" "$usb_snippet"
		if [ "$fb_test" -eq 1 ]; then
			insert_before_once "$init2_file" "setup_dynamic_partitions" "hotdog framebuffer paint test begin" "$fb_snippet"
		fi
		insert_after_once "$init2_file" "mount_root_partition" "hotdog rescue watchdog root marker begin" "$root_snippet"
		insert_before_once "$init2_file" "exec switch_root /sysroot" "hotdog rescue watchdog switch-root marker begin" "$switch_snippet"
		if [ "$drm_console" -eq 1 ]; then
			insert_before_once "$init2_file" "exec switch_root /sysroot" "hotdog DRM console switch-root stop begin" "$drm_stop_snippet"
		fi
	done
}

build_bootimg_in_chroot() {
	local cmdline="$1"
	local output_img="$2"
	local chroot_output="$mkbootimg_dir/pmbootstrap-chroot-mkbootimg.out"
	local host_pid="$$"
	local kernel_fd ramdisk_fd dtb_fd output_fd
	local kernel_path ramdisk_path dtb_path output_path
	local chroot_mkbootimg
	local mkbootimg_args=()

	note "building boot.img with pmbootstrap native chroot mkbootimg"
	"${pmb[@]}" chroot --add mkbootimg-osm0sis --output stdout -- true \
		> "$mkbootimg_dir/pmbootstrap-chroot-mkbootimg-install.out" 2>&1 || {
		sed -n '1,160p' "$mkbootimg_dir/pmbootstrap-chroot-mkbootimg-install.out" >&2 || true
		die "could not install mkbootimg-osm0sis in pmbootstrap native chroot"
	}
	chroot_mkbootimg="$("${pmb[@]}" chroot --output stdout -- sh -c '
		if command -v mkbootimg >/dev/null 2>&1; then
			printf "%s\n" mkbootimg
		elif command -v mkbootimg-osm0sis >/dev/null 2>&1; then
			printf "%s\n" mkbootimg-osm0sis
		else
			exit 127
		fi
	' 2>"$mkbootimg_dir/pmbootstrap-chroot-mkbootimg-probe.err")" || {
		sed -n '1,120p' "$mkbootimg_dir/pmbootstrap-chroot-mkbootimg-probe.err" >&2 || true
		die "missing mkbootimg in pmbootstrap native chroot"
	}
	note "using native chroot boot image builder: $chroot_mkbootimg"
	exec {kernel_fd}<"$components_dir/kernel"
	exec {ramdisk_fd}<"$components_dir/initramfs-watchdog.gz"
	exec {dtb_fd}<"$components_dir/dtb"
	exec {output_fd}>"$output_img"

	kernel_path="/proc/$host_pid/fd/$kernel_fd"
	ramdisk_path="/proc/$host_pid/fd/$ramdisk_fd"
	dtb_path="/proc/$host_pid/fd/$dtb_fd"
	output_path="/proc/$host_pid/fd/$output_fd"

	mkbootimg_args=(
		--kernel "$kernel_path" \
		--ramdisk "$ramdisk_path" \
		--cmdline "$cmdline" \
		--base "$boot_base" \
		--kernel_offset "$kernel_offset" \
		--ramdisk_offset "$ramdisk_offset" \
		--second_offset "$second_offset" \
		--tags_offset "$tags_offset" \
		--pagesize 4096 \
		--header_version 2 \
		--dtb "$dtb_path" \
		--dtb_offset "$dtb_offset" \
		--output "$output_path"
	)
	if [ -n "$os_version" ]; then
		mkbootimg_args+=(--os_version "$os_version")
	fi
	if [ -n "$os_patch_level" ]; then
		mkbootimg_args+=(--os_patch_level "$os_patch_level")
	fi

	if ! "${pmb[@]}" chroot --output stdout -- "$chroot_mkbootimg" "${mkbootimg_args[@]}" \
		> "$chroot_output" 2>&1; then
		exec {kernel_fd}<&- || true
		exec {ramdisk_fd}<&- || true
		exec {dtb_fd}<&- || true
		exec {output_fd}>&- || true
		sed -n '1,220p' "$chroot_output" >&2 || true
		die "pmbootstrap chroot mkbootimg failed; see $chroot_output"
	fi

	exec {kernel_fd}<&- || true
	exec {ramdisk_fd}<&- || true
	exec {dtb_fd}<&- || true
	exec {output_fd}>&- || true

	[ -s "$output_img" ] || die "mkbootimg produced an empty image: $output_img"
}

write_manifest() {
	local manifest="$outdir/MANIFEST.md"
	local output_img="$outdir/boot-noefi-pmosdtb-watchdog-${watchdog_sec}s.img"
	local initramfs_img="$components_dir/initramfs-watchdog.gz"

	{
		printf '# hotdog no-EFI watchdog boot image candidate\n\n'
		printf 'Date: %s\n\n' "$(date -Iseconds)"
		printf 'No adb, fastboot, scrcpy, USB reset, or phone command was used by this script.\n\n'
		printf '## Inputs\n\n'
		printf -- '- Source boot image: `%s`\n' "$source_boot"
		printf -- '- Source SHA256: `%s`\n' "$(sha256sum "$source_boot" | awk '{ print $1 }')"
			printf -- '- Kernel override: `%s`\n' "${kernel_override:-none}"
			printf -- '- DTB override: `%s`\n' "${dtb_override:-none}"
			printf -- '- Source unpack log: `%s`\n\n' "$outdir/source-unpack.txt"
			printf -- '- Extra cmdline: `%s`\n' "$extra_cmdline"
			if [ "$with_ramoops_cmdline" -eq 1 ]; then
				printf -- '- Ramoops cmdline: enabled, `%s`\n\n' "$ramoops_cmdline"
			else
				printf -- '- Ramoops cmdline: disabled\n\n'
			fi
			printf -- '- Direct debug shell: `%s`\n' "$direct_debug_shell"
			printf -- '- Framebuffer paint test: `%s`\n' "$fb_test"
			printf -- '- DRM initramfs console: `%s`\n' "$drm_console"
			if [ "$drm_console" -eq 1 ]; then
				printf -- '- DRM console helper: `%s`\n' "$drm_console_helper"
			fi
			printf -- '- TTY kmsg console: `%s`\n' "$tty_kmsg_console"
			printf -- '- Visible tty shell: `%s`\n' "$visible_tty_shell"
			printf -- '- Strip inherited DRM console: `%s`\n' "$strip_drm_console"
			printf -- '- OS version: `%s`\n' "${os_version:-default}"
			printf -- '- OS patch level: `%s`\n' "${os_patch_level:-default}"
			printf -- '- Boot base: `%s`\n' "$boot_base"
			printf -- '- Kernel offset: `%s`\n' "$kernel_offset"
			printf -- '- Ramdisk offset: `%s`\n' "$ramdisk_offset"
			printf -- '- Second offset: `%s`\n' "$second_offset"
			printf -- '- Tags offset: `%s`\n' "$tags_offset"
			printf -- '- DTB offset: `%s`\n\n' "$dtb_offset"
		printf '## Outputs\n\n'
		printf -- '- Candidate boot image: `%s`\n' "$output_img"
		printf -- '- Watchdog initramfs: `%s`\n' "$initramfs_img"
		printf -- '- Artifact directory: `%s`\n' "$outdir"
		printf -- '- Watchdog seconds: `%s`\n\n' "$watchdog_sec"
		printf -- '- Watchdog success mode: `%s`\n\n' "$watchdog_success"
		printf '## Cmdline\n\n'
		printf '```text\n'
		cat "$outdir/cmdline-watchdog.txt"
		printf '\n```\n\n'
		printf '## Build command\n\n'
		printf '```bash\n'
		printf '%q --source-boot %q --watchdog-sec %q' "$0" "$source_boot" "$watchdog_sec"
			if [ "$watchdog_success" != "usb" ]; then
				printf ' --watchdog-success %q' "$watchdog_success"
			fi
		if [ -n "$kernel_override" ]; then
			printf ' --kernel %q' "$kernel_override"
		fi
			if [ -n "$dtb_override" ]; then
				printf ' --dtb %q' "$dtb_override"
			fi
			if [ "$with_ramoops_cmdline" -eq 1 ]; then
				printf ' --with-ramoops-cmdline'
			fi
			if [ "$direct_debug_shell" -eq 1 ]; then
				printf ' --direct-debug-shell'
			fi
			if [ "$fb_test" -eq 1 ]; then
				printf ' --fb-test'
			fi
			if [ "$drm_console" -eq 1 ]; then
				printf ' --drm-console --drm-console-helper %q' "$drm_console_helper"
			fi
			if [ "$drm_console_userspace" -eq 1 ]; then
				printf ' --drm-console-userspace'
			fi
			if [ "$tty_kmsg_console" -eq 1 ]; then
				printf ' --tty-kmsg-console'
			fi
			if [ "$visible_tty_shell" -eq 1 ]; then
				printf ' --visible-tty-shell'
			fi
			if [ "$strip_drm_console" -eq 1 ]; then
				printf ' --strip-drm-console'
			fi
			if [ -n "$extra_cmdline" ]; then
				printf ' --extra-cmdline %q' "$extra_cmdline"
			fi
			if [ -n "$os_version" ]; then
				printf ' --os-version %q' "$os_version"
			fi
			if [ -n "$os_patch_level" ]; then
				printf ' --os-patch-level %q' "$os_patch_level"
			fi
			printf ' --base %q' "$boot_base"
			printf ' --kernel-offset %q' "$kernel_offset"
			printf ' --ramdisk-offset %q' "$ramdisk_offset"
			printf ' --second-offset %q' "$second_offset"
			printf ' --tags-offset %q' "$tags_offset"
			printf ' --dtb-offset %q' "$dtb_offset"
		printf ' --outdir %q\n' "$outdir"
		printf '```\n\n'
		printf '## Verification\n\n'
		printf -- '- Repacked initramfs listing: `%s`\n' "$outdir/initramfs-watchdog-contents.txt"
		printf -- '- Boot image unpack log: `%s`\n' "$outdir/unpack-watchdog.txt"
		printf -- '- File summary: `%s`\n' "$outdir/file-summary.txt"
		printf -- '- SHA256 sums: `%s`\n' "$outdir/SHA256SUMS"
	} > "$manifest"
}

note "artifact directory: $outdir"
note "unpacking source boot image"
unpack_bootimg --boot_img "$source_boot" --out "$outdir/source-unpack" > "$outdir/source-unpack.txt"

header_version="$(extract_field "boot image header version" "$outdir/source-unpack.txt")"
page_size="$(extract_field "page size" "$outdir/source-unpack.txt")"
kernel_addr="$(extract_field "kernel load address" "$outdir/source-unpack.txt")"
ramdisk_addr="$(extract_field "ramdisk load address" "$outdir/source-unpack.txt")"
tags_addr="$(extract_field "kernel tags load address" "$outdir/source-unpack.txt")"
dtb_addr="$(extract_field "dtb address" "$outdir/source-unpack.txt")"

[ "$header_version" = "2" ] || die "source boot image is not header v2: $header_version"
[ "$page_size" = "4096" ] || die "source boot image page size is not 4096: $page_size"
[ "$kernel_addr" = "0x00008000" ] || die "unexpected kernel load address: $kernel_addr"
[ "$ramdisk_addr" = "0x01000000" ] || die "unexpected ramdisk load address: $ramdisk_addr"
[ "$tags_addr" = "0x00000100" ] || die "unexpected tags load address: $tags_addr"
[ "$dtb_addr" = "0x0000000001f00000" ] || die "unexpected dtb address: $dtb_addr"

if [ -n "$kernel_override" ]; then
	cp "$kernel_override" "$components_dir/kernel"
else
	cp "$outdir/source-unpack/kernel" "$components_dir/kernel"
fi

if [ -n "$dtb_override" ]; then
	cp "$dtb_override" "$components_dir/dtb"
else
	cp "$outdir/source-unpack/dtb" "$components_dir/dtb"
fi

cp "$outdir/source-unpack/ramdisk" "$components_dir/initramfs-original.gz"
{
	printf 'kernel=%s\n' "${kernel_override:-$outdir/source-unpack/kernel}"
	printf 'dtb=%s\n' "${dtb_override:-$outdir/source-unpack/dtb}"
	printf 'ramdisk=%s\n' "$outdir/source-unpack/ramdisk"
} > "$outdir/component-sources.txt"

source_cmdline="$(extract_field "command line args" "$outdir/source-unpack.txt")$(extract_field "additional command line args" "$outdir/source-unpack.txt")"
[ -n "$source_cmdline" ] || die "could not extract source cmdline"
combined_cmdline="$(append_dedup_keyed_cmdline "$source_cmdline" "$extra_cmdline")"
if [ "$with_ramoops_cmdline" -eq 1 ]; then
	combined_cmdline="$(append_dedup_keyed_cmdline "$combined_cmdline" "$ramoops_cmdline")"
fi
watchdog_cmdline="$(append_watchdog_cmdline "$combined_cmdline" "$watchdog_sec")"
printf '%s\n' "$source_cmdline" > "$outdir/cmdline-source.txt"
printf '%s\n' "$extra_cmdline" > "$outdir/cmdline-extra.txt"
if [ "$with_ramoops_cmdline" -eq 1 ]; then
	printf '%s\n' "$ramoops_cmdline" > "$outdir/cmdline-ramoops.txt"
else
	: > "$outdir/cmdline-ramoops.txt"
fi
printf '%s\n' "$watchdog_cmdline" > "$outdir/cmdline-watchdog.txt"

note "extracting initramfs"
gzip -cd "$components_dir/initramfs-original.gz" \
	| (cd "$initramfs_tree" && cpio -idm --no-absolute-filenames) \
	> "$outdir/initramfs-extract.log" 2>&1

note "injecting watchdog helper and init hooks"
write_watchdog_helper
write_hotdog_super_loop_hook
write_hotdog_rootfs_postmount_helper
if [ "$strip_drm_console" -eq 1 ]; then
	strip_inherited_drm_console
fi
if [ "$fb_test" -eq 1 ]; then
	write_hotdog_fb_test_helper
fi
if [ "$tty_kmsg_console" -eq 1 ]; then
	write_hotdog_tty_kmsg_console_helper
fi
if [ "$drm_console" -eq 1 ]; then
	write_hotdog_drm_console_helper
fi
patch_init_scripts

sed -n '1,120p' "$initramfs_tree/init" > "$outdir/init-after-injection-head.txt"
if [ -f "$initramfs_tree/init_2nd.sh" ]; then
	sed -n '1,180p' "$initramfs_tree/init_2nd.sh" > "$outdir/init_2nd-after-injection-head.txt"
elif [ -f "$initramfs_tree/init_2nd" ]; then
	sed -n '1,180p' "$initramfs_tree/init_2nd" > "$outdir/init_2nd-after-injection-head.txt"
fi

note "repacking initramfs"
(
	cd "$initramfs_tree"
	find . -print0 | sort -z | cpio --null -o -H newc 2> "$outdir/initramfs-repack-cpio.log"
) | gzip -9n > "$components_dir/initramfs-watchdog.gz"

gzip -cd "$components_dir/initramfs-watchdog.gz" \
	| cpio -it 2>/dev/null \
	| sort > "$outdir/initramfs-watchdog-contents.txt"

output_img="$outdir/boot-noefi-pmosdtb-watchdog-${watchdog_sec}s.img"
build_bootimg_in_chroot "$watchdog_cmdline" "$output_img"

note "verifying rebuilt boot image"
unpack_bootimg --boot_img "$output_img" --out "$verify_dir" > "$outdir/unpack-watchdog.txt"
file "$source_boot" "$output_img" "$components_dir/initramfs-watchdog.gz" "$verify_dir/kernel" "$verify_dir/ramdisk" "$verify_dir/dtb" \
	> "$outdir/file-summary.txt"

sha256sum \
	"$source_boot" \
	"$components_dir/kernel" \
	"$components_dir/dtb" \
	"$components_dir/initramfs-original.gz" \
	"$components_dir/initramfs-watchdog.gz" \
	"$output_img" \
	"$outdir/source-unpack.txt" \
	"$outdir/unpack-watchdog.txt" \
	> "$outdir/SHA256SUMS"

write_manifest

note "done"
printf 'Artifact directory: %s\n' "$outdir"
printf 'Candidate boot image: %s\n' "$output_img"
printf 'Watchdog initramfs: %s\n' "$components_dir/initramfs-watchdog.gz"
printf 'Manifest: %s\n' "$outdir/MANIFEST.md"
