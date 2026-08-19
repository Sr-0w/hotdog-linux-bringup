#!/usr/bin/env python3
"""Read the SLPI's ULog buffers out of a remoteproc coredump.

The DSP keeps its logs in circular buffers in the carveout, and a coredump is
that carveout. Each buffer is a header carrying its name inline, a pointer to
its data, and read/write offsets; the headers are chained. Records hold a
64-bit timestamp and a pointer to a printf format string, which lives in the
firmware image rather than in the dump -- so both are needed.

The firmware must be the one the phone actually runs, from /mnt/modem_b/image.
An OTA copy of a different build resolves the same pointers to different
strings and invents failures that never happened.

Usage:
  slpi-ulog-dump.py <coredump.elf> <firmware-dir> [buffer-name ...]

<firmware-dir> holds slpi.mdt and slpi.b00..bNN. With no buffer named, every
buffer with records is dumped.
"""
import os
import re
import struct
import sys

# The DSP's virtual addresses are a constant offset above the physical ones.
RELOC = 0x18E00000


def load_coredump(path):
    """Return (blob, [(phys, size, file_offset)]) for a 32-bit core file."""
    blob = open(path, "rb").read()
    if blob[:4] != b"\x7fELF" or blob[4] != 1:
        sys.exit("%s: not a 32-bit ELF core file" % path)
    phoff = struct.unpack("<I", blob[0x1C:0x20])[0]
    entsize = struct.unpack("<H", blob[0x2A:0x2C])[0]
    count = struct.unpack("<H", blob[0x2C:0x2E])[0]
    segs = []
    for i in range(count):
        o = phoff + i * entsize
        _, off, _, pa, fsz, _, _, _ = struct.unpack("<IIIIIIII", blob[o:o + 32])
        if fsz:
            segs.append((pa, fsz, off))
    return blob, segs


def load_firmware(dirname):
    """Return [(vaddr, size, bytes)] for the loadable segments of slpi.mbn."""
    mdt = open(os.path.join(dirname, "slpi.mdt"), "rb").read()
    phoff = struct.unpack("<I", mdt[0x1C:0x20])[0]
    entsize = struct.unpack("<H", mdt[0x2A:0x2C])[0]
    count = struct.unpack("<H", mdt[0x2C:0x2E])[0]
    segs = []
    for i in range(count):
        o = phoff + i * entsize
        _, _, va, _, fsz, _, _, _ = struct.unpack("<IIIIIIII", mdt[o:o + 32])
        if not fsz:
            continue
        part = os.path.join(dirname, "slpi.b%02d" % i)
        if os.path.exists(part):
            segs.append((va, fsz, open(part, "rb").read()))
    if not segs:
        sys.exit("%s: no slpi.bNN segments found" % dirname)
    return segs


class Image:
    def __init__(self, core, fw):
        self.blob, self.segs = core
        self.fw = fw

    def read(self, phys, n):
        for base, size, off in self.segs:
            if base <= phys < base + size:
                o = off + (phys - base)
                return self.blob[o:o + min(n, base + size - phys)]
        return b""

    def read_va(self, va, n):
        return self.read(va - RELOC, n)

    def u32(self, phys):
        raw = self.read(phys, 4)
        return struct.unpack("<I", raw)[0] if len(raw) == 4 else None

    def string(self, va):
        """A format string, resolved against the firmware image."""
        for base, size, data in self.fw:
            if base <= va < base + size:
                o = va - base
                end = data.find(b"\0", o)
                if end < 0:
                    return None
                try:
                    text = data[o:end].decode("ascii")
                except UnicodeDecodeError:
                    return None
                ok = all(32 <= ord(c) < 127 or c in "\t\n" for c in text)
                return text if ok else None
        return None


