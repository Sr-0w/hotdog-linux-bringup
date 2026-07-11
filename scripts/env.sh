#!/usr/bin/env bash
set -euo pipefail

HOTDOG_ROOT="${HOTDOG_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}"
HOTDOG_LOCAL_ENV="${HOTDOG_LOCAL_ENV:-$HOTDOG_ROOT/hotdog.env}"
if [ -r "$HOTDOG_LOCAL_ENV" ]; then
	# shellcheck source=/dev/null
	source "$HOTDOG_LOCAL_ENV"
fi
HOTDOG_PROJECT_DOCS="${HOTDOG_PROJECT_DOCS:-$HOTDOG_ROOT/docs}"
HOTDOG_DUMP_ROOT="${HOTDOG_DUMP_ROOT:-$HOTDOG_ROOT/android-dumps}"
HOTDOG_LOG_ROOT="${HOTDOG_LOG_ROOT:-$HOTDOG_ROOT/logs}"
HOTDOG_SRC_ROOT="${HOTDOG_SRC_ROOT:-$HOTDOG_ROOT/src}"
HOTDOG_TOOLS_ROOT="${HOTDOG_TOOLS_ROOT:-$HOTDOG_ROOT/tools}"
HOTDOG_BIN_ROOT="${HOTDOG_BIN_ROOT:-$HOTDOG_TOOLS_ROOT/bin}"
HOTDOG_PMAPORTS_SM8150="${HOTDOG_PMAPORTS_SM8150:-$HOTDOG_SRC_ROOT/postmarketos/pmaports-sm8150}"
HOTDOG_PMBOOTSTRAP_CONFIG="${HOTDOG_PMBOOTSTRAP_CONFIG:-$HOTDOG_ROOT/pmbootstrap_v3.cfg}"
HOTDOG_PMBOOTSTRAP_WORK="${HOTDOG_PMBOOTSTRAP_WORK:-$HOTDOG_ROOT/pmbootstrap-work}"
HOTDOG_STABLE_PMOS_BOOT_B="${HOTDOG_STABLE_PMOS_BOOT_B:-$HOTDOG_ROOT/images/pmos-experiments/2026-07-11-130500-lineage414-r5-kexec-fbwait-nopaint-acm-rootwatchdog/boot-noefi-pmosdtb-watchdog-300s.img}"
HOTDOG_FASTBOOT_USB_IDS="${HOTDOG_FASTBOOT_USB_IDS:-18d1:d00d}"
HOTDOG_TARGET_SERIAL="${HOTDOG_TARGET_SERIAL:-${ANDROID_SERIAL:-}}"
HOTDOG_PMOS_HOST="${HOTDOG_PMOS_HOST:-${PMOS_HOST:-172.16.42.1}}"
HOTDOG_PMOS_USER="${HOTDOG_PMOS_USER:-${PMOS_USER:-user}}"
HOTDOG_PMOS_PASSWORD="${HOTDOG_PMOS_PASSWORD:-${PMOS_PASSWORD:-}}"

export HOTDOG_ROOT HOTDOG_LOCAL_ENV HOTDOG_PROJECT_DOCS HOTDOG_DUMP_ROOT HOTDOG_LOG_ROOT
export HOTDOG_SRC_ROOT HOTDOG_TOOLS_ROOT HOTDOG_BIN_ROOT
export HOTDOG_PMAPORTS_SM8150 HOTDOG_PMBOOTSTRAP_CONFIG HOTDOG_PMBOOTSTRAP_WORK
export HOTDOG_STABLE_PMOS_BOOT_B HOTDOG_FASTBOOT_USB_IDS
export HOTDOG_TARGET_SERIAL HOTDOG_PMOS_HOST HOTDOG_PMOS_USER HOTDOG_PMOS_PASSWORD

hotdog_require_target_serial() {
	[ -n "$HOTDOG_TARGET_SERIAL" ] || {
		printf 'Set ANDROID_SERIAL or HOTDOG_TARGET_SERIAL before this operation.\n' >&2
		return 2
	}
}

hotdog_require_pmos_password() {
	[ -n "$HOTDOG_PMOS_PASSWORD" ] || {
		printf 'Set PMOS_PASSWORD or HOTDOG_PMOS_PASSWORD before this operation.\n' >&2
		return 2
	}
}

hotdog_fastboot_usb_visible() {
	local usb_id=""

	command -v lsusb >/dev/null 2>&1 || return 1
	for usb_id in $HOTDOG_FASTBOOT_USB_IDS; do
		if lsusb -d "$usb_id" 2>/dev/null | grep -q .; then
			return 0
		fi
	done
	return 1
}

hotdog_fastboot_devices() {
	if hotdog_fastboot_usb_visible; then
		fastboot devices -l
	fi
}
