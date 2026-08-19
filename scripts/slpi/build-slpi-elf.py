#!/usr/bin/env python3
"""Reassemble the SLPI PIL image into an ELF that llvm-objdump can read.

The firmware ships as slpi.mdt plus slpi.b00..b21, which no disassembler
accepts. The .mdt already carries the ELF header and program headers, so all
that is missing is placing each segment's bytes at an offset the headers point
at. The result loads as elf32-hexagon and disassembles with

    llvm-objdump -d slpi-full.elf

Take the segments from the handset's own modem partition, /mnt/modem_b/image,
not from an OTA package: they are different builds, and resolving a format
string against the wrong one silently yields a plausible but wrong message.
"""
import os
import struct
import sys


def main(src, out):
    mdt = open(os.path.join(src, "slpi.mdt"), "rb").read()
    phoff = struct.unpack("<I", mdt[0x1C:0x20])[0]
    entsize = struct.unpack("<H", mdt[0x2A:0x2C])[0]
    count = struct.unpack("<H", mdt[0x2C:0x2E])[0]

    header = bytearray(mdt[:phoff + count * entsize])
    page = 0x1000
    base = ((len(header) + page - 1) // page) * page

    body = bytearray()
    headers = []
    for i in range(count):
        off = phoff + i * entsize
        typ, _, va, pa, fsz, msz, flags, align = struct.unpack("<IIIIIIII",
                                                               mdt[off:off + 32])
        path = os.path.join(src, "slpi.b%02d" % i)
        data = open(path, "rb").read()[:fsz] if (fsz and os.path.exists(path)) else b""
        if fsz and len(data) < fsz:
            data += b"\0" * (fsz - len(data))
        new_off = base + len(body) if fsz else 0
        if fsz:
            body += data
            body += b"\0" * ((-len(body)) % page)
        headers.append((typ, new_off, va, pa, fsz, msz, flags, align))

    for i, ph in enumerate(headers):
        struct.pack_into("<IIIIIIII", header, phoff + i * entsize, *ph)

    open(out, "wb").write(bytes(header) + b"\0" * (base - len(header)) + bytes(body))
    print("%s: %d bytes, %d segments" % (out, os.path.getsize(out), count))


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: build-slpi-elf.py <dir with slpi.mdt and slpi.b??> <out.elf>")
    main(sys.argv[1], sys.argv[2])
