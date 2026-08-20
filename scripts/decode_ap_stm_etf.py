#!/usr/bin/env python3
"""Decode AP STM packets captured through a formatted CoreSight ETF.

This is intentionally a small deterministic decoder for the packet forms emitted
by Linux p_basic/stm_data_write in an AP STM smoke test. It first removes the
CoreSight 16-byte formatter layer used by the TMC ETF, then decodes the STPv2
STM packet stream using low-nibble-first packet order.

It is not a general replacement for OpenCSD.
"""

from __future__ import annotations

import argparse
import hashlib
import string
import sys
from dataclasses import dataclass
from pathlib import Path


FRAME_SIZE = 16
BAD_TRACE_ID = 0x80
SYNC_NIBBLES = 22
UINT64_MASK = (1 << 64) - 1


class DecodeError(ValueError):
    """Raised when a capture is malformed or outside this decoder subset."""


@dataclass(frozen=True)
class TraceStream:
    """Bytes de-formatted from one CoreSight ATID stream."""

    trace_id: int
    data: bytes


@dataclass(frozen=True)
class StmPacket:
    """One decoded STPv2 packet."""

    index: int
    kind: str
    master: int
    channel: int
    payload: bytes = b""
    value: int | None = None
    timestamp_raw: int | None = None
    timestamp_bits: int = 0
    timestamp: int | None = None


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def ascii_repr(data: bytes) -> str:
    out = []
    printable = set(string.printable.encode("ascii")) - {0x0B, 0x0C}
    for byte in data:
        if byte == 0x0A:
            out.append("\\n")
        elif byte == 0x0D:
            out.append("\\r")
        elif byte == 0x09:
            out.append("\\t")
        elif byte in printable:
            out.append(chr(byte))
        else:
            out.append(".")
    return "".join(out)


def format_optional_hex(value: int | None) -> str:
    if value is None:
        return "None"
    return f"0x{value:x}"


def _ts_mask(bits: int) -> int:
    if bits == 0:
        return 0
    if bits >= 64:
        return UINT64_MASK
    return (1 << bits) - 1


def bin_to_gray(value: int) -> int:
    return (value ^ (value >> 1)) & UINT64_MASK


def gray_to_bin(value: int) -> int:
    value &= UINT64_MASK
    shift = 1
    while shift < 64:
        value ^= value >> shift
        shift <<= 1
    return value & UINT64_MASK


def deformat_tmc_etf(data: bytes) -> list[TraceStream]:
    """Unpack formatted 16-byte CoreSight frames into per-ATID byte streams.

    The TMC ETF was enabled with formatter and trace-ID insertion. For each
    frame, bytes 0..14 carry trace data or source-ID changes, and byte 15 carries
    the sideband bits that restore the low bit of even-position data bytes.
    This follows the frame shape implemented by OpenCSD's frame deformatter.
    """

    if not data:
        raise DecodeError("empty ETF capture")
    if len(data) % FRAME_SIZE:
        raise DecodeError(f"capture size {len(data)} is not a multiple of {FRAME_SIZE}")

    current_trace_id = BAD_TRACE_ID
    streams: dict[int, bytearray] = {}

    def append_byte(trace_id: int, value: int) -> None:
        if trace_id == BAD_TRACE_ID:
            if value != 0:
                raise DecodeError("non-zero formatter data before first CoreSight source ID")
            return
        streams.setdefault(trace_id, bytearray()).append(value & 0xFF)

    for frame_start in range(0, len(data), FRAME_SIZE):
        frame = data[frame_start : frame_start + FRAME_SIZE]
        aux = frame[15]
        flag_bit = 1

        for i in range(0, 14, 2):
            previous_id_and_id_change = False
            first = frame[i]

            if first & 1:
                new_trace_id = (first >> 1) & 0x7F
                if new_trace_id != current_trace_id:
                    previous_id_and_id_change = bool(aux & flag_bit)
                    if previous_id_and_id_change:
                        append_byte(current_trace_id, frame[i + 1])
                    current_trace_id = new_trace_id
                # If the source ID did not change, or if it changed without the
                # "previous ID owns second byte" flag, byte i+1 is data for the
                # current source.
                if not previous_id_and_id_change:
                    append_byte(current_trace_id, frame[i + 1])
            else:
                append_byte(current_trace_id, first | (1 if aux & flag_bit else 0))
                append_byte(current_trace_id, frame[i + 1])

            flag_bit <<= 1

        last = frame[14]
        if last & 1:
            current_trace_id = (last >> 1) & 0x7F
        else:
            append_byte(current_trace_id, last | (1 if aux & 0x80 else 0))

    if not streams:
        raise DecodeError("ETF capture contains no CoreSight source streams")

    return [TraceStream(trace_id, bytes(payload)) for trace_id, payload in sorted(streams.items())]


