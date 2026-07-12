#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/env.sh"
source "$(dirname "$0")/phone-lock.sh"

EDL_BIN="${EDL_BIN:-$HOTDOG_ROOT/tools/bin/edl}"
MIN_FREE_BYTES="${MIN_FREE_BYTES:-10737418240}"

usage() {
  cat <<'USAGE'
Usage: capture-qualcomm-900e-full-ram.sh

Capture every region exposed by Qualcomm Sahara memory-debug mode, including
the four 2 GiB DDR segments. This is read-only for storage. The Sahara client
resets the phone after a successful dump, so the persistent boot_b image then
boots normally.
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

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi
[ "$#" -eq 0 ] || die "This command takes no arguments" 2

for command in lsusb df awk tee find stat python3; do
  command -v "$command" >/dev/null 2>&1 || die "Missing command: $command" 127
done
[ -x "$EDL_BIN" ] || die "Missing EDL executable: $EDL_BIN" 127
lsusb -d 05c6:900e 2>/dev/null | grep -q . || die "Qualcomm 05c6:900e is not visible" 3

available_bytes="$(df -B1 --output=avail "$HOTDOG_LOG_ROOT" | awk 'NR == 2 { print $1 }')"
[[ "$available_bytes" =~ ^[0-9]+$ ]] || die "Could not determine free disk space" 3
[ "$available_bytes" -ge "$MIN_FREE_BYTES" ] || die "Less than $MIN_FREE_BYTES bytes are available" 3

stamp="$(date +%F-%H%M%S)"
run_dir="$HOTDOG_LOG_ROOT/qualcomm-900e-full-ram-$stamp"
mkdir -p "$run_dir"
exec > >(tee "$run_dir/run.log") 2>&1

log "Run directory: $run_dir"
log "Free bytes before dump: $available_bytes"
log "The dump path is read-only for phone storage and resets after completion"
phone_lock_acquire "Qualcomm 900e full RAM dump" 0 || die "Could not acquire phone-operation lock" 4

cd "$run_dir"
printf '%q ' "$EDL_BIN" --vid=0x05c6 --pid=0x900e memorydump > command.txt
printf '\n' >> command.txt
"$EDL_BIN" --vid=0x05c6 --pid=0x900e memorydump 2>&1 | tee edl-memorydump.txt

find memory -maxdepth 1 -type f -printf '%f\t%s\n' | sort > memory-files.tsv
stat -c '%n %s bytes' memory/DDRCS*.BIN 2>/dev/null | tee ddr-files.txt
if python3 "$HOTDOG_ROOT/scripts/extract-ramoops-console.py" \
  --scan-reservation memory/DDRCS0_0.BIN > ramoops-console.txt; then
  log "ramoops console extracted: $run_dir/ramoops-console.txt"
  tail -n 80 ramoops-console.txt | tee ramoops-console-tail.txt
else
  rm -f ramoops-console.txt
  log "No valid ramoops console was available in this dump"
fi
log "Full Sahara RAM capture completed"
log "Phone reset requested by the Sahara client"
