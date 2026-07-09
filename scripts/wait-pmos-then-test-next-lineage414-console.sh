#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/env.sh"

PMOS_HOST="${PMOS_HOST:-auto}"
PMOS_USER="${PMOS_USER:-user}"
PMOS_PASSWORD="${PMOS_PASSWORD:-147147}"
WAIT_TIMEOUT_SEC="${WAIT_TIMEOUT_SEC:-86400}"
POLL_SEC="${POLL_SEC:-5}"

stamp="$(date +%F-%H%M%S)"
run_dir="$HOTDOG_LOG_ROOT/wait-pmos-then-test-lineage414-console-$stamp"
mkdir -p "$run_dir"
exec > >(tee "$run_dir/run.log") 2>&1

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

log "Run directory: $run_dir"
log "Waiting for pmOS SSH before launching lineage414 console/pstore test"
log "Timeout: ${WAIT_TIMEOUT_SEC}s"

"$HOTDOG_ROOT/scripts/wait-pmos-usb-ssh.sh" \
  --host "$PMOS_HOST" \
  --user "$PMOS_USER" \
  --password "$PMOS_PASSWORD" \
  --timeout "$WAIT_TIMEOUT_SEC" \
  --poll "$POLL_SEC" \
  > "$run_dir/wait-pmos-usb-ssh-wrapper.log" 2>&1

log "pmOS SSH is reachable; launching next boot_b test from SSH"
"$HOTDOG_ROOT/scripts/test-next-lineage414-console-pstore.sh" \
  --from-pmos-ssh \
  > "$run_dir/test-next-lineage414-console-pstore-wrapper.log" 2>&1

log "Done"