def nibbles_from_bytes(data: bytes) -> list[int]:
    """Return STPv2 protocol nibbles in low-nibble-first order."""

    nibbles: list[int] = []
    for byte in data:
        nibbles.append(byte & 0xF)
        nibbles.append((byte >> 4) & 0xF)
    return nibbles


class StmDecoder:
    """Small STPv2 decoder for p_basic-generated AP STM smoke packets."""

    def __init__(self, data: bytes) -> None:
        self.nibbles = nibbles_from_bytes(data)
        self.pos = 0
        self.master = 0
        self.channel = 0
        self.version: int | None = None
        self.timestamp_encoding = "unknown"
        self.previous_timestamp: int | None = None

    def available(self) -> int:
        return len(self.nibbles) - self.pos

    def require_available(self, count: int, what: str) -> None:
        if count < 0:
            raise DecodeError(f"internal negative read count for {what}")
        if self.available() < count:
            raise DecodeError(
                f"unexpected end of STP stream while reading {what}: "
                f"need {count} nibbles, have {self.available()} at nibble {self.pos}"
            )

    def read_nibble(self, what: str = "nibble") -> int:
        self.require_available(1, what)
        value = self.nibbles[self.pos]
        self.pos += 1
        return value

    def read_value(self, count: int, what: str = "value") -> int:
        self.require_available(count, what)
        value = 0
        for _ in range(count):
            value = (value << 4) | self.read_nibble(what)
        return value

    def read_timestamp_update(self) -> tuple[int, int]:
        count = self.read_nibble("timestamp-size")
        if count == 0xD:
            count = 14
        elif count == 0xE:
            count = 16
        elif count == 0xF:
            raise DecodeError("invalid STPv2 timestamp size 0xf")
        raw = self.read_value(count, "timestamp-value") if count else 0
        return raw, count * 4

    def reconstruct_timestamp(self, raw: int, bits: int) -> int | None:
        """Apply STPv2 relative timestamp update semantics.

        VERSION 3 uses natural-binary timestamps; VERSION 4 uses Gray-coded
        timestamp updates. A partial timestamp before the first full timestamp is
        not reconstructable and is represented as None instead of pretending that
        the raw low bits are an absolute time.
        """

        if bits < 0 or bits > 64 or bits % 4:
            raise DecodeError(f"invalid timestamp bit width {bits}")

        if bits == 64:
            if self.timestamp_encoding == "gray":
                timestamp = gray_to_bin(raw)
            else:
                timestamp = raw & UINT64_MASK
            self.previous_timestamp = timestamp
            return timestamp

        if self.previous_timestamp is None:
            return None

        mask = _ts_mask(bits)
        if self.timestamp_encoding == "gray":
            previous_gray = bin_to_gray(self.previous_timestamp)
            next_gray = (previous_gray & ~mask) | (raw & mask)
            timestamp = gray_to_bin(next_gray)
        else:
            timestamp = (self.previous_timestamp & ~mask) | (raw & mask)

        timestamp &= UINT64_MASK
        self.previous_timestamp = timestamp
        return timestamp

    def timestamp_packet(
        self,
        start: int,
        kind: str,
        payload: bytes = b"",
        value: int | None = None,
    ) -> StmPacket:
        timestamp_raw, timestamp_bits = self.read_timestamp_update()
        timestamp = self.reconstruct_timestamp(timestamp_raw, timestamp_bits)
        return StmPacket(
            start,
            kind,
            self.master,
            self.channel,
            payload=payload,
            value=value,
            timestamp_raw=timestamp_raw,
            timestamp_bits=timestamp_bits,
            timestamp=timestamp,
        )

    @staticmethod
    def value_payload(value: int, bits: int) -> bytes:
        # STM integer payloads are carried in little-endian byte order. The
        # STPv2 packet itself is nibble-encoded, but p_basic payload bytes must
        # reconstruct to the userspace write byte-for-byte.
        if bits == 4:
            return bytes([value & 0xF])
        return value.to_bytes(bits // 8, "little")

    def decode(self) -> list[StmPacket]:
        packets: list[StmPacket] = []

        while self.available() > 0:
            start = self.pos

            if self.available() >= SYNC_NIBBLES and self.nibbles[
                self.pos : self.pos + SYNC_NIBBLES - 1
            ] == [0xF] * (SYNC_NIBBLES - 1) and self.nibbles[
                self.pos + SYNC_NIBBLES - 1 : self.pos + SYNC_NIBBLES
            ] == [0]:
                self.pos += SYNC_NIBBLES
                packets.append(StmPacket(start, "ASYNC", self.master, self.channel))
                continue

            header = self.read_nibble("opcode")

            if header == 0x0:
                packets.append(StmPacket(start, "NULL", self.master, self.channel))
            elif header == 0x1:
                self.master = self.read_value(2, "M8")
                self.channel = 0
                packets.append(
                    StmPacket(start, "M8", self.master, self.channel, value=self.master)
                )
            elif header == 0x3:
                self.channel = (self.channel & 0xFF00) | self.read_value(2, "C8")
                packets.append(
                    StmPacket(start, "C8", self.master, self.channel, value=self.channel)
                )
            elif header in (0x4, 0x5, 0x6, 0x7, 0xC):
                bits = {0x4: 8, 0x5: 16, 0x6: 32, 0x7: 64, 0xC: 4}[header]
                value = self.read_value({4: 1, 8: 2, 16: 4, 32: 8, 64: 16}[bits], f"D{bits}")
                packets.append(
                    StmPacket(
                        start,
                        f"D{bits}",
                        self.master,
                        self.channel,
                        self.value_payload(value, bits),
                        value=value,
                    )
                )
            elif header in (0x8, 0x9, 0xA, 0xB, 0xD):
                bits = {0x8: 8, 0x9: 16, 0xA: 32, 0xB: 64, 0xD: 4}[header]
                value = self.read_value(
                    {4: 1, 8: 2, 16: 4, 32: 8, 64: 16}[bits], f"D{bits}_MTS"
                )
                packets.append(
                    self.timestamp_packet(
                        start,
                        f"D{bits}_MTS",
                        payload=self.value_payload(value, bits),
                        value=value,
                    )
                )
            elif header == 0xE:
                packets.append(self.timestamp_packet(start, "FLAG_TS"))
            elif header == 0xF:
                packets.append(self.decode_extended(start))
            else:
                raise DecodeError(f"reserved one-nibble opcode 0x{header:x} at nibble {start}")

        return packets

    def decode_extended(self, start: int) -> StmPacket:
        second = self.read_nibble("extended opcode")
        if second == 0x0:
            return self.decode_f0_extended(start)
        if second == 0x3:
            self.channel = self.read_value(4, "C16")
            return StmPacket(start, "C16", self.master, self.channel, value=self.channel)
        if second in (0x4, 0x5, 0x6, 0x7, 0xC):
            bits = {0x4: 8, 0x5: 16, 0x6: 32, 0x7: 64, 0xC: 4}[second]
            value = self.read_value({4: 1, 8: 2, 16: 4, 32: 8, 64: 16}[bits], f"D{bits}_TS")
            return self.timestamp_packet(
                start,
                f"D{bits}_TS",
                payload=self.value_payload(value, bits),
                value=value,
            )
        if second in (0x8, 0x9, 0xA, 0xB, 0xD):
            bits = {0x8: 8, 0x9: 16, 0xA: 32, 0xB: 64, 0xD: 4}[second]
            value = self.read_value({4: 1, 8: 2, 16: 4, 32: 8, 64: 16}[bits], f"D{bits}_M")
            return StmPacket(
                start,
                f"D{bits}_M",
                self.master,
                self.channel,
                self.value_payload(value, bits),
                value=value,
            )
        if second == 0xE:
            return StmPacket(start, "FLAG", self.master, self.channel)
        if second == 0xF:
            return StmPacket(start, "ASYNC_SHORT", self.master, self.channel)
        raise DecodeError(f"reserved extended opcode 0xf{second:x} at nibble {start}")

    def decode_f0_extended(self, start: int) -> StmPacket:
        third = self.read_nibble("f0 opcode")
        if third == 0x0:
            self.version = self.read_nibble("VERSION")
            if self.version == 3:
                self.timestamp_encoding = "natural"
            elif self.version == 4:
                self.timestamp_encoding = "gray"
            else:
                raise DecodeError(f"unsupported STM VERSION {self.version} at nibble {start}")
            self.master = 0
            self.channel = 0
            self.previous_timestamp = None
            return StmPacket(start, "VERSION", self.master, self.channel, value=self.version)
        if third == 0x1:
            return self.timestamp_packet(start, "NULL_TS")
        if third == 0x6:
            value = self.read_value(2, "TRIG")
            return StmPacket(start, "TRIG", self.master, self.channel, value=value)
        if third == 0x7:
            value = self.read_value(2, "TRIG_TS")
            return self.timestamp_packet(start, "TRIG_TS", value=value)
        if third == 0x8:
            value = self.read_value(8, "FREQ")
            return StmPacket(start, "FREQ", self.master, self.channel, value=value)
        raise DecodeError(f"reserved f0 opcode 0xf0{third:x} at nibble {start}")


def decode_stm(data: bytes) -> list[StmPacket]:
    return StmDecoder(data).decode()


def payload_from_packets(packets: list[StmPacket]) -> bytes:
    payload = bytearray()
    for packet in packets:
        if packet.kind.startswith("D"):
            payload.extend(packet.payload)
    return bytes(payload)


def classify_stream(stream: TraceStream) -> str:
    if not stream.data:
        return "empty"
    if all(byte == 0 for byte in stream.data):
        return "zero-padding"
    return "stp"


def summarize(args: argparse.Namespace) -> int:
    capture = Path(args.capture)
    data = capture.read_bytes()
    digest = sha256_bytes(data)

    print(f"capture={capture}")
    print(f"size={len(data)}")
    print(f"sha256={digest}")
    if args.expect_sha256 and digest != args.expect_sha256:
        print(f"sha256_verdict=MISMATCH expected={args.expect_sha256}")
        return 2
    if args.expect_sha256:
        print("sha256_verdict=MATCH")

    last_nonzero = max((i for i, byte in enumerate(data) if byte != 0), default=-1)
    print(f"last_nonzero_offset=0x{last_nonzero:x}")
    if last_nonzero + 1 < len(data):
        print(f"zero_tail_from=0x{last_nonzero + 1:x}")
    else:
        print("zero_tail_from=none")

    streams = deformat_tmc_etf(data)
    selected_payloads: list[tuple[int, bytes]] = []
    selected_packets: list[tuple[int, list[StmPacket]]] = []

    print("streams:")
    for stream in streams:
        kind = classify_stream(stream)
        print(f"  atid={stream.trace_id} len={len(stream.data)} kind={kind}")
        if kind != "stp":
            continue
        packets = decode_stm(stream.data)
        payload = payload_from_packets(packets)
        selected_packets.append((stream.trace_id, packets))
        selected_payloads.append((stream.trace_id, payload))

    if not selected_packets:
        raise DecodeError("ETF capture contains no useful STP stream")

    for trace_id, packets in selected_packets:
        print(f"packets atid={trace_id}:")
        for idx, packet in enumerate(packets):
            parts = [
                f"  {idx:02d}",
                f"nibble={packet.index}",
                f"master=0x{packet.master:02x}",
                f"channel=0x{packet.channel:04x}",
                f"type={packet.kind}",
            ]
            if packet.payload:
                parts.append(f"payload_hex={packet.payload.hex()}")
                parts.append(f"payload_ascii='{ascii_repr(packet.payload)}'")
            if packet.value is not None and not packet.payload:
                parts.append(f"value=0x{packet.value:x}")
            if packet.timestamp_raw is not None:
                parts.append(f"timestamp_bits={packet.timestamp_bits}")
                parts.append(f"timestamp_raw={format_optional_hex(packet.timestamp_raw)}")
                parts.append(f"timestamp={format_optional_hex(packet.timestamp)}")
            print(" ".join(parts))

    for trace_id, payload in selected_payloads:
        print(
            f"payload atid={trace_id} len={len(payload)} "
            f"ascii='{ascii_repr(payload)}'"
        )

    marker = args.expect_marker.encode()
    if args.expect_marker_lf:
        marker += b"\n"
    if args.expect_marker:
        matches = [trace_id for trace_id, payload in selected_payloads if payload == marker]
        if matches:
            print(f"marker_verdict=MATCH atid={','.join(str(i) for i in matches)}")
            return 0
        print("marker_verdict=MISMATCH")
        return 1

    return 0


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", help="formatted CoreSight ETF capture")
    parser.add_argument("--expect-sha256", help="expected capture SHA256")
    parser.add_argument("--expect-marker", default="", help="expected decoded marker text")
    parser.add_argument(
        "--expect-marker-lf",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="append a line feed to --expect-marker before comparison",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_arg_parser()
    args = parser.parse_args(argv)
    try:
        return summarize(args)
    except (OSError, DecodeError) as exc:
        print(f"error={exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
