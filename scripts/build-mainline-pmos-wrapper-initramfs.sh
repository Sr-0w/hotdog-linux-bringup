#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source "$(dirname "$0")/env.sh"

BASE_CPIO="$HOTDOG_ROOT/build/experiments/2026-07-11-110300-mainline617-pmos-r5-raw-initramfs/initramfs-pmos-r5.cpio"
GEN_INIT_CPIO="$HOTDOG_ROOT/build/experiments/2026-07-10-mainline617-psci-entry-reset-src/usr/gen_init_cpio"
OUTDIR=""
SUPPRESS_FB_PAINT=1
USERSPACE_FB_MARKER=0
WRAPPER_BINARY=""
REBOOT_MODE_HELPER=""
APSS_WDT_HELPER=""
RESCUE_SUPERVISOR=""
BOUNDED_EXEC_HELPER=""
USERSPACE_STAGE_HELPER=""
USERSPACE_STAGE_PROFILE="handoff"
SOURCE_INIT_2ND=0

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
  --apss-wdt-helper FILE
                        Add the static APSS watchdog helper. Keep a 32-second
                        bootloader fallback alive until the initramfs deadline
                        and disarm it only after the configured success marker.
  --rescue-supervisor FILE
                        Replace the shell watchdog worker with a static
                        monotonic-deadline supervisor. It performs RESTART2
                        directly and keeps a 32-second APSS fallback armed.
  --bounded-exec-helper FILE
                        Use a static fork/exec supervisor for bounded udev
                        commands so a blocked child exec cannot suspend ash.
  --userspace-stage-helper FILE
                        Add the static stage helper and replace /init plus
                        /init_2nd.sh with instrumented copies that mark the
                        stage-one handoff and early stage-two setup.
  --userspace-stage-profile PROFILE
                        Select stage-two checkpoints: handoff (default),
                        handoff-deep, udev, udev-bounded,
                        udev-bounded-deep, udev-skip, or usb-probe.
                        handoff-deep separates both sourced function files,
                        watchdog return, and entry into setup_udev.
                        udev-bounded reports each udev command and moves past
                        one that is still blocked after 15 seconds.
                        udev-bounded-deep reports init_2nd entry, function
                        sources, watchdog return, bounded setup_udev return,
                        and USB networking return.
                        udev-skip omits setup_udev and traces USB gadget setup
                        plus DHCP startup. It is diagnostic-only.
                        usb-probe omits setup_udev and reports configfs, UDC,
                        gadget binding, and network-interface availability.
  --source-init-2nd     Source /init_2nd.sh at the first stage handoff instead
                        of executing it. This diagnostic mode isolates a
                        blocked second execve while preserving PID 1.
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
		--apss-wdt-helper) APSS_WDT_HELPER="$2"; shift ;;
		--rescue-supervisor) RESCUE_SUPERVISOR="$2"; shift ;;
		--bounded-exec-helper) BOUNDED_EXEC_HELPER="$2"; shift ;;
		--userspace-stage-helper) USERSPACE_STAGE_HELPER="$2"; shift ;;
		--userspace-stage-profile) USERSPACE_STAGE_PROFILE="$2"; shift ;;
		--source-init-2nd) SOURCE_INIT_2ND=1 ;;
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
if [ -n "$USERSPACE_STAGE_HELPER" ]; then
	[ -x "$USERSPACE_STAGE_HELPER" ] || {
		printf 'Missing executable userspace-stage helper: %s\n' \
			"$USERSPACE_STAGE_HELPER" >&2
		exit 2
	}
	file "$USERSPACE_STAGE_HELPER" |
		grep -q 'ELF 64-bit LSB executable, ARM aarch64' || {
		printf 'Userspace-stage helper is not an AArch64 executable: %s\n' \
			"$USERSPACE_STAGE_HELPER" >&2
		exit 2
	}
	grep -a -q 'HOTDOG_USERSPACE_STAGE_V1' "$USERSPACE_STAGE_HELPER" || {
		printf 'Userspace-stage helper marker is missing: %s\n' \
			"$USERSPACE_STAGE_HELPER" >&2
		exit 2
	}
fi
case "$USERSPACE_STAGE_PROFILE" in
	handoff|handoff-deep|udev|udev-bounded|udev-bounded-deep|udev-skip|usb-probe) ;;
	*)
		printf 'Unknown userspace stage profile: %s\n' \
			"$USERSPACE_STAGE_PROFILE" >&2
		exit 2
		;;
esac
if [ -z "$USERSPACE_STAGE_HELPER" ] &&
		[ "$USERSPACE_STAGE_PROFILE" != handoff ]; then
	printf '%s requires --userspace-stage-helper\n' \
		"--userspace-stage-profile=$USERSPACE_STAGE_PROFILE" >&2
	exit 2
