#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/env.sh"

stamp="$(date +%F-%H%M%S)"
run_dir="$HOTDOG_LOG_ROOT/wait-pmos-then-test-mainline617-rammarker-$stamp"
mkdir -p "$run_dir"

exec > >(tee "$run_dir/run.log") 2>&1

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

host="${PMOS_HOST:-auto}"
user="${PMOS_USER:-user}"
password="${PMOS_PASSWORD:-147147}"
timeout_sec="${PMOS_WAIT_TIMEOUT_SEC:-86400}"
poll_sec="${PMOS_WAIT_POLL_SEC:-5}"

log "Run directory: $run_dir"
log "Waiting for pmOS SSH before launching mainline617 RAM-marker test"
log "Timeout: ${timeout_sec}s"

"$HOTDOG_ROOT/scripts/wait-pmos-usb-ssh.sh" \
  --host "$host" \
  --user "$user" \
  --password "$password" \
  --timeout "$timeout_sec" \
  --poll "$poll_sec" \
  > "$run_dir/wait-pmos-usb-ssh-wrapper.log" 2>&1

log "pmOS SSH is reachable; launching mainline617 RAM-marker boot test"
exec "$HOTDOG_ROOT/scripts/test-next-mainline617-rammarker.sh" --from-pmos-ssh