def find_buffers(img):
    """Scan for ULog headers: name inline at +0x08, data at +0x24, size at +0x28."""
    found = {}
    for base, size, off in img.segs:
        chunk = img.blob[off:off + size]
        for pos in range(0, len(chunk) - 0x60, 4):
            data_ptr, buf_size = struct.unpack("<II", chunk[pos + 0x24:pos + 0x2C])
            if buf_size < 256 or buf_size > (1 << 20) or buf_size & (buf_size - 1):
                continue
            if not 0xB0000000 <= data_ptr < 0xB2400000:
                continue
            raw = chunk[pos + 8:pos + 0x18]
            end = raw.find(b"\0")
            if end <= 0:
                continue
            try:
                name = raw[:end].decode("ascii")
            except UnicodeDecodeError:
                continue
            if not all(32 <= ord(c) < 127 for c in name):
                continue
            read_at, write_at = struct.unpack("<II", chunk[pos + 0x50:pos + 0x58])
            if write_at == 0:
                continue
            found[name] = dict(header=base + pos, data=data_ptr,
                               size=buf_size, read=read_at, write=write_at)
    return found


def records(img, buf):
    """Yield (timestamp, format_va, args) oldest first, following the wrap."""
    raw = img.read_va(buf["data"], buf["size"])
    if len(raw) < buf["size"]:
        return
    size = buf["size"]
    # A wrapped buffer starts mid-record; walk from the write pointer so the
    # first partial record is skipped rather than mis-parsed.
    start = buf["write"] % size if buf["write"] > size else 0
    pos, consumed = start, 0
    while consumed < size - 16:
        head = raw[pos:pos + 4] if pos + 4 <= size else raw[pos:] + raw[:pos + 4 - size]
        _, length = struct.unpack("<HH", head)
        if length < 16 or length > 256 or length % 4:
            pos = (pos + 4) % size
            consumed += 4
            continue
        body = b"".join(raw[(pos + i) % size:(pos + i) % size + 1]
                        for i in range(length))
        ts = struct.unpack("<Q", body[4:12])[0]
        fmt_va = struct.unpack("<I", body[12:16])[0]
        args = [struct.unpack("<I", body[i:i + 4])[0]
                for i in range(16, length, 4)]
        yield ts, fmt_va, args
        pos = (pos + length) % size
        consumed += length


def render(img, fmt, args):
    out, i = [], 0
    for token in re.findall(r"%[-#0-9.lu]*[sdxXupc%]|[^%]+|%", fmt):
        if len(token) > 1 and token.startswith("%"):
            kind = token[-1]
            if kind == "%":
                out.append("%")
                continue
            val = args[i] if i < len(args) else 0
            i += 1
            if kind == "s":
                text = img.string(val)
                out.append(text if text is not None else "0x%08x" % val)
            elif kind in "xX":
                out.append("0x%x" % val)
            elif kind == "d":
                out.append(str(val - (1 << 32) if val >= (1 << 31) else val))
            else:
                out.append(str(val))
        else:
            out.append(token)
    return "".join(out)


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__.strip())
    img = Image(load_coredump(sys.argv[1]), load_firmware(sys.argv[2]))
    wanted = sys.argv[3:]
    buffers = find_buffers(img)
    if not buffers:
        sys.exit("no ULog buffers found -- is this an SLPI coredump?")
    for name in sorted(buffers):
        if wanted and not any(w.lower() in name.lower() for w in wanted):
            continue
        buf = buffers[name]
        rows = list(records(img, buf))
        if not rows:
            continue
        print("== %s == %d octets ecrits, tampon de %d, %d enregistrements"
              % (name, buf["write"], buf["size"], len(rows)))
        for ts, fmt_va, args in rows:
            fmt = img.string(fmt_va)
            if fmt is None:
                print("  ts=%-12d <format 0x%08x hors image>" % (ts, fmt_va))
            else:
                print("  ts=%-12d %s" % (ts, render(img, fmt, args).replace("\t", " ")))
        print()


if __name__ == "__main__":
    main()
