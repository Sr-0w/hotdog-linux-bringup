#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: inspect-dtb-pack-simplefb.sh --dtb FILE [--entry N] [--outdir DIR]

Inspect a single DTB or concatenated Android DTB pack and report whether the
selected entry contains the hotdog simple-framebuffer / stdout-path wiring.

No adb, fastboot, SSH, or phone command is used.

Options:
  --dtb FILE     DTB or concatenated DTB pack to inspect.
  --entry N      Entry index to inspect from a pack. Default: 12.
  --outdir DIR   Keep split entry and DTS files in DIR.
  -h, --help     Show this help.
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

dtb=""
entry=12
outdir=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dtb)
      [ "$#" -ge 2 ] || die "--dtb requires a file"
      dtb="$2"
      shift
      ;;
    --entry)
      [ "$#" -ge 2 ] || die "--entry requires a value"
      entry="$2"
      shift
      ;;
    --outdir)
      [ "$#" -ge 2 ] || die "--outdir requires a directory"
      outdir="$2"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "unknown argument: $1"
      ;;
  esac
  shift
done

[ -n "$dtb" ] || die "--dtb is required"
[ -s "$dtb" ] || die "missing DTB file: $dtb"
[[ "$entry" =~ ^[0-9]+$ ]] || die "--entry must be a non-negative integer"

require_cmd python3
require_cmd dtc
require_cmd sha256sum

cleanup_dir=""
if [ -z "$outdir" ]; then
  cleanup_dir="$(mktemp -d)"
  outdir="$cleanup_dir"
else
  mkdir -p "$outdir"
fi
trap '[ -z "${cleanup_dir:-}" ] || rm -rf "$cleanup_dir"' EXIT

entry_dtb="$outdir/entry-$(printf '%02d' "$entry").dtb"
entry_dts="$outdir/entry-$(printf '%02d' "$entry").dts"
meta="$outdir/pack-meta.txt"

python3 - "$dtb" "$entry" "$entry_dtb" "$meta" <<'PY'
import pathlib
import struct
import sys

source = pathlib.Path(sys.argv[1])
wanted = int(sys.argv[2])
dest = pathlib.Path(sys.argv[3])
meta = pathlib.Path(sys.argv[4])
data = source.read_bytes()
magic = 0xD00DFEED
offset = 0
entries = []

while offset < len(data):
    if offset + 8 > len(data):
        raise SystemExit(f"trailing data at offset {offset}")
    got, totalsize = struct.unpack(">II", data[offset:offset + 8])
    if got != magic:
        raise SystemExit(f"bad FDT magic at offset {offset}: 0x{got:08x}")
    end = offset + totalsize
    if end > len(data):
        raise SystemExit(f"entry {len(entries)} exceeds input length")
    entries.append((offset, end, data[offset:end]))
    offset = end

if wanted >= len(entries):
    raise SystemExit(f"entry {wanted} not present; entries={len(entries)}")

dest.write_bytes(entries[wanted][2])
with meta.open("w") as f:
    f.write(f"entries={len(entries)}\n")
    f.write(f"selected_entry={wanted}\n")
    f.write(f"selected_offset={entries[wanted][0]}\n")
    f.write(f"selected_size={len(entries[wanted][2])}\n")
PY

dtc -I dtb -O dts -o "$entry_dts" "$entry_dtb" \
  > "$outdir/dtc.out" 2> "$outdir/dtc.err" || {
  sed -n '1,120p' "$outdir/dtc.err" >&2 || true
  die "dtc failed for selected entry"
}

has_line() {
  local label="$1"
  local pattern="$2"

  if grep -Eq "$pattern" "$entry_dts"; then
    printf '%s=yes\n' "$label"
  else
    printf '%s=no\n' "$label"
  fi
}

printf 'dtb=%s\n' "$dtb"
sha256sum "$dtb" | awk '{ print "dtb_sha256=" $1 }'
cat "$meta"
sha256sum "$entry_dtb" | awk '{ print "entry_sha256=" $1 }'
has_line chosen_node '^[[:space:]]*chosen[[:space:]]*\{'
has_line chosen_ranges '^[[:space:]]*ranges;'
has_line stdout_path 'stdout-path = "/chosen/framebuffer@9c000000";'
has_line linux_stdout_path 'linux,stdout-path = "/chosen/framebuffer@9c000000";'
has_line simplefb_node 'framebuffer@9c000000'
has_line simplefb_compatible 'compatible = "simple-framebuffer";'
has_line display0_alias 'display0 = "/chosen/framebuffer@9c000000";'

printf '\n== selected lines ==\n'
grep -nE 'chosen \{|ranges;|stdout-path|framebuffer@9c000000|compatible = "simple-framebuffer"|display0 = ' "$entry_dts" || true

printf '\nentry_dtb=%s\n' "$entry_dtb"
printf 'entry_dts=%s\n' "$entry_dts"
