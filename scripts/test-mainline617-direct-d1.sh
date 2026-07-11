#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source "$(dirname "$0")/env.sh"

BOOT_IMAGE="$HOTDOG_ROOT/images/pmos-experiments/2026-07-11-150002-mainline617-direct-repro-clean-c/boot.img"
RESTORE_IMAGE="$HOTDOG_ROOT/images/pmos-experiments/2026-07-11-130500-lineage414-r5-kexec-fbwait-nopaint-acm-rootwatchdog/boot-noefi-pmosdtb-watchdog-300s.img"
BOOT_WAIT_SEC="${HOTDOG_D1_BOOT_WAIT_SEC:-540}"

usage() {
	cat <<'USAGE'
Usage: test-mainline617-direct-d1.sh [safe test-boot-b-image.sh options]

Run the first pinned boot_b test for the D1 exact clean-c mainline 6.17 direct
boot image. This launcher hash-checks the D1 boot image and the stable no-paint
restore image, requires a healthy pmOS SSH source, prearms the rescue watcher,
expects a 6.17.0-sm8150 kernel after reboot, and restores boot_b back to the
stable system image when the generic boot_b tester sees a recovery path.

Pinned defaults:
  image:                 2026-07-11-150002 mainline617 direct clean-c boot.img
  restore image:         2026-07-11-130500 Lineage 4.14 no-paint pmOS bridge
  source:                --from-pmos-ssh
  rescue watcher:        --start-rescue-watcher
  expected kernel:       --expect-kernel-prefix 6.17.0-sm8150
  restore-after:         system
  boot wait:             HOTDOG_D1_BOOT_WAIT_SEC, default 540, minimum 480

Only these safe options are accepted and passed through:
  --serial SERIAL
  --expected-product "msmnile hotdog"
  --poll SEC
  --fastboot-timeout SEC
  --rescue-watch-timeout SEC
  --rescue-watch-poll SEC

Environment:
  HOTDOG_D1_BOOT_WAIT_SEC  Override the boot result wait, minimum 480 seconds.

This launcher rejects every other argument, including options that weaken
bootloader safety checks or change the pinned image, restore image, source mode,
expected kernel, restore mode, rescue watcher, or boot-wait policy.
USAGE
}

die() {
	printf 'ERROR: %s\n' "$1" >&2
	exit "${2:-1}"
}

check_sha() {
	local label="$1"
	local file="$2"
	local expected="$3"
	local actual

	[ -s "$file" ] || die "Missing $label: $file" 2
	actual="$(sha256sum "$file" | awk '{ print $1 }')"
	[ "$actual" = "$expected" ] || {
		printf '%s hash mismatch: expected %s, got %s\n' "$label" "$expected" "$actual" >&2
		exit 3
	}
}

validate_boot_wait() {
	case "$BOOT_WAIT_SEC" in
		''|*[!0-9]*) die "Invalid HOTDOG_D1_BOOT_WAIT_SEC: $BOOT_WAIT_SEC" 2 ;;
	esac
	[ "$BOOT_WAIT_SEC" -ge 480 ] || die "HOTDOG_D1_BOOT_WAIT_SEC must be at least 480, got $BOOT_WAIT_SEC" 2
}

validate_positive_arg() {
	local name="$1"
	local value="$2"

	case "$value" in
		''|*[!0-9]*) die "$name must be a positive integer, got: $value" 2 ;;
	esac
	[ "$value" -ge 1 ] || die "$name must be a positive integer, got: $value" 2
}

validate_nonempty_arg() {
	local name="$1"
	local value="$2"

	[ -n "$value" ] || die "$name must not be empty" 2
}

FORWARDED_ARGS=()

append_value_arg() {
	local name="$1"
	local value="$2"

	validate_nonempty_arg "$name" "$value"
	FORWARDED_ARGS+=("$name" "$value")
}

append_positive_arg() {
	local name="$1"
	local value="$2"

	validate_positive_arg "$name" "$value"
	FORWARDED_ARGS+=("$name" "$value")
}

parse_safe_options() {
	local value

	while [ "$#" -gt 0 ]; do
		case "$1" in
			--serial|--expected-product)
				[ "$#" -ge 2 ] || die "Missing value for $1" 2
				append_value_arg "$1" "$2"
				shift 2
				;;
			--serial=*|--expected-product=*)
				value="${1#*=}"
				append_value_arg "${1%%=*}" "$value"
				shift
				;;
			--poll|--fastboot-timeout|--rescue-watch-timeout|--rescue-watch-poll)
				[ "$#" -ge 2 ] || die "Missing value for $1" 2
				append_positive_arg "$1" "$2"
				shift 2
				;;
			--poll=*|--fastboot-timeout=*|--rescue-watch-timeout=*|--rescue-watch-poll=*)
				value="${1#*=}"
				append_positive_arg "${1%%=*}" "$value"
				shift
				;;
			--*)
				die "Unsupported option for pinned D1 test: $1" 2
				;;
			*)
				die "Unsupported positional argument for pinned D1 test: $1" 2
				;;
		esac
	done
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
	usage
	exit 0
fi

validate_boot_wait
parse_safe_options "$@"

hotdog_require_pmos_password

check_sha "D1 direct clean-c boot image" "$BOOT_IMAGE" f8e83ae15cb016612433b8a2d800d828b025d56c76640a2ebb41a3061baf8994
check_sha "stable no-paint restore image" "$RESTORE_IMAGE" 23fa53d382425e9414a2e2a4b6e10f42d59ce1d6623b7fa1fbebf21ffe0c8a50

exec "$HOTDOG_ROOT/scripts/test-boot-b-image.sh" \
	--image "$BOOT_IMAGE" \
	--restore-boot-b "$RESTORE_IMAGE" \
	--from-pmos-ssh \
	--start-rescue-watcher \
	--expect-kernel-prefix 6.17.0-sm8150 \
	--restore-after system \
	--boot-wait "$BOOT_WAIT_SEC" \
	"${FORWARDED_ARGS[@]}"
