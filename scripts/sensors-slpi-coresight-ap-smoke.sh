#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Bounded AP-side CoreSight STM smoke test for OnePlus hotdog e566.
# This script never enables QDSSC, never touches remoteproc and never reboots.

set -euo pipefail

EXPECTED_KERNEL_RELEASE="6.16.0-sm8150"
EXPECTED_ARCH="aarch64"
EXPECTED_HOSTNAME="hotdog"
EXPECTED_VERMAGIC="6.16.0-sm8150 SMP preempt mod_unload aarch64"
POLICY_NAME="ap-smoke"
POLICY_NODE="default"
POLICY_CHANNEL=10
CAPTURE_BLOCK_SIZE=4096
CAPTURE_BLOCKS=1
CAPTURE_TIMEOUT=3

SYSFS_ROOT="${HOTDOG_AP_SMOKE_SYSFS_ROOT:-/sys}"
CONFIGFS_ROOT="${HOTDOG_AP_SMOKE_CONFIGFS_ROOT:-/sys/kernel/config}"
DEV_ROOT="${HOTDOG_AP_SMOKE_DEV_ROOT:-/dev}"
PROC_MODULES="${HOTDOG_AP_SMOKE_PROC_MODULES:-/proc/modules}"

MODULE_PATH=""
MODULE_SHA256=""
SINK_NAME=""
CAPTURE_OUT=""

STM_NAME=""
STM_CLASS=""
STM_CS=""
SINK_CS=""
POLICY_DIR=""
POLICY_NODE_DIR=""

PRE_STM_CORE_LOADED=0
PRE_STM_P_BASIC_LOADED=0
INTRODUCED_STM_CORE=0
INTRODUCED_STM_P_BASIC=0
INTRODUCED_POLICY=0
INTRODUCED_POLICY_NODE=0
INTRODUCED_SOURCE_ENABLE=0
INTRODUCED_SINK_ENABLE=0
CLEANUP_STARTED=0

usage() {
	printf '%s\n' \
		"usage: $0 --module /path/stm_p_basic.ko --module-sha256 SHA256 --sink tmc_etf0 --capture-out /private/path.bin" \
		"" \
		"Safety:" \
		"  - requires hostname=hotdog, uname -m=aarch64 and uname -r=6.16.0-sm8150" \
		"  - validates module SHA256 and vermagic before loading" \
		"  - refuses ETR sinks and never changes buffer_size" \
		"  - writes one AP STM marker and captures at most 4096 bytes from the ETF device"
}

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

on_error() {
	local line=$1
	printf 'ERROR: command failed near line %s\n' "$line" >&2
}

on_signal() {
	local signal=$1
	printf 'ERROR: received %s, rolling back\n' "$signal" >&2
	exit 130
}

module_loaded() {
	local module=$1
	awk -v module="$module" '$1 == module { found = 1 } END { exit !found }' \
		"$PROC_MODULES"
}

read_one_line() {
	local path=$1
	if [[ -r "$path" ]]; then
		sed -n '1p' "$path"
	else
		printf 'missing'
	fi
}

write_value() {
	local path=$1
	local value=$2
	printf '%s\n' "$value" > "$path"
}

