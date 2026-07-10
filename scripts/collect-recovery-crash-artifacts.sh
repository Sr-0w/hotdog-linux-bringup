#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/env.sh"

SERIAL="${ANDROID_SERIAL:-}"
OUT=""
PARTITIONS=(rawdump logdump logfs misc param devinfo)

usage() {
  cat <<'USAGE'
Usage: collect-recovery-crash-artifacts.sh --out DIR [options]

Collect recovery-side crash evidence after a failed boot attempt. This script
only uses recovery ADB reads. It does not reboot, flash, wipe, or write device
partitions.

It also attempts a raw recovery-side /dev/mem dump of the 0xa9800000 ramoops
window into ramoops-phys-a9800000-4m.img, then writes ramoops-marker-scan.txt
with any ENT1/ENT2/SWT3 RAM-marker hits. If recovery does not expose /dev/mem,
the scan records missing-or-empty-dump and collection continues.

Options:
  --out DIR       Output directory for collected artifacts.
  --serial SERIAL Target ADB serial.
  -h, --help     Show this help.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --out)
      [ "$#" -ge 2 ] || { echo "Missing value for --out" >&2; exit 2; }
      OUT="$2"
      shift
      ;;
    --serial)
      [ "$#" -ge 2 ] || { echo "Missing value for --serial" >&2; exit 2; }
      SERIAL="$2"
      export ANDROID_SERIAL="$SERIAL"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

[ -n "$OUT" ] || { usage >&2; exit 2; }

mkdir -p "$OUT"/{partitions,pstore}
exec > >(tee "$OUT/run.log") 2>&1

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

adb_do() {
  if [ -n "$SERIAL" ]; then
    adb -s "$SERIAL" "$@"
  else
    adb "$@"
  fi
}

adb_shell_capture() {
  local name="$1"
  shift
  adb_do shell "$@" > "$OUT/$name" 2>&1 || true
}

adb_exec_out_capture() {
  local name="$1"
  shift
  local adb_cmd=(adb)

  if [ -n "$SERIAL" ]; then
    adb_cmd+=(-s "$SERIAL")
  fi

  if ! timeout 60 "${adb_cmd[@]}" exec-out "$@" > "$OUT/$name" 2>"$OUT/$name.err"; then
    local rc=$?
    log "exec-out capture failed for $name with exit $rc"
    rm -f "$OUT/$name"
    printf 'failed exit=%s\n' "$rc" > "$OUT/$name.log"
  fi
}

scan_ram_marker_dump() {
  local image="$OUT/ramoops-phys-a9800000-4m.img"
  local report="$OUT/ramoops-marker-scan.txt"

  {
    echo "RAM marker scan for mainline head.S probe"
    echo "image=$image"
    echo "base=0xa9800000"
    echo

    if [ ! -s "$image" ]; then
      echo "missing-or-empty-dump"
      echo "Recovery probably lacks /dev/mem access, or the dump command failed."
      return 0
    fi

    echo "first 64 bytes as 32-bit words:"
    od -An -tx4 -N 64 "$image" 2>/dev/null || true
    echo

    scan_one_marker "ENT1" "1TNE" "offset 0x0, after preserve_boot_args"
    scan_one_marker "ENT2" "2TNE" "offset 0x4, after __cpu_setup"
    scan_one_marker "SWT3" "3TWS" "offset 0x8, at __primary_switch"
  } > "$report" 2>&1 || true
}

scan_one_marker() {
  local name="$1"
  local pattern="$2"
  local meaning="$3"
  local image="$OUT/ramoops-phys-a9800000-4m.img"
  local hits

  echo "===$name little-endian bytes: $(printf '%s' "$pattern" | od -An -tx1 | tr -s ' ' ' ' | sed 's/^ //')"
  echo "$meaning"
  hits="$(LC_ALL=C grep -aob -- "$pattern" "$image" 2>/dev/null || true)"
  if [ -z "$hits" ]; then
    echo "not-found"
  else
    while IFS=: read -r off match; do
      [ -n "$off" ] || continue
      printf 'offset=0x%x phys=0x%x match=%s\n' "$off" "$((0xa9800000 + off))" "$match"
    done <<EOF
$hits
EOF
  fi
  echo
}

resolve_partition_path() {
  local part="$1"

  adb_do shell "for base in /dev/block/by-name /dev/block/bootdevice/by-name /dev/block/platform/*/by-name; do if [ -e \"\$base/$part\" ]; then readlink -f \"\$base/$part\" 2>/dev/null || echo \"\$base/$part\"; exit 0; fi; done; exit 1" \
    2>/dev/null | tr -d '\r' | sed -n '1p'
}

