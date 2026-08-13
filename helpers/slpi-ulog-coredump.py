#!/usr/bin/env python3
"""Recover Qualcomm ULog RAM buffers from a remoteproc ELF coredump.

The tool is deliberately forensic: it never modifies the dump, and it only
resolves format-string pointers when the caller supplies the image relocation
for that ULog.  Pointer relocation is image-specific and must not be guessed
when producing evidence.
"""

import argparse
import fnmatch
import re
import struct
import sys
from dataclasses import dataclass


PT_LOAD = 1
ULOG_VERSION = 4
ULOG_HEADER_SIZE = 124
ULOG_NAME_SIZE = 24
ULOG_MAX_MESSAGE = 1024
ULOG_SUBTYPE_PRINTF = 1


@dataclass(frozen=True)
class Segment:
    offset: int
    address: int
    size: int


@dataclass(frozen=True)
class ULog:
    address: int
    name: str
    status: int
    buffer: int
    size: int
    reader_core: int
    writer_core: int
    feature_flags: int


class Dump:
    def __init__(self, path, pointer_relocation):
        self.data = open(path, "rb").read()
        self.pointer_relocation = pointer_relocation
        self.segments = self._elf_segments()

    def _elf_segments(self):
        data = self.data
        if data[:5] != b"\x7fELF\x01" or data[5] != 1:
            raise ValueError("expected a 32-bit little-endian ELF file")
        phoff = struct.unpack_from("<I", data, 28)[0]
        phentsize = struct.unpack_from("<H", data, 42)[0]
        phnum = struct.unpack_from("<H", data, 44)[0]
        segments = []
        for index in range(phnum):
            fields = struct.unpack_from("<IIIIIIII", data,
                                        phoff + index * phentsize)
            kind, offset, _vaddr, paddr, filesz, _memsz, _flags, _align = fields
            if kind == PT_LOAD and filesz:
                segments.append(Segment(offset, paddr, filesz))
        if not segments:
            raise ValueError("ELF contains no loadable segments")
        return segments

    def address_for_offset(self, offset):
        for segment in self.segments:
            if segment.offset <= offset < segment.offset + segment.size:
                return segment.address + offset - segment.offset
        raise KeyError("file offset 0x%x is outside PT_LOAD segments" % offset)

    def read(self, address, size):
        for segment in self.segments:
            if (segment.address <= address and
                    address + size <= segment.address + segment.size):
                offset = segment.offset + address - segment.address
                return self.data[offset:offset + size]
        raise KeyError("address 0x%x..0x%x is outside PT_LOAD segments" %
                       (address, address + size))

    def pointer_address(self, pointer):
        return pointer - self.pointer_relocation

    def read_pointer(self, pointer, size):
        return self.read(self.pointer_address(pointer), size)

    def string(self, pointer, relocation, limit=1024):
        address = pointer - relocation
        for segment in self.segments:
            if segment.address <= address < segment.address + segment.size:
                offset = segment.offset + address - segment.address
                available = segment.address + segment.size - address
                block = self.data[offset:offset + min(limit, available)]
                raw = block.split(b"\0", 1)[0]
                if (not raw or b"\0" not in block or
                        any(byte not in (9, 10, 13) and not 32 <= byte <= 126
                            for byte in raw)):
                    raise KeyError("pointer 0x%x is not an ASCII string" % pointer)
                return raw.decode("utf-8", "replace")
        raise KeyError("string pointer 0x%x does not map with relocation 0x%x" %
                       (pointer, relocation))

    def logs(self):
        found = []
        data = self.data
        for offset in range(0, len(data) - ULOG_HEADER_SIZE + 1, 4):
            if struct.unpack_from("<I", data, offset + 4)[0] != ULOG_VERSION:
                continue
            raw_name = data[offset + 8:offset + 8 + ULOG_NAME_SIZE]
            raw_name = raw_name.split(b"\0", 1)[0]
            if not raw_name or any(byte < 32 or byte > 126 for byte in raw_name):
                continue
            status, buffer, size, mask = struct.unpack_from("<IIII", data,
                                                            offset + 32)
            reader_core, writer_core = struct.unpack_from("<II", data,
                                                           offset + 72)
            if status & ~0xff or not size or size & (size - 1):
                continue
            if size < 64 or size > 1024 * 1024 or mask != size - 1:
                continue
            try:
                self.read_pointer(buffer, size)
                self.read_pointer(reader_core, 8)
                self.read_pointer(writer_core, 12)
                address = self.address_for_offset(offset)
            except KeyError:
                continue
            found.append(ULog(address, raw_name.decode("ascii"), status,
                              buffer, size, reader_core, writer_core,
                              data[offset + 106]))
        return found


def wrapped(ring, offset, size):
    mask = len(ring) - 1
    start = offset & mask
    if start + size <= len(ring):
        return ring[start:start + size]
    first = len(ring) - start
    return ring[start:] + ring[:size - first]


def messages(dump, log):
    ring = dump.read_pointer(log.buffer, log.size)
    read, _read_flags = struct.unpack("<II",
                                      dump.read_pointer(log.reader_core, 8))
    write, read_writer, usage = struct.unpack(
        "<III", dump.read_pointer(log.writer_core, 12))
    start = max(read, read_writer)
    if write < start or write - start > log.size:
        start = max(0, write - log.size)

    offset = start
    while offset < write:
        header = struct.unpack("<I", wrapped(ring, offset, 4))[0]
        length = (header >> 16) & 0xffff
        padded = (length + 3) & ~3
        if length < 4 or padded > ULOG_MAX_MESSAGE or offset + padded > write:
            yield offset, None, "invalid message length %d" % length
            break
        yield offset, wrapped(ring, offset, padded)[:length], None
        offset += padded
    return usage