fi
if [ "$SOURCE_INIT_2ND" -eq 1 ] && [ -z "$USERSPACE_STAGE_HELPER" ]; then
	printf '%s requires --userspace-stage-helper\n' \
		"--source-init-2nd" >&2
	exit 2
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
fi
if [ -n "$APSS_WDT_HELPER" ]; then
	[ -x "$APSS_WDT_HELPER" ] || {
		printf 'Missing executable APSS watchdog helper: %s\n' \
			"$APSS_WDT_HELPER" >&2
		exit 2
	}
	file "$APSS_WDT_HELPER" |
		grep -q 'ELF 64-bit LSB executable, ARM aarch64' || {
		printf 'APSS watchdog helper is not an AArch64 executable: %s\n' \
			"$APSS_WDT_HELPER" >&2
		exit 2
	}
	grep -a -q 'HOTDOG_APSS_WDT_CONTROL_V3' "$APSS_WDT_HELPER" || {
		printf 'APSS watchdog helper marker is missing: %s\n' \
			"$APSS_WDT_HELPER" >&2
		exit 2
	}
fi
if [ -n "$RESCUE_SUPERVISOR" ]; then
	[ -z "$REBOOT_MODE_HELPER" ] && [ -z "$APSS_WDT_HELPER" ] || {
		printf '%s is mutually exclusive with %s and %s\n' \
			"--rescue-supervisor" "--reboot-mode-helper" \
			"--apss-wdt-helper" >&2
		exit 2
	}
	[ -x "$RESCUE_SUPERVISOR" ] || {
		printf 'Missing executable rescue supervisor: %s\n' \
			"$RESCUE_SUPERVISOR" >&2
		exit 2
	}
	file "$RESCUE_SUPERVISOR" |
		grep -q 'ELF 64-bit LSB executable, ARM aarch64' || {
		printf 'Rescue supervisor is not an AArch64 executable: %s\n' \
			"$RESCUE_SUPERVISOR" >&2
		exit 2
	}
	grep -a -q 'HOTDOG_RESCUE_SUPERVISOR_V1' "$RESCUE_SUPERVISOR" || {
		printf 'Rescue supervisor marker is missing: %s\n' \
			"$RESCUE_SUPERVISOR" >&2
		exit 2
	}
fi
if [ -n "$BOUNDED_EXEC_HELPER" ]; then
	case "$USERSPACE_STAGE_PROFILE" in
		udev-bounded|udev-bounded-deep) ;;
		*)
			printf '%s requires a bounded udev stage profile\n' \
				"--bounded-exec-helper" >&2
			exit 2
			;;
	esac
	[ -x "$BOUNDED_EXEC_HELPER" ] || {
		printf 'Missing executable bounded exec helper: %s\n' \
			"$BOUNDED_EXEC_HELPER" >&2
		exit 2
	}
	file "$BOUNDED_EXEC_HELPER" |
		grep -q 'ELF 64-bit LSB executable, ARM aarch64' || {
		printf 'Bounded exec helper is not an AArch64 executable: %s\n' \
			"$BOUNDED_EXEC_HELPER" >&2
		exit 2
	}
	file "$BOUNDED_EXEC_HELPER" | grep -q 'statically linked' || {
		printf 'Bounded exec helper is not statically linked: %s\n' \
			"$BOUNDED_EXEC_HELPER" >&2
		exit 2
	}
	grep -a -q 'HOTDOG_BOUNDED_EXEC_V1' "$BOUNDED_EXEC_HELPER" || {
		printf 'Bounded exec helper marker is missing: %s\n' \
			"$BOUNDED_EXEC_HELPER" >&2
		exit 2
	}
fi
if [ -n "$REBOOT_MODE_HELPER" ] || [ -n "$APSS_WDT_HELPER" ] ||
		[ -n "$RESCUE_SUPERVISOR" ] ||
		[ -n "$BOUNDED_EXEC_HELPER" ] ||
		[ -n "$USERSPACE_STAGE_HELPER" ]; then
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
watchdog_original="$OUTDIR/hotdog_rescue_watchdog.original"
watchdog_restart2_override="$OUTDIR/hotdog_rescue_watchdog.restart2"
init_original="$OUTDIR/init.original"
init_override="$OUTDIR/init.instrumented"
init_2nd_original="$OUTDIR/init_2nd.original"
init_2nd_override="$OUTDIR/init_2nd.instrumented"
init_functions_2nd_original="$OUTDIR/init_functions_2nd.original"
init_functions_2nd_override="$OUTDIR/init_functions_2nd.instrumented"
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

if [ -n "$BOUNDED_EXEC_HELPER" ]; then
	printf 'file /hotdog-bounded-exec %s 0755 0 0\n' \
		"$BOUNDED_EXEC_HELPER" >> "$list_file"
