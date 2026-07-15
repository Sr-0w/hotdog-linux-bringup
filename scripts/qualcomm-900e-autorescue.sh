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
Usage: qualcomm-900e-autorescue.sh inspect [--early-breadcrumb-address ADDRESS]
       qualcomm-900e-autorescue.sh reset

Operate on the configured hotdog target only while Qualcomm 05c6:900e is
visible. "inspect" reads the experimental breadcrumb and restart reason from
physical memory. "reset" sends SAHARA_RESET_REQ. Neither action reads or
writes phone storage. ADDRESS accepts decimal or a 0x-prefixed physical
address and reads one additional 64-byte diagnostic record.
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
shift

early_breadcrumb_address="${HOTDOG_EARLY_BREADCRUMB_PHYS:-}"
while [ "$#" -gt 0 ]; do
	case "$1" in
		--early-breadcrumb-address)
			[ "$action" = inspect ] || die "Early breadcrumb reads require inspect" 2
			[ "$#" -ge 2 ] || die "Missing value for $1" 2
			early_breadcrumb_address="$2"
			shift 2
			;;
		*)
			die "Unknown argument: $1" 2
			;;
	esac
done

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

helper_args=(
	"$action"
	--edl-source "$EDL_SOURCE"
	--serial "$HOTDOG_TARGET_SERIAL"
)
if [ "$action" = inspect ] && [ -n "$early_breadcrumb_address" ]; then
	helper_args+=(--early-breadcrumb-address "$early_breadcrumb_address")
	log "Additional early breadcrumb: $early_breadcrumb_address (64 bytes)"
fi

"$PYTHON_BIN" -u "$HELPER" "${helper_args[@]}"
log "Sahara $action completed"