_FORMAT = re.compile(
    r"%([#0 +\-]*)(\*|\d+)?(?:\.(\*|\d+))?([hljztL]{0,2})([diuoxXpsc])"
)


def render_printf(dump, fmt, args, relocation):
    values = iter(args)

    def next_value():
        try:
            return next(values)
        except StopIteration:
            return None

    def replacement(match):
        flags, width, precision, length, kind = match.groups()
        if width == "*":
            width = str(next_value())
        if precision == "*":
            precision = str(next_value())
        value = next_value()
        if value is None:
            return "<missing>"
        if length in ("ll", "j"):
            high = next_value()
            if high is None:
                return "<missing64>"
            value |= high << 32
        if kind == "s":
            try:
                text = dump.string(value, relocation)
            except KeyError:
                text = "<str@0x%08x>" % value
            if precision and precision.isdigit():
                text = text[:int(precision)]
            return text
        if kind == "c":
            return chr(value & 0xff)
        if kind == "p":
            return "0x%08x" % value
        bits = 64 if length in ("ll", "j") else 32
        if kind in "di" and value & (1 << (bits - 1)):
            value -= 1 << bits
        if kind in "xX":
            text = format(value, kind)
            if "#" in flags:
                text = ("0X" if kind == "X" else "0x") + text
        elif kind == "o":
            text = format(value, "o")
            if "#" in flags:
                text = "0" + text
        else:
            text = str(value)
        if width and width.lstrip("-").isdigit():
            amount = int(width)
            fill = "0" if "0" in flags and "-" not in flags else " "
            text = text.ljust(abs(amount), fill) if "-" in flags else text.rjust(amount, fill)
        return text

    pieces = fmt.split("%%")
    rendered = "%".join(_FORMAT.sub(replacement, piece) for piece in pieces)
    remaining = list(values)
    return rendered, remaining


def decode_message(dump, message, relocation):
    header = struct.unpack_from("<I", message)[0]
    subtype = header & 0xffff
    timestamp_size = 8
    if len(message) < 4 + timestamp_size:
        return "short message"
    timestamp = struct.unpack_from("<Q", message, 4)[0]
    payload = message[4 + timestamp_size:]
    if subtype != ULOG_SUBTYPE_PRINTF or len(payload) < 4:
        return "ts=%d subtype=%d payload=%s" % (timestamp, subtype,
                                                payload.hex())
    fmt_pointer = struct.unpack_from("<I", payload)[0]
    args = list(struct.unpack_from("<%dI" % ((len(payload) - 4) // 4),
                                   payload, 4))
    raw = "ts=%d fmt=0x%08x args=[%s]" % (
        timestamp, fmt_pointer, ", ".join("0x%08x" % arg for arg in args))
    if relocation is None:
        return raw
    try:
        fmt = dump.string(fmt_pointer, relocation)
    except KeyError as error:
        return raw + " unresolved=%s" % error
    rendered, remaining = render_printf(dump, fmt, args, relocation)
    suffix = " extra=[%s]" % ", ".join("0x%08x" % arg for arg in remaining) if remaining else ""
    return "ts=%d %s%s" % (timestamp, rendered.rstrip("\n"), suffix)


def parse_relocations(values):
    result = {}
    for value in values:
        try:
            name, address = value.rsplit("=", 1)
            result[name] = int(address, 0)
        except ValueError:
            raise argparse.ArgumentTypeError(
                "relocations must use LOG=0xADDRESS") from None
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dump", help="remoteproc ELF devcoredump")
    parser.add_argument("--pointer-relocation", type=lambda value: int(value, 0),
                        default=0x18e00000,
                        help="DSP heap-pointer relocation (default: 0x18e00000)")
    parser.add_argument("--log", action="append", default=[],
                        help="ULog name or shell-style pattern; repeatable")
    parser.add_argument("--relocation", action="append", default=[],
                        metavar="LOG=ADDRESS",
                        help="trusted format-string relocation; repeatable")
    parser.add_argument("--list", action="store_true",
                        help="list discovered ULogs")
    args = parser.parse_args()

    dump = Dump(args.dump, args.pointer_relocation)
    logs = dump.logs()
    relocations = parse_relocations(args.relocation)
    if args.list or not args.log:
        for log in logs:
            read, _flags = struct.unpack("<II",
                                         dump.read_pointer(log.reader_core, 8))
            write, read_writer, usage = struct.unpack(
                "<III", dump.read_pointer(log.writer_core, 12))
            print("0x%08x %-24s size=%-6d read=%-8d trailing=%-8d write=%-8d usage=0x%x" %
                  (log.address, log.name, log.size, read, read_writer, write,
                   usage))
        if not args.log:
            return

    selected = [log for log in logs
                if any(fnmatch.fnmatchcase(log.name, pattern)
                       for pattern in args.log)]
    if not selected:
        sys.exit("no matching ULog found")
    for log in selected:
        print("== %s @ 0x%08x ==" % (log.name, log.address))
        relocation = relocations.get(log.name)
        for offset, message, error in messages(dump, log):
            if error:
                print("+0x%08x %s" % (offset, error))
                continue
            print("+0x%08x %s" %
                  (offset, decode_message(dump, message, relocation)))


if __name__ == "__main__":
    main()