cleanup() {
	local rc=$?
	local cleanup_rc=0

	trap - EXIT ERR INT TERM
	if [[ "$CLEANUP_STARTED" -eq 1 ]]; then
		exit "$rc"
	fi
	CLEANUP_STARTED=1
	set +e

	if [[ "$INTRODUCED_SOURCE_ENABLE" -eq 1 && -n "$STM_CS" ]]; then
		write_value "$STM_CS/enable_source" 0 || cleanup_rc=1
	fi

	if [[ "$INTRODUCED_SINK_ENABLE" -eq 1 && -n "$SINK_CS" ]]; then
		write_value "$SINK_CS/enable_sink" 0 || cleanup_rc=1
	fi

	if [[ "$INTRODUCED_POLICY_NODE" -eq 1 && -n "$POLICY_NODE_DIR" ]]; then
		if [[ "$CONFIGFS_ROOT" != "/sys/kernel/config" ]]; then
			rm -f "$POLICY_NODE_DIR/masters" "$POLICY_NODE_DIR/channels"
		fi
		rmdir "$POLICY_NODE_DIR" || cleanup_rc=1
	fi

	if [[ "$INTRODUCED_POLICY" -eq 1 && -n "$POLICY_DIR" ]]; then
		rmdir "$POLICY_DIR" || cleanup_rc=1
	fi

	if [[ "$INTRODUCED_STM_P_BASIC" -eq 1 ]]; then
		modprobe -r stm_p_basic || cleanup_rc=1
	fi

	if [[ "$INTRODUCED_STM_CORE" -eq 1 ]]; then
		modprobe -r stm_core || cleanup_rc=1
	fi

	if [[ "$INTRODUCED_SOURCE_ENABLE" -eq 1 && -n "$STM_CS" ]]; then
		[[ "$(read_one_line "$STM_CS/enable_source")" == "0" ]] || cleanup_rc=1
	fi

	if [[ "$INTRODUCED_SINK_ENABLE" -eq 1 && -n "$SINK_CS" ]]; then
		[[ "$(read_one_line "$SINK_CS/enable_sink")" == "0" ]] || cleanup_rc=1
	fi

	if [[ "$INTRODUCED_POLICY_NODE" -eq 1 && -n "$POLICY_NODE_DIR" ]]; then
		[[ ! -e "$POLICY_NODE_DIR" ]] || cleanup_rc=1
	fi

	if [[ "$INTRODUCED_POLICY" -eq 1 && -n "$POLICY_DIR" ]]; then
		[[ ! -e "$POLICY_DIR" ]] || cleanup_rc=1
	fi

	if [[ "$INTRODUCED_STM_P_BASIC" -eq 1 ]]; then
		! module_loaded stm_p_basic || cleanup_rc=1
	fi

	if [[ "$INTRODUCED_STM_CORE" -eq 1 ]]; then
		! module_loaded stm_core || cleanup_rc=1
	fi

	if [[ "$cleanup_rc" -ne 0 ]]; then
		printf 'ERROR: rollback verification failed\n' >&2
		if [[ "$rc" -eq 0 ]]; then
			rc=1
		fi
	fi

	exit "$rc"
}

trap cleanup EXIT
trap 'on_error "$LINENO"' ERR
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM

parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--module)
			[[ $# -ge 2 ]] || die "--module needs an argument"
			MODULE_PATH=$2
			shift 2
			;;
		--module-sha256)
			[[ $# -ge 2 ]] || die "--module-sha256 needs an argument"
			MODULE_SHA256=$2
			shift 2
			;;
		--sink)
			[[ $# -ge 2 ]] || die "--sink needs an argument"
			SINK_NAME=$2
			shift 2
			;;
		--capture-out)
			[[ $# -ge 2 ]] || die "--capture-out needs an argument"
			CAPTURE_OUT=$2
			shift 2
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			die "unknown argument: $1"
			;;
		esac
	done
}

validate_args() {
	[[ -n "$MODULE_PATH" ]] || die "--module is required"
	[[ -n "$MODULE_SHA256" ]] || die "--module-sha256 is required"
	[[ -n "$SINK_NAME" ]] || die "--sink is required"
	[[ -n "$CAPTURE_OUT" ]] || die "--capture-out is required"

	[[ "$MODULE_PATH" == /* ]] || die "--module must be an absolute path"
	[[ -f "$MODULE_PATH" ]] || die "--module is not a regular file: $MODULE_PATH"
	[[ "$MODULE_SHA256" =~ ^[0-9a-fA-F]{64}$ ]] || die "--module-sha256 must be 64 hex characters"
	[[ "$SINK_NAME" != */* && "$SINK_NAME" != *..* && -n "$SINK_NAME" ]] || die "--sink must be a device name"
	[[ "$CAPTURE_OUT" == /* ]] || die "--capture-out must be an absolute path"
	[[ ! -e "$CAPTURE_OUT" ]] || die "--capture-out already exists: $CAPTURE_OUT"
	[[ -d "$(dirname "$CAPTURE_OUT")" ]] || die "--capture-out parent does not exist"
	[[ -r "$PROC_MODULES" ]] || die "cannot read modules list: $PROC_MODULES"
}

attest_device() {
	local got_hostname got_arch got_release

	got_hostname=$(hostname)
	got_arch=$(uname -m)
	got_release=$(uname -r)

	[[ "$got_hostname" == "$EXPECTED_HOSTNAME" ]] || die "hostname mismatch: $got_hostname"
	[[ "$got_arch" == "$EXPECTED_ARCH" ]] || die "architecture mismatch: $got_arch"
	[[ "$got_release" == "$EXPECTED_KERNEL_RELEASE" ]] || die "kernel release mismatch: $got_release"

	printf 'attestation: hostname=%s uname_m=%s uname_r=%s\n' \
		"$got_hostname" "$got_arch" "$got_release"
}

verify_module_file() {
	local actual_sha actual_vermagic

	actual_sha=$(sha256sum "$MODULE_PATH" | awk '{ print $1 }')
	[[ "$actual_sha" == "$MODULE_SHA256" ]] || die "module sha256 mismatch: $actual_sha"

	actual_vermagic=$(modinfo -F vermagic "$MODULE_PATH")
	[[ "$actual_vermagic" == "$EXPECTED_VERMAGIC" ]] || die "module vermagic mismatch: $actual_vermagic"

	printf 'module: path=%s sha256=%s vermagic=%s\n' \
		"$MODULE_PATH" "$actual_sha" "$actual_vermagic"
}

capture_module_prestate() {
	if module_loaded stm_core; then
		PRE_STM_CORE_LOADED=1
	fi
	if module_loaded stm_p_basic; then
		PRE_STM_P_BASIC_LOADED=1
	fi

	printf 'module-prestate: stm_core=%s stm_p_basic=%s\n' \
		"$PRE_STM_CORE_LOADED" "$PRE_STM_P_BASIC_LOADED"
}

load_modules() {
	if [[ "$PRE_STM_CORE_LOADED" -eq 0 ]]; then
		modprobe stm_core
		module_loaded stm_core || die "stm_core did not load"
		INTRODUCED_STM_CORE=1
	fi

	if [[ "$PRE_STM_P_BASIC_LOADED" -eq 0 ]]; then
		insmod "$MODULE_PATH"
		module_loaded stm_p_basic || die "stm_p_basic did not load"
		INTRODUCED_STM_P_BASIC=1
	fi
}

collect_matching_devices() {
	local root=$1
	local kind=$2
	local path base

	shopt -s nullglob
	for path in "$root"/*; do
		[[ -d "$path" ]] || continue
		base=$(basename "$path")
		case "$kind" in
		stm)
			[[ "$base" == stm* && -e "$path/enable_source" ]] && printf '%s\n' "$base"
			;;
		etf)
			[[ "$base" == *etf* && -e "$path/enable_sink" && ! -e "$path/buffer_size" ]] && printf '%s\n' "$base"
			;;
		etr)
			[[ "$base" == *etr* || -e "$path/buffer_size" ]] && printf '%s\n' "$base"
			;;
		esac
	done
	shopt -u nullglob
}

enumerate_coresight() {
	local cs_root="$SYSFS_ROOT/bus/coresight/devices"
	local stm_class_root="$SYSFS_ROOT/class/stm"
	local stms class_stms etfs etrs sink_match

	[[ -d "$cs_root" ]] || die "missing CoreSight sysfs root: $cs_root"
	[[ -d "$stm_class_root" ]] || die "missing STM class root: $stm_class_root"

	mapfile -t stms < <(collect_matching_devices "$cs_root" stm)
	mapfile -t class_stms < <(find "$stm_class_root" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort)
	mapfile -t etfs < <(collect_matching_devices "$cs_root" etf | sort)
	mapfile -t etrs < <(collect_matching_devices "$cs_root" etr | sort)

	printf 'coresight-stm-devices: %s\n' "${stms[*]:-none}"
	printf 'stm-class-devices: %s\n' "${class_stms[*]:-none}"
	printf 'coresight-etf-candidates: %s\n' "${etfs[*]:-none}"
	printf 'coresight-etr-candidates: %s\n' "${etrs[*]:-none}"

	[[ "${#stms[@]}" -eq 1 && "${stms[0]}" == "stm0" ]] || die "expected exactly one CoreSight stm0"
	[[ "${#class_stms[@]}" -eq 1 && "${class_stms[0]}" == "stm0" ]] || die "expected exactly one STM class stm0"

	sink_match=0
	for etf in "${etfs[@]}"; do
		if [[ "$etf" == "$SINK_NAME" ]]; then
			sink_match=$((sink_match + 1))
		fi
	done
	[[ "$sink_match" -eq 1 ]] || die "sink is not an unambiguous ETF candidate: $SINK_NAME"

	SINK_CS="$cs_root/$SINK_NAME"
	[[ "$SINK_NAME" != *etr* && ! -e "$SINK_CS/buffer_size" ]] || die "refusing ETR/buffer_size sink: $SINK_NAME"

	STM_NAME=stm0
	STM_CLASS="$stm_class_root/$STM_NAME"
	STM_CS="$cs_root/$STM_NAME"
	POLICY_DIR="$CONFIGFS_ROOT/stp-policy/${STM_NAME}:p_basic.${POLICY_NAME}"
	POLICY_NODE_DIR="$POLICY_DIR/$POLICY_NODE"
}

capture_prestate() {
	local policies

	[[ -d "$CONFIGFS_ROOT/stp-policy" ]] || die "missing STM configfs policy root"
	[[ -e "$DEV_ROOT/stm0" ]] || die "missing STM devfs node: $DEV_ROOT/stm0"
	[[ -e "$DEV_ROOT/$SINK_NAME" ]] || die "missing ETF devfs node: $DEV_ROOT/$SINK_NAME"

	printf 'source-prestate: %s\n' "$(read_one_line "$STM_CS/enable_source")"
	printf 'sink-prestate: %s\n' "$(read_one_line "$SINK_CS/enable_sink")"
	printf 'stm-masters: %s\n' "$(read_one_line "$STM_CLASS/masters")"
	printf 'stm-channels: %s\n' "$(read_one_line "$STM_CLASS/channels")"
	printf 'sink-status: %s\n' "$(read_one_line "$SINK_CS/status")"
	printf 'sink-buffer-size: %s\n' "$(read_one_line "$SINK_CS/buffer_size")"
	printf 'sink-mgmt-rsz: %s\n' "$(read_one_line "$SINK_CS/mgmt/rsz")"

	policies=$(find "$CONFIGFS_ROOT/stp-policy" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort | tr '\n' ' ')
	printf 'policies-prestate: %s\n' "${policies:-none}"

	[[ "$(read_one_line "$STM_CS/enable_source")" == "0" ]] || die "STM source already enabled"
	[[ "$(read_one_line "$SINK_CS/enable_sink")" == "0" ]] || die "ETF sink already enabled"
	[[ ! -e "$POLICY_DIR" ]] || die "policy already exists: $POLICY_DIR"
}

create_policy() {
	local first_master last_master channels

	read -r first_master last_master < "$STM_CLASS/masters"
	channels=$(read_one_line "$STM_CLASS/channels")
	[[ "$first_master" =~ ^[0-9]+$ && "$last_master" =~ ^[0-9]+$ ]] || die "invalid STM masters range"
	[[ "$channels" =~ ^[0-9]+$ ]] || die "invalid STM channel count"
	[[ "$channels" -gt "$POLICY_CHANNEL" ]] || die "STM does not expose channel $POLICY_CHANNEL"

	if ! mkdir "$POLICY_DIR"; then
		die "failed to create STM p_basic policy; backend may be absent or busy: $POLICY_DIR"
	fi
	INTRODUCED_POLICY=1
	if ! mkdir "$POLICY_NODE_DIR"; then
		die "failed to create STM policy node: $POLICY_NODE_DIR"
	fi
	INTRODUCED_POLICY_NODE=1
	write_value "$POLICY_NODE_DIR/masters" "$first_master $first_master"
	write_value "$POLICY_NODE_DIR/channels" "$POLICY_CHANNEL $POLICY_CHANNEL"

	printf 'policy: %s masters=%s channels=%s\n' \
		"$POLICY_NODE_DIR" "$first_master" "$POLICY_CHANNEL"
}

run_smoke() {
	local marker

	marker="HOTDOG_STM_AP_SMOKE $(date -u +%Y%m%dT%H%M%SZ) pid=$$"

	write_value "$SINK_CS/enable_sink" 1
	INTRODUCED_SINK_ENABLE=1
	write_value "$STM_CS/enable_source" 1
	INTRODUCED_SOURCE_ENABLE=1

	printf '%s\n' "$marker" > "$DEV_ROOT/stm0"
	write_value "$STM_CS/enable_source" 0

	timeout "$CAPTURE_TIMEOUT" dd if="$DEV_ROOT/$SINK_NAME" of="$CAPTURE_OUT" \
		bs="$CAPTURE_BLOCK_SIZE" count="$CAPTURE_BLOCKS" status=none

	printf 'marker: %s\n' "$marker"
	stat --printf='capture: path=%n size=%s\n' "$CAPTURE_OUT"
	sha256sum "$CAPTURE_OUT"
}

main() {
	parse_args "$@"
	validate_args
	attest_device
	verify_module_file
	capture_module_prestate
	load_modules
	enumerate_coresight
	capture_prestate
	create_policy
	run_smoke
}

main "$@"
