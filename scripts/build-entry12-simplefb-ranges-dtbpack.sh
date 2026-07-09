#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Usage: build-entry12-simplefb-ranges-dtbpack.sh [options]

Build a hotdog stock multi-DTB pack variant where entry 12 keeps the existing
simple-framebuffer node, but fixes address translation for simplefb/fbcon by
adding ranges; below /chosen and using absolute stdout-path strings.

Options:
  --source-pack FILE  Source concatenated DTB pack.
  --outdir DIR        Output directory. Default: timestamped build/experiments dir.
  --entry N           Entry index to patch. Default: 12.
  -h, --help          Show this help.
USAGE
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

note() {
  printf '[build-entry12-simplefb-ranges-dtbpack] %s\n' "$*"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/env.sh"

source_pack="$HOTDOG_ROOT/build/experiments/2026-07-09-142300-stock-dtb-pack-entry12-simplefb/stock-dtb-pack-entry12-simplefb-x8-stdout.dtbpack"
entry_index=12
outdir=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --source-pack)
      [ "$#" -ge 2 ] || die "--source-pack requires a value"
      source_pack="$2"
      shift
      ;;
    --outdir)
      [ "$#" -ge 2 ] || die "--outdir requires a value"
      outdir="$2"
      shift
      ;;
    --entry)
      [ "$#" -ge 2 ] || die "--entry requires a value"
      entry_index="$2"
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

[[ "$entry_index" =~ ^[0-9]+$ ]] || die "--entry must be a non-negative integer"
[ -s "$source_pack" ] || die "missing source pack: $source_pack"

require_cmd python3
require_cmd dtc
require_cmd sha256sum

if [ -z "$outdir" ]; then
  outdir="$HOTDOG_ROOT/build/experiments/$(date +%F-%H%M%S)-stock-dtb-pack-entry${entry_index}-simplefb-ranges"
fi

entries_dir="$outdir/entries"
work_dir="$outdir/work"
output_pack="$outdir/stock-dtb-pack-entry${entry_index}-simplefb-ranges-stdout.dtbpack"
mkdir -p "$entries_dir" "$work_dir"

note "splitting source pack"
python3 - "$source_pack" "$entries_dir" <<'PY'
import pathlib
import struct
import sys

source = pathlib.Path(sys.argv[1])
outdir = pathlib.Path(sys.argv[2])
data = source.read_bytes()
offset = 0
index = 0
magic = 0xD00DFEED
while offset < len(data):
    if offset + 8 > len(data):
        raise SystemExit(f"trailing data at offset {offset}")
    got, totalsize = struct.unpack(">II", data[offset:offset + 8])
    if got != magic:
        raise SystemExit(f"bad FDT magic at offset {offset}: 0x{got:08x}")
    end = offset + totalsize
    if end > len(data):
        raise SystemExit(f"entry {index} totalsize exceeds source pack")
    (outdir / f"entry-{index:02d}.dtb").write_bytes(data[offset:end])
    offset = end
    index += 1
print(index)
PY

entry_file="$entries_dir/entry-$(printf '%02d' "$entry_index").dtb"
[ -s "$entry_file" ] || die "entry $entry_index not present in source pack"

note "patching entry $entry_index"
orig_dts="$work_dir/entry-${entry_index}-orig.dts"
fixed_dts="$work_dir/entry-${entry_index}-ranges.dts"
dtc -I dtb -O dts "$entry_file" > "$orig_dts" 2> "$work_dir/entry-${entry_index}-orig-dtc.err" || true
python3 - "$orig_dts" "$fixed_dts" <<'PY'
import pathlib
import re
import sys

source = pathlib.Path(sys.argv[1])
dest = pathlib.Path(sys.argv[2])
text = source.read_text()

def patch_chosen(match: re.Match[str]) -> str:
    body = match.group(1)
    if not re.search(r"^\s*ranges;", body, flags=re.M):
        body = "\t\tranges;\n" + body
    body = re.sub(
        r'linux,stdout-path = "[^"]*";',
        'linux,stdout-path = "/chosen/framebuffer@9c000000";',
        body,
        count=1,
    )
    body = re.sub(
        r'\n(\s*)stdout-path = "[^"]*";',
        r'\n\1stdout-path = "/chosen/framebuffer@9c000000";',
        body,
        count=1,
    )
    return "chosen {\n" + body + "\n\t};"

patched, count = re.subn(
    r"chosen \{\n(.*?)\n\t\};",
    patch_chosen,
    text,
    count=1,
    flags=re.S,
)
if count != 1:
    raise SystemExit("could not find /chosen node")
if "framebuffer@9c000000" not in patched:
    raise SystemExit("patched DTS does not contain expected framebuffer node")
dest.write_text(patched)
PY

dtc -I dts -O dtb -o "$entry_file" "$fixed_dts" > "$work_dir/entry-${entry_index}-ranges-dtc.out" 2> "$work_dir/entry-${entry_index}-ranges-dtc.err"

note "repacking DTB pack"
: > "$output_pack"
for f in "$entries_dir"/entry-*.dtb; do
  cat "$f" >> "$output_pack"
done

source_sha="$(sha256sum "$source_pack")"
output_sha="$(sha256sum "$output_pack")"
entry_sha="$(sha256sum "$entry_file")"
{
  printf 'source pack: %s\n' "$source_sha"
  printf 'fixed pack: %s\n' "$output_sha"
  printf 'fixed entry%s: %s\n' "$entry_index" "$entry_sha"
  printf 'change: add ranges; under /chosen and use absolute stdout-path strings; keep framebuffer reg size from source entry\n'
} > "$outdir/properties.txt"
sha256sum "$output_pack" "$entry_file" > "$outdir/SHA256SUMS"

note "done"
printf 'DTB pack: %s\n' "$output_pack"
printf 'Properties: %s\n' "$outdir/properties.txt"
