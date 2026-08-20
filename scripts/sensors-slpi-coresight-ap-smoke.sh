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

	lsmod | awk -v module="$module" '
		NR == 1 && $1 == "Module" { next }
		$1 == module { found = 1 }
		END { exit !found }
	'
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

require_command() {
	local command=$1

	command -v "$command" >/dev/null 2>&1 || die "missing required command: $command"
}

verify_tooling() {
	local command
	local commands=(
		awk
		date
		dd
		find
		hostname
		insmod
		lsmod
		mkdir
		modinfo
		modprobe
		rmdir
		rmmod
		sed
		sha256sum
		sort
		timeout
		uname
		wc
	)

	if [[ "$CONFIGFS_ROOT" != "/sys/kernel/config" ]]; then
		commands+=(rm)
	fi

	for command in "${commands[@]}"; do
		require_command "$command"
	done

	find "$MODULE_PATH" -print >/dev/null 2>&1 || die "find -print is not supported"
}

list_child_paths() {
	local root=$1
	local path rel

	find "$root" -print | sort | while IFS= read -r path; do
		[[ "$path" == "$root" ]] && continue
		rel=${path#"$root"/}
		[[ "$rel" == "$path" ]] && continue
		[[ "$rel" == */* ]] && continue
		printf '%s\n' "$path"
	done
}

list_child_names() {
	local root=$1
	local path

	list_child_paths "$root" | while IFS= read -r path; do
		printf '%s\n' "${path##*/}"
	done
}

join_words() {
	local item joined=""

	while IFS= read -r item; do
		joined="${joined}${joined:+ }$item"
	done
	printf '%s' "$joined"
}

join_args() {
	local item joined=""

	for item in "$@"; do
		joined="${joined}${joined:+ }$item"
	done
	printf '%s' "${joined:-none}"
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
		if module_loaded stm_p_basic; then
			if ! rmmod stm_p_basic; then
				printf 'ERROR: rmmod stm_p_basic failed\n' >&2
				cleanup_rc=1
			fi
		fi
	fi

	if [[ "$INTRODUCED_STM_CORE" -eq 1 ]]; then
		if module_loaded stm_core; then
			if ! modprobe -r stm_core; then
				printf 'ERROR: modprobe -r stm_core failed\n' >&2
				cleanup_rc=1
			fi
		fi
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
	local capture_parent

	[[ -n "$MODULE_PATH" ]] || die "--module is required"
	[[ -n "$MODULE_SHA256" ]] || die "--module-sha256 is required"
	[[ -n "$SINK_NAME" ]] || die "--sink is required"
	[[ -n "$CAPTURE_OUT" ]] || die "--capture-out is required"

	[[ "$MODULE_PATH" == /* ]] || die "--module must be an absolute path"
	[[ -f "$MODULE_PATH" ]] || die "--module is not a regular file: $MODULE_PATH"
	[[ "$MODULE_SHA256" =~ ^[0-9a-fA-F]{64}$ ]] || die "--module-sha256 must be 64 hex characters"
	[[ "$SINK_NAME" != */* && "$SINK_NAME" != *..* && -n "$SINK_NAME" ]] || die "--sink must be a device name"
	[[ "$SINK_NAME" != tmc_etr* ]] || die "refusing ETR sink: $SINK_NAME"
	[[ "$SINK_NAME" == tmc_etf* ]] || die "sink must be a tmc_etf* device: $SINK_NAME"
	[[ "$CAPTURE_OUT" == /* ]] || die "--capture-out must be an absolute path"
	[[ ! -e "$CAPTURE_OUT" ]] || die "--capture-out already exists: $CAPTURE_OUT"
	capture_parent=${CAPTURE_OUT%/*}
	[[ -n "$capture_parent" ]] || capture_parent=/
	[[ -d "$capture_parent" ]] || die "--capture-out parent does not exist"
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

load_stm_core() {
	if [[ "$PRE_STM_CORE_LOADED" -eq 0 ]]; then
		if modprobe stm_core; then
			if module_loaded stm_core; then
				INTRODUCED_STM_CORE=1
			else
				die "stm_core did not load"
			fi
		else
			if module_loaded stm_core; then
				INTRODUCED_STM_CORE=1
				die "modprobe stm_core failed after partially loading stm_core"
			fi
			die "modprobe stm_core failed"
		fi
	fi
}

load_stm_p_basic() {
	if [[ "$PRE_STM_P_BASIC_LOADED" -eq 0 ]]; then
		if insmod "$MODULE_PATH"; then
			if module_loaded stm_p_basic; then
				INTRODUCED_STM_P_BASIC=1
			else
				die "stm_p_basic did not load"
			fi
		else
			if module_loaded stm_p_basic; then
				INTRODUCED_STM_P_BASIC=1
				die "insmod stm_p_basic failed after partially loading stm_p_basic"
			fi
			die "insmod stm_p_basic failed"
		fi
	fi
}

collect_matching_devices() {
	local root=$1
	local kind=$2
	local path base

	while IFS= read -r path; do
		[[ -d "$path" ]] || continue
		base=${path##*/}
		case "$kind" in
		stm)
			[[ "$base" == stm* && -e "$path/enable_source" ]] && printf '%s\n' "$base"
			;;
		etf)
			[[ "$base" == tmc_etf* && -e "$path/enable_sink" ]] && printf '%s\n' "$base"
			;;
		etr)
			[[ "$base" == tmc_etr* ]] && printf '%s\n' "$base"
			;;
		esac
	done < <(list_child_paths "$root")
}

