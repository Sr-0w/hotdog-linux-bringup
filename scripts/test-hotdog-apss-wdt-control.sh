#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source "$(dirname "$0")/env.sh"

for command_name in dd od qemu-aarch64 truncate zig; do
	command -v "$command_name" >/dev/null 2>&1 || {
		printf 'Missing command: %s\n' "$command_name" >&2
		exit 127
	}
done

source_file="$HOTDOG_ROOT/helpers/hotdog-apss-wdt-control.c"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

fake_mem="$workdir/devmem"
helper="$workdir/hotdog-apss-wdt-control"
arm_log="$workdir/arm.log"
disable_log="$workdir/disable.log"
disarm_log="$workdir/disarm.log"
kick_log="$workdir/kick.log"

apss_wdt_phys=$((0x17c10000))
imem_reason_phys=$((0x146bf65c))
wdt_rst=$((apss_wdt_phys + 0x04))
wdt_en=$((apss_wdt_phys + 0x08))
wdt_bark=$((apss_wdt_phys + 0x10))
wdt_bite=$((apss_wdt_phys + 0x14))
restart_bootloader=$((0x77665500))
restart_normal=$((0x77665501))
timeout_sec=32
expected_ticks=$((timeout_sec * 32764))

read_u32() {
	local offset="$1"
	od -An -j "$offset" -N 4 -tu4 "$fake_mem" | tr -d '[:space:]'
}

expect_u32() {
	local label="$1" offset="$2" expected="$3" actual=""
	actual="$(read_u32 "$offset")"
	if [ "$actual" != "$expected" ]; then
		printf '%s mismatch: expected %s, got %s\n' \
			"$label" "$expected" "$actual" >&2
		exit 1
	fi
	printf '[apss-wdt-selftest] %s=%s\n' "$label" "$actual"
}

[ -s "$source_file" ] || {
	printf 'Missing helper source: %s\n' "$source_file" >&2
	exit 2
}
truncate -s "$((apss_wdt_phys + 0x1000))" "$fake_mem"

zig cc -target aarch64-linux-musl -static -Os -s \
	-Wall -Wextra -Werror \
	-DDEVMEM_PATH="\"$fake_mem\"" \
	-o "$helper" "$source_file"

set +e
qemu-aarch64 "$helper" --arm-bootloader 9 >/dev/null 2>&1
invalid_status=$?
set -e
[ "$invalid_status" -eq 2 ] || {
	printf 'Invalid timeout returned %s instead of 2\n' "$invalid_status" >&2
	exit 1
}

set +e
qemu-aarch64 "$helper" --arm-bootloader 33 >/dev/null 2>&1
invalid_status=$?
set -e
[ "$invalid_status" -eq 2 ] || {
	printf 'Overflowing timeout returned %s instead of 2\n' \
		"$invalid_status" >&2
	exit 1
}

qemu-aarch64 "$helper" --arm-bootloader "$timeout_sec" > "$arm_log"
grep -q '^HOTDOG_APSS_WDT_CONTROL_V3$' "$arm_log"
expect_u32 restart-reason "$imem_reason_phys" "$restart_bootloader"
expect_u32 watchdog-reset "$wdt_rst" 1
expect_u32 watchdog-enable "$wdt_en" 1
expect_u32 watchdog-bark "$wdt_bark" "$expected_ticks"
expect_u32 watchdog-bite "$wdt_bite" "$expected_ticks"

printf '\0\0\0\0' |
	dd of="$fake_mem" bs=1 seek="$wdt_rst" conv=notrunc status=none
expect_u32 watchdog-reset-cleared "$wdt_rst" 0
qemu-aarch64 "$helper" --kick > "$kick_log"
grep -q '^HOTDOG_APSS_WDT_CONTROL_V3$' "$kick_log"
expect_u32 watchdog-kick "$wdt_rst" 1
expect_u32 watchdog-enable-after-kick "$wdt_en" 1
expect_u32 restart-reason-after-kick "$imem_reason_phys" "$restart_bootloader"

qemu-aarch64 "$helper" --disable > "$disable_log"
grep -q '^HOTDOG_APSS_WDT_CONTROL_V3$' "$disable_log"
expect_u32 watchdog-disable "$wdt_en" 0
expect_u32 restart-reason-preserved "$imem_reason_phys" "$restart_bootloader"

qemu-aarch64 "$helper" --arm-bootloader "$timeout_sec" >/dev/null
qemu-aarch64 "$helper" --disarm > "$disarm_log"
grep -q '^HOTDOG_APSS_WDT_CONTROL_V3$' "$disarm_log"
expect_u32 watchdog-disarm "$wdt_en" 0
expect_u32 restart-reason-normal "$imem_reason_phys" "$restart_normal"

printf '[apss-wdt-selftest] all checks passed\n'