fi

if [ -n "$USERSPACE_STAGE_HELPER" ]; then
	"$HOTDOG_ROOT/scripts/extract-last-newc-member.py" \
		"$BASE_CPIO" init > "$init_original"
	awk -v source_init_2nd="$SOURCE_INIT_2ND" '
		function marker(stage) {
			print "/hotdog-userspace-stage " stage
		}

		/^[[:space:]]*set -a[[:space:]]*$/ && !stage0 {
			print
			marker(0)
			stage0 = 1
			next
		}

		/^[[:space:]]*mount_proc_sys_dev[[:space:]]*$/ && !stage1 {
			marker(1)
			print
			marker(2)
			stage1 = stage2 = 1
			next
		}

		/^[[:space:]]*hotdog_rescue_watchdog_start stage1[[:space:]]*$/ &&
				!stage3 {
			print
			marker(3)
			stage3 = 1
			next
		}

		/^[[:space:]]*setup_log[[:space:]]*$/ && !stage4 {
			print
			marker(4)
			stage4 = 1
			next
		}

		/^[[:space:]]*jump_init_2nd[[:space:]]*$/ && !stage5 {
			marker(5)
			if (source_init_2nd)
				print ". /init_2nd.sh"
			else
				print
			marker(6)
			stage5 = stage6 = 1
			next
		}

		/^[[:space:]]*setup_mdev[[:space:]]*$/ && !stage7 {
			print
			marker(7)
			stage7 = 1
			next
		}

		/^[[:space:]]*load_modules \/lib\/modules\/initramfs\.load[[:space:]]*$/ &&
				!stage8 {
			print
			marker(8)
			stage8 = 1
			next
		}

		/^[[:space:]]*setup_usb_network[[:space:]]*$/ && !stage9 {
			print
			marker(9)
			stage9 = 1
			next
		}

		/^[[:space:]]*start_unudhcpd[[:space:]]*$/ && !stage10 {
			print
			marker(10)
			stage10 = 1
			next
		}

		{ print }

		END {
			if (!(stage0 && stage1 && stage2 && stage3 && stage4 &&
			      stage5 && stage6 && stage7 && stage8 && stage9 &&
			      stage10))
				exit 42
		}
	' "$init_original" > "$init_override"
	chmod 0755 "$init_override"

	"$HOTDOG_ROOT/scripts/extract-last-newc-member.py" \
		"$BASE_CPIO" init_2nd.sh > "$init_2nd_original"
	if [ "$USERSPACE_STAGE_PROFILE" = handoff ]; then
		awk '
			function marker(stage) {
				print "/hotdog-userspace-stage " stage
			}

			/^#!\/bin\/busybox ash$/ && !stage6 {
				print
				marker(6)
				stage6 = 1
				next
			}

			/^[[:space:]]*\. \/init_functions_2nd\.sh[[:space:]]*$/ &&
					!stage7 {
				print
				marker(7)
				stage7 = 1
				next
			}

			/^[[:space:]]*hotdog_rescue_watchdog_start stage2[[:space:]]*$/ &&
					!stage8 {
				print
				marker(8)
				stage8 = 1
				next
			}

			/^[[:space:]]*setup_udev[[:space:]]*$/ && !stage9 {
				marker(9)
				print
				marker(10)
				stage9 = stage10 = 1
				next
			}

			{ print }

			END {
				if (!(stage6 && stage7 && stage8 && stage9 && stage10))
					exit 42
			}
		' "$init_2nd_original" > "$init_2nd_override"
	elif [ "$USERSPACE_STAGE_PROFILE" = handoff-deep ]; then
		awk '
			function marker(stage) {
				print "/hotdog-userspace-stage " stage
			}

			/^#!\/bin\/busybox ash$/ && !stage6 {
				print
				marker(6)
				stage6 = 1
				next
			}

			/^[[:space:]]*\. \/init_functions\.sh[[:space:]]*$/ &&
					!stage7 {
				print
				marker(7)
				stage7 = 1
				next
			}

			/^[[:space:]]*\. \/init_functions_2nd\.sh[[:space:]]*$/ &&
					!stage8 {
				print
				marker(8)
				stage8 = 1
				next
			}

			/^[[:space:]]*hotdog_rescue_watchdog_start stage2[[:space:]]*$/ &&
					!stage9 {
				print
				marker(9)
				stage9 = 1
				next
			}

			/^[[:space:]]*setup_udev[[:space:]]*$/ && !stage10 {
				marker(10)
				print
				stage10 = 1
				next
			}

			{ print }

			END {
				if (!(stage6 && stage7 && stage8 && stage9 && stage10))
					exit 42
			}
		' "$init_2nd_original" > "$init_2nd_override"
	elif [ "$USERSPACE_STAGE_PROFILE" = udev-bounded-deep ]; then
		awk '
			function marker(stage) {
				print "/hotdog-userspace-stage " stage
			}

			/^#!\/bin\/busybox ash$/ && !stage6 {
				print
				marker(6)
				stage6 = 1
				next
			}

			/^[[:space:]]*\. \/init_functions_2nd\.sh[[:space:]]*$/ &&
					!stage7 {
				print
				marker(7)
				stage7 = 1
				next
			}

			/^[[:space:]]*hotdog_rescue_watchdog_start stage2[[:space:]]*$/ &&
					!stage8 {
				print
				marker(8)
				stage8 = 1
				next
			}

			/^[[:space:]]*setup_udev[[:space:]]*$/ && !stage9 {
				print
				marker(9)
				stage9 = 1
				next
			}

			/^[[:space:]]*setup_usb_network[[:space:]]*$/ && !stage10 {
				print
				marker(10)
				stage10 = 1
				next
			}

			{ print }

			END {
				if (!(stage6 && stage7 && stage8 && stage9 && stage10))
					exit 42
			}
		' "$init_2nd_original" > "$init_2nd_override"
	elif [ "$USERSPACE_STAGE_PROFILE" = udev-skip ]; then
		awk '
			function marker(stage) {
				print "/hotdog-userspace-stage " stage
			}

			/^[[:space:]]*setup_udev[[:space:]]*$/ && !stage6 {
				marker(6)
				marker(7)
				stage6 = stage7 = 1
				next
			}

			/^[[:space:]]*setup_usb_network[[:space:]]*$/ && !stage8 {
				marker(8)
				print
				marker(9)
				stage8 = stage9 = 1
				next
			}

			/^[[:space:]]*start_unudhcpd[[:space:]]*$/ && !stage10 {
				print
				marker(10)
				stage10 = 1
				next
			}

			{ print }

			END {
				if (!(stage6 && stage7 && stage8 && stage9 && stage10))
					exit 42
			}
		' "$init_2nd_original" > "$init_2nd_override"
	elif [ "$USERSPACE_STAGE_PROFILE" = usb-probe ]; then
		awk '
			function marker(stage) {
				print "/hotdog-userspace-stage " stage
			}

			/^[[:space:]]*setup_udev[[:space:]]*$/ && !stage6 {
				marker(6)
				print "if [ -d \"$CONFIGFS\" ]; then"
				marker(7)
				print "fi"
				print "if [ -n \"$(ls -A /sys/class/udc 2>/dev/null)\" ]; then"
				marker(8)
				print "fi"
				stage6 = stage7 = stage8 = 1
				next
			}

			/^[[:space:]]*setup_usb_network[[:space:]]*$/ && !stage9 {
				print
				print "if [ -n \"$(cat \"$CONFIGFS/g1/UDC\" 2>/dev/null)\" ]; then"
				marker(9)
				print "fi"
				stage9 = 1
				next
			}

			/^[[:space:]]*start_unudhcpd[[:space:]]*$/ && !stage10 {
				print
				print "hotdog_usb_probe_iface=\"$("
				print "\tcat \"$CONFIGFS/g1/functions/ncm.usb0/ifname\" 2>/dev/null ||"
				print "\tcat \"$CONFIGFS/g1/functions/rndis.usb0/ifname\" 2>/dev/null ||"
				print "\techo \"\""
				print ")\""
				print "if [ -n \"$hotdog_usb_probe_iface\" ] &&"
				print "\t\t[ -e \"/sys/class/net/$hotdog_usb_probe_iface\" ]; then"
				marker(10)
				print "fi"
				print "unset hotdog_usb_probe_iface"
				stage10 = 1
				next
			}

			{ print }

			END {
				if (!(stage6 && stage7 && stage8 && stage9 && stage10))
					exit 42
			}
		' "$init_2nd_original" > "$init_2nd_override"
	else
		awk '
			function marker(stage) {
				print "/hotdog-userspace-stage " stage
			}

			/^[[:space:]]*setup_udev[[:space:]]*$/ && !stage6 {
				marker(6)
				print
				stage6 = 1
				next
			}

			/^[[:space:]]*setup_usb_network[[:space:]]*$/ && !stage10 {
				print
				marker(10)
				stage10 = 1
				next
			}

			{ print }

			END {
				if (!(stage6 && stage10))
					exit 42
			}
		' "$init_2nd_original" > "$init_2nd_override"
	fi

	if [ "$USERSPACE_STAGE_PROFILE" = udev ] ||
			[ "$USERSPACE_STAGE_PROFILE" = udev-bounded ] ||
			[ "$USERSPACE_STAGE_PROFILE" = udev-bounded-deep ]; then
		"$HOTDOG_ROOT/scripts/extract-last-newc-member.py" \
			"$BASE_CPIO" init_functions_2nd.sh \
			> "$init_functions_2nd_original"
		if [ "$USERSPACE_STAGE_PROFILE" = udev ]; then
			awk '
				function marker(stage) {
					print "\t/hotdog-userspace-stage " stage
				}

				/^[[:space:]]*udevd -d --resolve-names=never[[:space:]]*$/ &&
						!stage7 {
					print
					marker(7)
					stage7 = 1
					next
				}

				/^[[:space:]]*udevadm trigger --type=devices --action=add[[:space:]]*$/ &&
						!stage8 {
					print
					marker(8)
					stage8 = 1
					next
				}

				/^[[:space:]]*udevadm settle[[:space:]]*$/ && !stage9 {
					print
					marker(9)
					stage9 = 1
					next
				}

				{ print }

				END {
					if (!(stage7 && stage8 && stage9))
						exit 42
				}
			' "$init_functions_2nd_original" > "$init_functions_2nd_override"
		else
			awk \
				-v deep="$([ "$USERSPACE_STAGE_PROFILE" = udev-bounded-deep ] && printf 1 || printf 0)" \
				-v bounded_exec="$([ -n "$BOUNDED_EXEC_HELPER" ] && printf 1 || printf 0)" '
				/^setup_udev\(\)[[:space:]]*\{/ && !runner {
					print "hotdog_stage_run() {"
					if (bounded_exec) {
						print "\tlocal stage=\"$1\" status=0"
						print "\tshift"
						print "\t/hotdog-bounded-exec --timeout 15 -- \"$@\""
						print "\tstatus=$?"
						print "\tif [ \"$status\" -eq 124 ]; then"
						print "\t\tprintf \"<4>HOTDOG_USERSPACE_STAGE_TIMEOUT=%s\\n\" \"$stage\" > /dev/kmsg 2>/dev/null || true"
						print "\t\treturn 124"
						print "\tfi"
						print "\t[ \"$stage\" = \"-\" ] || /hotdog-userspace-stage \"$stage\""
						print "\treturn \"$status\""
						print "}"
						print ""
						print
						runner = 1
						next
					}
					print "\tlocal stage=\"$1\" pid remaining=15 status=0"
					print "\tshift"
					print "\t\"$@\" &"
					print "\tpid=$!"
					print "\twhile kill -0 \"$pid\" 2>/dev/null && [ \"$remaining\" -gt 0 ]; do"
					print "\t\tsleep 1"
					print "\t\tremaining=$((remaining - 1))"
					print "\tdone"
					print "\tif ! kill -0 \"$pid\" 2>/dev/null; then"
					print "\t\twait \"$pid\""
					print "\t\tstatus=$?"
					print "\t\t[ \"$stage\" = \"-\" ] || /hotdog-userspace-stage \"$stage\""
					print "\t\treturn \"$status\""
					print "\tfi"
					print "\tprintf \"<4>HOTDOG_USERSPACE_STAGE_TIMEOUT=%s\\n\" \"$stage\" > /dev/kmsg 2>/dev/null || true"
					print "\tkill -TERM \"$pid\" 2>/dev/null || true"
					print "\tsleep 1"
					print "\tkill -KILL \"$pid\" 2>/dev/null || true"
					print "\treturn 124"
					print "}"
					print ""
					print
					runner = 1
					next
				}

				/^[[:space:]]*udevd -d --resolve-names=never[[:space:]]*$/ &&
						!stage7 {
					print deep ?
						"\thotdog_stage_run - udevd -d --resolve-names=never" :
						"\thotdog_stage_run 7 udevd -d --resolve-names=never"
					stage7 = 1
					next
				}

				/^[[:space:]]*udevadm trigger --type=devices --action=add[[:space:]]*$/ &&
						!stage8 {
					print deep ?
						"\thotdog_stage_run - udevadm trigger --type=devices --action=add" :
						"\thotdog_stage_run 8 udevadm trigger --type=devices --action=add"
					stage8 = 1
					next
				}

				/^[[:space:]]*udevadm settle[[:space:]]*$/ && !stage9 {
					print deep ?
						"\thotdog_stage_run - udevadm settle" :
						"\thotdog_stage_run 9 udevadm settle"
					stage9 = 1
					next
				}

				{ print }

				END {
					if (!(runner && stage7 && stage8 && stage9))
						exit 42
				}
			' "$init_functions_2nd_original" > "$init_functions_2nd_override"
		fi
		chmod 0644 "$init_functions_2nd_override"
	fi
	chmod 0755 "$init_2nd_override"
	cat >> "$list_file" <<EOF
file /hotdog-userspace-stage $USERSPACE_STAGE_HELPER 0755 0 0
file /init $init_override 0755 0 0
file /init_2nd.sh $init_2nd_override 0755 0 0
EOF
	if [ -s "$init_functions_2nd_override" ]; then
		cat >> "$list_file" <<EOF
file /init_functions_2nd.sh $init_functions_2nd_override 0644 0 0
EOF
	fi
	if [ "$SOURCE_INIT_2ND" -eq 1 ]; then
		grep -qx '\. /init_2nd\.sh' "$init_override"
		[ "$(grep -c '^\. /init_2nd\.sh$' "$init_override")" -eq 1 ]
	fi
fi

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

if [ -n "$REBOOT_MODE_HELPER" ] || [ -n "$APSS_WDT_HELPER" ] ||
		[ -n "$RESCUE_SUPERVISOR" ]; then
	"$HOTDOG_ROOT/scripts/extract-last-newc-member.py" \
		"$BASE_CPIO" hotdog_rescue_watchdog.sh > "$watchdog_original"
	if [ -n "$RESCUE_SUPERVISOR" ]; then
		cp "$watchdog_original" "$watchdog_override"
		cat >> "$watchdog_override" <<'SUPERVISOR_OVERRIDE'

# Static monotonic supervisor override. This later definition intentionally
# replaces the inherited shell-loop implementation above.
hotdog_rescue_watchdog_start() {
	local stage="$1"
	local pid sec

	if [ -e /tmp/hotdog_rescue_watchdog.started ]; then
		if [ -r /tmp/hotdog_rescue_watchdog.pid ]; then
			pid="$(cat /tmp/hotdog_rescue_watchdog.pid 2>/dev/null || true)"
			[ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && return 0
		fi
		hotdog_rescue_watchdog_log "stale supervisor marker at $stage; rearming"
		rm -f /tmp/hotdog_rescue_watchdog.started \
			/tmp/hotdog_rescue_watchdog.pid 2>/dev/null || true
	fi

	sec="$(hotdog_rescue_watchdog_cmdline_sec)" || return 0
	mkdir -p /tmp 2>/dev/null || true
	: > /tmp/hotdog_rescue_watchdog.started 2>/dev/null || true
	hotdog_rescue_watchdog_log \
		"static monotonic supervisor armed at $stage for ${sec}s"
	/hotdog-rescue-supervisor \
		--deadline "$sec" \
		--success-file /tmp/hotdog_rescue_watchdog.root-mounted \
		> /tmp/hotdog_rescue_supervisor.log 2>&1 &
	echo $! > /tmp/hotdog_rescue_watchdog.pid 2>/dev/null || true
}
SUPERVISOR_OVERRIDE
	else
		watchdog_input="$watchdog_original"
		if [ -n "$REBOOT_MODE_HELPER" ]; then
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
			' "$watchdog_input" > "$watchdog_restart2_override"
			watchdog_input="$watchdog_restart2_override"
		fi
		if [ -n "$APSS_WDT_HELPER" ]; then
		awk '
			/^hotdog_rescue_watchdog_start\(\)[[:space:]]*\{/ &&
					!disarm_function {
				print "hotdog_rescue_watchdog_disarm_hardware() {"
				print "\t[ -e /tmp/hotdog_apss_wdt.armed ] || return 0"
				print "\tif /hotdog-apss-wdt-control --disarm; then"
				print "\t\trm -f /tmp/hotdog_apss_wdt.armed 2>/dev/null || true"
				print "\t\thotdog_rescue_watchdog_log \"APSS hardware fallback disarmed\""
				print "\t\treturn 0"
				print "\tfi"
				print "\thotdog_rescue_watchdog_log \"APSS hardware fallback disarm failed\""
				print "\treturn 1"
				print "}"
				print ""
				print "hotdog_rescue_watchdog_kick_hardware() {"
				print "\t[ -e /tmp/hotdog_apss_wdt.armed ] || return 0"
				print "\tif /hotdog-apss-wdt-control --kick >/dev/null 2>&1; then"
				print "\t\treturn 0"
				print "\tfi"
				print "\tif [ ! -e /tmp/hotdog_apss_wdt.kick-failed ]; then"
				print "\t\t: > /tmp/hotdog_apss_wdt.kick-failed 2>/dev/null || true"
				print "\t\thotdog_rescue_watchdog_log \"APSS hardware fallback kick failed\""
				print "\tfi"
				print "\treturn 1"
				print "}"
				print ""
				print
				disarm_function = 1
				kick_function = 1
				next
			}

			/^[[:space:]]*local pid sec[[:space:]]*$/ && !hardware_local {
				print "\tlocal pid sec"
				hardware_local = 1
				next
			}

			/^[[:space:]]*sec="\$\(hotdog_rescue_watchdog_cmdline_sec\)" \|\| return 0[[:space:]]*$/ &&
					!armed {
				print
				print "\tmkdir -p /tmp 2>/dev/null || true"
				print "\tif /hotdog-apss-wdt-control --arm-bootloader 32; then"
				print "\t\tif : > /tmp/hotdog_apss_wdt.armed 2>/dev/null; then"
				print "\t\t\thotdog_rescue_watchdog_log \"APSS hardware fallback armed for 32s with periodic kicks\""
				print "\t\telse"
				print "\t\t\thotdog_rescue_watchdog_log \"APSS hardware marker failed; disarming fallback\""
				print "\t\t\t/hotdog-apss-wdt-control --disarm || true"
				print "\t\tfi"
				print "\telse"
				print "\t\thotdog_rescue_watchdog_log \"APSS hardware fallback unavailable\""
				print "\tfi"
				armed = 1
				next
			}

			/^[[:space:]]*while \[ "\$slept" -lt "\$sec" \]; do[[:space:]]*$/ &&
					!kick_loop {
				print
				print "\t\t\thotdog_rescue_watchdog_kick_hardware || true"
				kick_loop = 1
				next
			}

			/success marker seen (before deadline|at deadline)/ {
				print
				if ($0 ~ /before deadline/)
					indent = "\t\t\t\t"
				else
					indent = "\t\t\t"
				print indent "if hotdog_rescue_watchdog_disarm_hardware; then"
				print indent "\texit 0"
				print indent "fi"
				success = success + 1
				next
			}

			/^[[:space:]]*exit 0[[:space:]]*$/ && success > skipped {
				skipped = skipped + 1
				next
			}

			{ print }

			END {
				if (!(disarm_function && kick_function && hardware_local &&
				      armed && kick_loop &&
				      success == 2 && skipped == 2))
					exit 42
			}
			' "$watchdog_input" > "$watchdog_override"
		else
			cp "$watchdog_input" "$watchdog_override"
		fi
	fi
	chmod 0755 "$watchdog_override"
	cat >> "$list_file" <<EOF
file /hotdog_rescue_watchdog.sh $watchdog_override 0755 0 0
EOF
	if [ -n "$REBOOT_MODE_HELPER" ]; then
		printf 'file /hotdog-reboot-mode %s 0755 0 0\n' \
			"$REBOOT_MODE_HELPER" >> "$list_file"
	fi
	if [ -n "$APSS_WDT_HELPER" ]; then
		printf 'file /hotdog-apss-wdt-control %s 0755 0 0\n' \
			"$APSS_WDT_HELPER" >> "$list_file"
	fi
	if [ -n "$RESCUE_SUPERVISOR" ]; then
		printf 'file /hotdog-rescue-supervisor %s 0755 0 0\n' \
			"$RESCUE_SUPERVISOR" >> "$list_file"
	fi
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
if [ -n "$REBOOT_MODE_HELPER" ] || [ -n "$APSS_WDT_HELPER" ] ||
		[ -n "$RESCUE_SUPERVISOR" ]; then
	grep -qx 'hotdog_rescue_watchdog.sh' "$OUTDIR/overlay-contents.txt"
fi
if [ -n "$REBOOT_MODE_HELPER" ]; then
	grep -qx 'hotdog-reboot-mode' "$OUTDIR/overlay-contents.txt"
	grep -q 'requesting bootloader through RESTART2' "$watchdog_override"
	grep -q '/hotdog-reboot-mode bootloader' "$watchdog_override"
fi
if [ -n "$APSS_WDT_HELPER" ]; then
	grep -qx 'hotdog-apss-wdt-control' "$OUTDIR/overlay-contents.txt"
	grep -q 'APSS hardware fallback armed' "$watchdog_override"
	grep -q '/hotdog-apss-wdt-control --arm-bootloader' "$watchdog_override"
	grep -q '/hotdog-apss-wdt-control --kick' "$watchdog_override"
	grep -q '/hotdog-apss-wdt-control --disarm' "$watchdog_override"
fi
if [ -n "$RESCUE_SUPERVISOR" ]; then
	grep -qx 'hotdog-rescue-supervisor' "$OUTDIR/overlay-contents.txt"
	grep -q 'static monotonic supervisor armed' "$watchdog_override"
	grep -q '/hotdog-rescue-supervisor' "$watchdog_override"
	grep -q -- '--success-file /tmp/hotdog_rescue_watchdog.root-mounted' \
		"$watchdog_override"
fi
if [ -n "$BOUNDED_EXEC_HELPER" ]; then
	grep -qx 'hotdog-bounded-exec' "$OUTDIR/overlay-contents.txt"
	grep -q '/hotdog-bounded-exec --timeout 15 -- "$@"' \
		"$init_functions_2nd_override"
fi
if [ -n "$USERSPACE_STAGE_HELPER" ]; then
	grep -qx 'hotdog-userspace-stage' "$OUTDIR/overlay-contents.txt"
	grep -qx 'init' "$OUTDIR/overlay-contents.txt"
	grep -qx 'init_2nd.sh' "$OUTDIR/overlay-contents.txt"
	for stage in $(seq 0 10); do
		grep -qx "/hotdog-userspace-stage $stage" "$init_override"
	done
	[ "$(grep -c '^/hotdog-userspace-stage ' "$init_override")" -eq 11 ]
	if [ "$USERSPACE_STAGE_PROFILE" = handoff ] ||
			[ "$USERSPACE_STAGE_PROFILE" = handoff-deep ] ||
			[ "$USERSPACE_STAGE_PROFILE" = udev-bounded-deep ] ||
			[ "$USERSPACE_STAGE_PROFILE" = udev-skip ] ||
			[ "$USERSPACE_STAGE_PROFILE" = usb-probe ]; then
		for stage in $(seq 6 10); do
			grep -qx "/hotdog-userspace-stage $stage" "$init_2nd_override"
		done
		[ "$(grep -c '^/hotdog-userspace-stage ' "$init_2nd_override")" -eq 5 ]
	else
		grep -qx '/hotdog-userspace-stage 6' "$init_2nd_override"
		grep -qx '/hotdog-userspace-stage 10' "$init_2nd_override"
		[ "$(grep -c '^/hotdog-userspace-stage ' "$init_2nd_override")" -eq 2 ]
	fi
	if [ "$USERSPACE_STAGE_PROFILE" = udev-skip ] ||
			[ "$USERSPACE_STAGE_PROFILE" = usb-probe ]; then
		if grep -qx '[[:space:]]*setup_udev[[:space:]]*' \
				"$init_2nd_override"; then
			printf '%s profile retained setup_udev\n' \
				"$USERSPACE_STAGE_PROFILE" >&2
			exit 1
		fi
		grep -qx '[[:space:]]*setup_usb_network[[:space:]]*' \
			"$init_2nd_override"
			grep -qx '[[:space:]]*start_unudhcpd[[:space:]]*' \
				"$init_2nd_override"
	fi
	if [ "$USERSPACE_STAGE_PROFILE" = usb-probe ]; then
		grep -q '/sys/class/udc' "$init_2nd_override"
		grep -q '\$CONFIGFS/g1/UDC' "$init_2nd_override"
		grep -q '/sys/class/net/\$hotdog_usb_probe_iface' \
			"$init_2nd_override"
	fi
	if [ "$USERSPACE_STAGE_PROFILE" = udev ] ||
			[ "$USERSPACE_STAGE_PROFILE" = udev-bounded ] ||
			[ "$USERSPACE_STAGE_PROFILE" = udev-bounded-deep ]; then
		grep -qx 'init_functions_2nd.sh' "$OUTDIR/overlay-contents.txt"
		if [ "$USERSPACE_STAGE_PROFILE" = udev ]; then
			for stage in $(seq 7 9); do
				grep -qx "	/hotdog-userspace-stage $stage" \
					"$init_functions_2nd_override"
			done
			[ "$(grep -c '^[[:space:]]*/hotdog-userspace-stage ' \
				"$init_functions_2nd_override")" -eq 3 ]
		elif [ "$USERSPACE_STAGE_PROFILE" = udev-bounded ]; then
			for stage in $(seq 7 9); do
				grep -q "hotdog_stage_run $stage " \
					"$init_functions_2nd_override"
			done
		else
			[ "$(grep -c 'hotdog_stage_run - ' \
				"$init_functions_2nd_override")" -eq 3 ]
		fi
		if [ "$USERSPACE_STAGE_PROFILE" != udev ]; then
			grep -q 'HOTDOG_USERSPACE_STAGE_TIMEOUT=' \
				"$init_functions_2nd_override"
			if [ -n "$BOUNDED_EXEC_HELPER" ]; then
				grep -q '/hotdog-bounded-exec --timeout 15 --' \
					"$init_functions_2nd_override"
			else
				grep -q 'remaining=15' "$init_functions_2nd_override"
			fi
		fi
	fi
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
printf 'APSS watchdog helper: %s\n' "${APSS_WDT_HELPER:-none}"
printf 'Static rescue supervisor: %s\n' "${RESCUE_SUPERVISOR:-none}"
printf 'Static bounded exec helper: %s\n' "${BOUNDED_EXEC_HELPER:-none}"
printf 'Userspace stage helper: %s\n' "${USERSPACE_STAGE_HELPER:-none}"
printf 'Userspace stage profile: %s\n' "$USERSPACE_STAGE_PROFILE"
printf 'Source init_2nd handoff: %s\n' "$SOURCE_INIT_2ND"
printf 'Raw size: %s bytes\n' "$(stat -c %s "$output")"
cat "$OUTDIR/SHA256SUMS"