connections_summary() {
	local device=$1

	if [[ -d "$device/connections" ]]; then
		list_child_names "$device/connections" | join_words
	else
		printf 'missing'
	fi
}

connection_tokens() {
	local device=$1
	local path

	[[ -d "$device/connections" ]] || return 0

	while IFS= read -r path; do
		printf '%s\n' "${path##*/}"
		if [[ -f "$path" && -r "$path" ]]; then
			sed -n '1,16p' "$path"
		fi
	done < <(list_child_paths "$device/connections") |
		awk '
		{
			line = $0
			gsub(/[^[:alnum:]_]+/, " ", line)
			n = split(line, tokens, " ")
			for (i = 1; i <= n; i++)
				if (tokens[i] != "")
					print tokens[i]
		}
		' | sort
}

tokens_contain() {
	local wanted=$1
	shift
	local token

	for token in "$@"; do
		[[ "$token" == "$wanted" ]] && return 0
	done
	return 1
}

tokens_contain_other_etf() {
	local wanted=$1
	shift
	local token

	for token in "$@"; do
		[[ "$token" =~ ^tmc_etf[0-9]+$ && "$token" != "$wanted" ]] &&
			return 0
	done
	return 1
}

tokens_contain_other_stm() {
	local wanted=$1
	shift
	local token

	for token in "$@"; do
		[[ "$token" =~ ^stm[0-9]+$ && "$token" != "$wanted" ]] &&
			return 0
	done
	return 1
}

check_requested_connections() {
	local stm_connections sink_connections
	local stm_tokens sink_tokens

	stm_connections=$(connections_summary "$STM_CS")
	sink_connections=$(connections_summary "$SINK_CS")
	mapfile -t stm_tokens < <(connection_tokens "$STM_CS" | sort -u)
	mapfile -t sink_tokens < <(connection_tokens "$SINK_CS" | sort -u)

	printf 'stm-connections: %s\n' "$stm_connections"
	printf 'sink-connections: %s\n' "$sink_connections"
	printf 'stm-connection-tokens: %s\n' "$(join_args "${stm_tokens[@]}")"
	printf 'sink-connection-tokens: %s\n' "$(join_args "${sink_tokens[@]}")"

	if tokens_contain_other_etf "$SINK_NAME" "${stm_tokens[@]}"; then
		die "CoreSight connection metadata names a different ETF sink for $STM_NAME"
	fi
	if tokens_contain_other_stm "$STM_NAME" "${sink_tokens[@]}"; then
		die "CoreSight connection metadata names a different STM source for $SINK_NAME"
	fi

	if tokens_contain "$SINK_NAME" "${stm_tokens[@]}" ||
	   tokens_contain "$STM_NAME" "${sink_tokens[@]}"; then
		printf 'connections-check: graph-metadata-links %s to %s\n' \
			"$STM_NAME" "$SINK_NAME"
		return 0
	fi

	printf 'connections-check: connection graph not proven by sysfs names; using explicit requested sink %s\n' \
		"$SINK_NAME"
}