dump_partition_if_present() {
  local part="$1"
  local remote_path=""
  local image="$OUT/partitions/$part.img"
  local log_file="$OUT/partitions/$part.dump.log"
  local adb_cmd=(adb)

  remote_path="$(resolve_partition_path "$part" || true)"
  if [ -z "$remote_path" ]; then
    log "Partition not present: $part"
    printf 'missing\n' > "$log_file"
    return 0
  fi

  printf '%s %s\n' "$part" "$remote_path" | tee -a "$OUT/partition-paths.txt"
  adb_do shell "ls -l '$remote_path'; blockdev --getsize64 '$remote_path' 2>/dev/null || true" \
    > "$OUT/partitions/$part.info.txt" 2>&1 || true

  log "Dumping partition $part from $remote_path"
  if [ -n "$SERIAL" ]; then
    adb_cmd+=(-s "$SERIAL")
  fi
  if timeout 180 "${adb_cmd[@]}" exec-out "dd if='$remote_path' bs=1048576 2>/dev/null" > "$image"; then
    sha256sum "$image" | tee "$OUT/partitions/$part.sha256"
  else
    local rc=$?
    log "Partition dump failed for $part with exit $rc"
    rm -f "$image"
    printf 'failed exit=%s\n' "$rc" > "$log_file"
  fi
}

main() {
  command -v adb >/dev/null 2>&1 || { echo "Missing adb" >&2; exit 127; }
  command -v sha256sum >/dev/null 2>&1 || { echo "Missing sha256sum" >&2; exit 127; }
  command -v timeout >/dev/null 2>&1 || { echo "Missing timeout" >&2; exit 127; }

  log "Output: $OUT"
  log "Serial: ${SERIAL:-auto}"

  adb_do devices -l > "$OUT/adb-devices.txt" 2>&1 || true
  adb_do root > "$OUT/adb-root.txt" 2>&1 || true
  sleep 2
  adb_do devices -l > "$OUT/adb-devices-after-root.txt" 2>&1 || true

  adb_shell_capture recovery-state.txt 'id; uname -a; cat /proc/cmdline; cat /proc/filesystems; mount; getprop 2>/dev/null || true'
  adb_shell_capture recovery-dmesg.txt 'dmesg 2>&1 || true'
  adb_shell_capture pstore-probe.txt 'set -x; rm -rf /tmp/hotdog-pstore; mkdir -p /tmp/hotdog-pstore; mount -t pstore pstore /tmp/hotdog-pstore 2>/tmp/hotdog-pstore.mount.err || true; cat /tmp/hotdog-pstore.mount.err 2>/dev/null || true; ls -la /tmp/hotdog-pstore 2>&1 || true; find /tmp/hotdog-pstore -maxdepth 1 -type f -print 2>&1 || true; ls -la /sys/fs/pstore 2>&1 || true'
  adb_do pull /tmp/hotdog-pstore "$OUT/pstore/tmp-hotdog-pstore" > "$OUT/adb-pull-tmp-hotdog-pstore.txt" 2>&1 || true

  adb_shell_capture last-kmsg-probe.txt 'for f in /proc/last_kmsg /sys/kernel/debug/last_kmsg /sys/fs/pstore/*; do [ -e "$f" ] || continue; echo "===$f"; cat "$f" 2>&1 || true; done'
  adb_shell_capture ramoops-sysfs-find.txt 'find /sys -maxdepth 5 \( -iname "*pstore*" -o -iname "*ramoops*" \) -print 2>&1 || true'
  adb_shell_capture ramoops-platform.txt 'ls -la /sys/devices/platform/a9800000.ramoops 2>&1 || true; cat /sys/devices/platform/a9800000.ramoops/uevent 2>&1 || true'
  adb_shell_capture ramoops-dt.txt 'base=/sys/firmware/devicetree/base/reserved-memory/ramoops@0xA9800000; ls -la "$base" 2>&1 || true; for f in "$base"/*; do [ -f "$f" ] || continue; echo "===$f"; od -An -tx1 "$f" 2>&1 || cat "$f" 2>&1 || true; done'
  adb_shell_capture pstore-kernel-support.txt 'echo "=== /proc/iomem"; cat /proc/iomem 2>&1 || true; echo "=== /proc/modules"; cat /proc/modules 2>&1 || true; echo "=== /sys/module pstore/ramoops"; find /sys/module -maxdepth 2 \( -iname "*pstore*" -o -iname "*ramoops*" \) -print 2>&1 || true; echo "=== kallsyms pstore/ramoops"; grep -E "pstore|ramoops|persistent_ram|kmsg_dump" /proc/kallsyms 2>&1 || true; echo "=== /dev/mem"; ls -l /dev/mem 2>&1 || true'
  adb_exec_out_capture ramoops-phys-a9800000-4m.img 'dd if=/dev/mem bs=4096 skip=694272 count=1024 2>/dev/null'
  scan_ram_marker_dump
  adb_shell_capture by-name-list.txt 'ls -l /dev/block/by-name 2>&1 || true; ls -l /dev/block/bootdevice/by-name 2>&1 || true; for base in /dev/block/platform/*/by-name; do ls -l "$base" 2>&1 || true; done'

  : > "$OUT/partition-paths.txt"
  for part in "${PARTITIONS[@]}"; do
    dump_partition_if_present "$part"
  done

  log "Done: $OUT"
  find "$OUT" -type f -size +0c ! -name SHA256SUMS ! -name run.log -print0 | sort -z | xargs -0 sha256sum > "$OUT/SHA256SUMS" 2>/dev/null || true
}

main "$@"
