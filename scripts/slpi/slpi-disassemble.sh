#!/bin/sh
# Disassemble the SLPI firmware one segment at a time, unambiguously.
#
# build-slpi-elf.py packs every segment into one ELF, which loads fine but
# reads badly: llvm-objdump emits some address ranges twice, so a lookup by
# address silently picks whichever copy came last. On the hotdog image that is
# 248398 duplicated addresses out of 1.69M lines, about 15% -- enough to land a
# search in the wrong function, which is what happened while chasing the sensor
# drivers.
#
# Restricting each run to one segment's address range gives one file per
# segment with every address unique, and tells you which segment a hit is in.
#
# Usage: slpi-disassemble.sh <dir with slpi.mdt and slpi.b??> <outdir>

set -eu

src=${1:?usage: slpi-disassemble.sh <firmware-dir> <outdir>}
out=${2:?usage: slpi-disassemble.sh <firmware-dir> <outdir>}
mkdir -p "$out"

here=$(dirname "$0")
full="$out/slpi-full.elf"
python3 "$here/build-slpi-elf.py" "$src" "$full" >/dev/null

# Segment 21 is 3.5 MB of executable BSS whose address range swallows segment
# 14 whole, so objdump covers that range twice and every seg14 address comes
# out duplicated. Retyping the content-free segments PT_NULL drops them.
python3 - "$full" <<'PY'
import struct, sys
p = sys.argv[1]
b = bytearray(open(p, "rb").read())
phoff = struct.unpack("<I", b[0x1C:0x20])[0]
es = struct.unpack("<H", b[0x2A:0x2C])[0]
n = struct.unpack("<H", b[0x2C:0x2E])[0]
for i in range(n):
    o = phoff + i * es
    typ, off, va, pa, fsz, msz, fl, al = struct.unpack("<IIIIIIII", b[o:o + 32])
    if fsz == 0:
        struct.pack_into("<I", b, o, 0)          # PT_NULL
open(p, "wb").write(bytes(b))
PY

python3 - "$src" "$out" "$full" <<'PY'
import os, struct, subprocess, sys

src, out, full = sys.argv[1], sys.argv[2], sys.argv[3]
mdt = open(os.path.join(src, "slpi.mdt"), "rb").read()
phoff = struct.unpack("<I", mdt[0x1C:0x20])[0]
entsize = struct.unpack("<H", mdt[0x2A:0x2C])[0]
count = struct.unpack("<H", mdt[0x2C:0x2E])[0]

made = []
for i in range(count):
    off = phoff + i * entsize
    _, _, va, _, fsz, _, flags, _ = struct.unpack("<IIIIIIII", mdt[off:off + 32])
    if not fsz or not flags & 1:          # loadable and executable only
        continue
    txt = os.path.join(out, "seg%02d.txt" % i)
    with open(txt, "w") as f:
        subprocess.run(["llvm-objdump", "-d",
                        "--start-address=0x%x" % va,
                        "--stop-address=0x%x" % (va + fsz),
                        full], stdout=f, check=True)
    made.append((i, va, fsz, txt))

for i, va, fsz, txt in made:
    print("seg%02d  va 0x%08x  %8d octets  ->  %s" % (i, va, fsz, txt))
PY