enumerate_coresight() {
	local phase=$1
	local allow_absent=${2:-0}
	local cs_root="$SYSFS_ROOT/bus/coresight/devices"
	local stm_class_root="$SYSFS_ROOT/class/stm"
	local stms class_stms etfs etrs
	local etf requested_matches=0

	printf 'coresight-enumeration-phase: %s\n' "$phase"

	if [[ ! -d "$cs_root" || ! -d "$stm_class_root" ]]; then
		printf 'coresight-topology-state: absent\n'
		if [[ -d "$cs_root" ]]; then
			printf 'coresight-root: present\n'
		else
			printf 'coresight-root: missing\n'
		fi
		if [[ -d "$stm_class_root" ]]; then
			printf 'stm-class-root: present\n'
		else
			printf 'stm-class-root: missing\n'
		fi
		[[ "$allow_absent" -eq 1 ]] && return 2
		die "missing CoreSight sysfs topology"
	fi

	mapfile -t stms < <(collect_matching_devices "$cs_root" stm)
	mapfile -t class_stms < <(list_child_names "$stm_class_root")
	mapfile -t etfs < <(collect_matching_devices "$cs_root" etf | sort)
	mapfile -t etrs < <(collect_matching_devices "$cs_root" etr | sort)

	if [[ "${#stms[@]}" -eq 0 && "${#class_stms[@]}" -eq 0 &&
	      "${#etfs[@]}" -eq 0 && "${#etrs[@]}" -eq 0 ]]; then
		printf 'coresight-topology-state: absent\n'
		[[ "$allow_absent" -eq 1 ]] && return 2
		die "missing CoreSight sysfs topology"
	fi

	printf 'coresight-topology-state: visible\n'
	printf 'coresight-stm-devices: %s\n' "${stms[*]:-none}"
	printf 'stm-class-devices: %s\n' "${class_stms[*]:-none}"
	printf 'coresight-etf-candidates: %s\n' "${etfs[*]:-none}"
	printf 'coresight-etr-candidates: %s\n' "${etrs[*]:-none}"

	[[ "${#stms[@]}" -eq 1 && "${stms[0]}" == "stm0" ]] || die "expected exactly one CoreSight stm0"
	[[ "${#class_stms[@]}" -eq 1 && "${class_stms[0]}" == "stm0" ]] || die "expected exactly one STM class stm0"

	for etf in "${etfs[@]}"; do
		if [[ "$etf" == "$SINK_NAME" ]]; then
			requested_matches=$((requested_matches + 1))
		fi
	done
	[[ "$requested_matches" -eq 1 ]] || die "requested ETF sink not found exactly once: $SINK_NAME"

	SINK_CS="$cs_root/$SINK_NAME"
	[[ -d "$SINK_CS" ]] || die "requested ETF sink sysfs directory is missing: $SINK_CS"
	[[ -e "$SINK_CS/enable_sink" ]] || die "requested ETF sink missing enable_sink: $SINK_CS"

	STM_NAME=stm0
	STM_CLASS="$stm_class_root/$STM_NAME"
	STM_CS="$cs_root/$STM_NAME"
	POLICY_DIR="$CONFIGFS_ROOT/stp-policy/${STM_NAME}:p_basic.${POLICY_NAME}"
	POLICY_NODE_DIR="$POLICY_DIR/$POLICY_NODE"

	check_requested_connections
}

prepare_coresight_topology() {
	if enumerate_coresight pre-load 1; then
		return 0
	fi

	[[ "$PRE_STM_CORE_LOADED" -eq 0 && "$PRE_STM_P_BASIC_LOADED" -eq 0 ]] ||
		die "CoreSight topology absent while STM modules are already loaded"

	printf 'coresight-topology-load: no pre-existing topology; loading stm_core before second enumeration\n'
	load_stm_core
	enumerate_coresight post-stm-core-load 0
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

	policies=$(list_child_names "$CONFIGFS_ROOT/stp-policy" | join_words)
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
	local capture_size

	marker="HOTDOG_STM_AP_SMOKE $(date -u +%Y%m%dT%H%M%SZ) pid=$$"

	write_value "$SINK_CS/enable_sink" 1
	INTRODUCED_SINK_ENABLE=1
	write_value "$STM_CS/enable_source" 1
	INTRODUCED_SOURCE_ENABLE=1

	printf '%s\n' "$marker" > "$DEV_ROOT/stm0"
	write_value "$STM_CS/enable_source" 0

	timeout "$CAPTURE_TIMEOUT" dd if="$DEV_ROOT/$SINK_NAME" of="$CAPTURE_OUT" \
		bs="$CAPTURE_BLOCK_SIZE" count="$CAPTURE_BLOCKS"

	printf 'marker: %s\n' "$marker"
	printf 'sink-buffer-size-post: %s\n' "$(read_one_line "$SINK_CS/buffer_size")"
	capture_size=$(wc -c < "$CAPTURE_OUT")
	printf 'capture: path=%s size=%s\n' "$CAPTURE_OUT" "$capture_size"
	sha256sum "$CAPTURE_OUT"
}

main() {
	parse_args "$@"
	validate_args
	verify_tooling
	attest_device
	verify_module_file
	capture_module_prestate
	prepare_coresight_topology
	capture_prestate
	load_stm_p_basic
	create_policy
	run_smoke
}

main "$@"
