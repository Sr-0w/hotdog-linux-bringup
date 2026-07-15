#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source "$(dirname "$0")/env.sh"
# shellcheck disable=SC1091
source "$(dirname "$0")/phone-lock.sh"

PYTHON_BIN="${EDL_PYTHON_BIN:-$HOTDOG_ROOT/tools/venvs/edl/bin/python}"
EDL_SOURCE="${EDL_SOURCE:-$HOTDOG_ROOT/src/qualcomm/edl}"
HELPER="$HOTDOG_ROOT/helpers/hotdog_sahara_900e.py"

usage() {
	cat <<'USAGE'
Usage: qualcomm-900e-autorescue.sh inspect|reset

Operate on the configured hotdog target only while Qualcomm 05c6:900e is
visible. "inspect" reads the experimental breadcrumb and restart reason from
physical memory. "reset" sends SAHARA_RESET_REQ. Neither action reads or
writes phone storage.
USAGE
}

log() {
	printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

die() {
	log "ERROR: $1"
	exit "${2:-1}"
}

cleanup() {
	phone_lock_release || true
}
trap cleanup EXIT

case "${1:-}" in
	-h|--help)
		usage
		exit 0
		;;
	inspect|reset)
		action="$1"
		;;
	*)
		usage >&2
		exit 2
		;;
esac
[ "$#" -eq 1 ] || die "This command accepts exactly one action" 2

hotdog_require_target_serial
command -v lsusb >/dev/null 2>&1 || die "Missing command: lsusb" 127
[ -x "$PYTHON_BIN" ] || die "Missing EDL Python runtime: $PYTHON_BIN" 127
[ -d "$EDL_SOURCE/edlclient" ] || die "Missing bkerler/edl source: $EDL_SOURCE" 127
[ -r "$HELPER" ] || die "Missing Sahara helper: $HELPER" 127
lsusb -d 05c6:900e 2>/dev/null | grep -q . || die "Qualcomm 05c6:900e is not visible" 3

stamp="$(date +%F-%H%M%S)"
run_dir="$HOTDOG_LOG_ROOT/qualcomm-900e-autorescue-$action-$stamp"
mkdir -p "$run_dir"
exec > >(tee "$run_dir/run.log") 2>&1

log "Run directory: $run_dir"
log "Action: $action"
log "Target serial: $HOTDOG_TARGET_SERIAL"
log "Phone storage access: none"
phone_lock_acquire "Qualcomm 900e Sahara $action" 0 || die "Could not acquire phone-operation lock" 4

"$PYTHON_BIN" -u "$HELPER" "$action" \
	--edl-source "$EDL_SOURCE" \
	--serial "$HOTDOG_TARGET_SERIAL"
log "Sahara $action completed"
