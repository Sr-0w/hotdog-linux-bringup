#!/usr/bin/env python3
"""Decode the AP STM smoke path captured through a formatted CoreSight ETF.

This is intentionally a small deterministic decoder for the packet forms emitted
by Linux p_basic/stm_data_write on the hotdog AP smoke test. It first removes
the CoreSight 16-byte formatter layer used by the TMC ETF, then decodes the
STPv2 STM packet stream using low-nibble-first packet order.

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
    timestamp: int | None = None
    timestamp_bits: int = 0


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def ascii_repr(data: bytes) -> str:
    out = []
    printable = set(string.printable.encode("ascii")) - {0x0b, 0x0c}
    for byte in data:
        if byte == 0x0a:
            out.append("\\n")
        elif byte == 0x0d:
            out.append("\\r")
        elif byte == 0x09:
            out.append("\\t")
        elif byte in printable:
            out.append(chr(byte))
        else:
            out.append(".")
    return "".join(out)


def deformat_tmc_etf(data: bytes) -> list[TraceStream]:
    """Unpack formatted 16-byte CoreSight frames into per-ATID byte streams.

    The TMC ETF was enabled with formatter and trace-ID insertion. For each
    frame, bytes 0..14 carry trace data or source-ID changes, and byte 15 carries
    the sideband bits that restore the low bit of even-position data bytes.
    This follows the frame shape implemented by OpenCSD's frame deformatter.
    """

    if len(data) % FRAME_SIZE:
        raise ValueError(f"capture size {len(data)} is not a multiple of {FRAME_SIZE}")

    current_trace_id = BAD_TRACE_ID
    streams: dict[int, bytearray] = {}

    def append_byte(trace_id: int, value: int) -> None:
        if trace_id != BAD_TRACE_ID:
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

    def available(self) -> int:
        return len(self.nibbles) - self.pos

    def read_nibble(self) -> int:
        if self.pos >= len(self.nibbles):
            raise ValueError("unexpected end of STP stream")
        value = self.nibbles[self.pos]
        self.pos += 1
        return value

    def read_value(self, count: int) -> int:
        value = 0
        for _ in range(count):
            value = (value << 4) | self.read_nibble()
        return value

    def read_timestamp(self) -> tuple[int, int]:
        count = self.read_nibble()
        if count == 0xD:
            count = 14
        elif count == 0xE:
            count = 16
        elif count == 0xF:
            raise ValueError("invalid STPv2 timestamp size 0xf")
        timestamp = self.read_value(count)
        return timestamp, count * 4

    @staticmethod
    def value_payload(value: int, bits: int) -> bytes:
        # OpenCSD emits STM integer payloads through native little-endian integer
        # storage; this helper makes that byte order explicit and portable.
        if bits == 4:
            return bytes([value & 0xF])
        return value.to_bytes(bits // 8, "little")

    def decode(self) -> list[StmPacket]:
        packets: list[StmPacket] = []

        while self.available() > 0:
            start = self.pos

            if self.nibbles[self.pos : self.pos + SYNC_NIBBLES - 1] == [0xF] * (
                SYNC_NIBBLES - 1
            ) and self.nibbles[self.pos + SYNC_NIBBLES - 1 : self.pos + SYNC_NIBBLES] == [
                0
            ]:
                self.pos += SYNC_NIBBLES
                packets.append(StmPacket(start, "ASYNC", self.master, self.channel))
                continue

            header = self.read_nibble()

            if header == 0x0:
                packets.append(StmPacket(start, "NULL", self.master, self.channel))
            elif header == 0x1:
                self.master = self.read_value(2)
                self.channel = 0
                packets.append(
                    StmPacket(start, "M8", self.master, self.channel, value=self.master)
                )
            elif header == 0x3:
                self.channel = (self.channel & 0xFF00) | self.read_value(2)
                packets.append(
                    StmPacket(start, "C8", self.master, self.channel, value=self.channel)
                )
            elif header in (0x4, 0x5, 0x6, 0x7, 0xC):
                bits = {0x4: 8, 0x5: 16, 0x6: 32, 0x7: 64, 0xC: 4}[header]
                value = self.read_value({4: 1, 8: 2, 16: 4, 32: 8, 64: 16}[bits])
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
                value = self.read_value({4: 1, 8: 2, 16: 4, 32: 8, 64: 16}[bits])
                timestamp, timestamp_bits = self.read_timestamp()
                packets.append(
                    StmPacket(
                        start,
                        f"D{bits}_MTS",
                        self.master,
                        self.channel,
                        self.value_payload(value, bits),
                        value=value,
                        timestamp=timestamp,
                        timestamp_bits=timestamp_bits,
                    )
                )
            elif header == 0xE:
                timestamp, timestamp_bits = self.read_timestamp()
                packets.append(
                    StmPacket(
                        start,
                        "FLAG_TS",
                        self.master,
                        self.channel,
                        timestamp=timestamp,
                        timestamp_bits=timestamp_bits,
                    )
                )
            elif header == 0xF:
                packets.append(self.decode_extended(start))
            else:
                raise ValueError(f"reserved one-nibble opcode 0x{header:x} at nibble {start}")

        return packets

    def decode_extended(self, start: int) -> StmPacket:
        second = self.read_nibble()
        if second == 0x0:
            return self.decode_f0_extended(start)
        if second == 0x3:
            self.channel = self.read_value(4)
            return StmPacket(start, "C16", self.master, self.channel, value=self.channel)
        if second in (0x4, 0x5, 0x6, 0x7, 0xC):
            bits = {0x4: 8, 0x5: 16, 0x6: 32, 0x7: 64, 0xC: 4}[second]
            value = self.read_value({4: 1, 8: 2, 16: 4, 32: 8, 64: 16}[bits])
            timestamp, timestamp_bits = self.read_timestamp()
            return StmPacket(
                start,
                f"D{bits}_TS",
                self.master,
                self.channel,
                self.value_payload(value, bits),
                value=value,
                timestamp=timestamp,
                timestamp_bits=timestamp_bits,
            )
        if second in (0x8, 0x9, 0xA, 0xB, 0xD):
            bits = {0x8: 8, 0x9: 16, 0xA: 32, 0xB: 64, 0xD: 4}[second]
            value = self.read_value({4: 1, 8: 2, 16: 4, 32: 8, 64: 16}[bits])
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
        raise ValueError(f"reserved extended opcode 0xf{second:x} at nibble {start}")

    def decode_f0_extended(self, start: int) -> StmPacket:
        third = self.read_nibble()
        if third == 0x0:
            self.version = self.read_nibble()
            if self.version not in (3, 4):
                raise ValueError(f"unsupported STM VERSION {self.version} at nibble {start}")
            self.master = 0
            self.channel = 0
            return StmPacket(start, "VERSION", self.master, self.channel, value=self.version)
        if third == 0x1:
            timestamp, timestamp_bits = self.read_timestamp()
            return StmPacket(
                start,
                "NULL_TS",
                self.master,
                self.channel,
                timestamp=timestamp,
                timestamp_bits=timestamp_bits,
            )
        if third == 0x6:
            value = self.read_value(2)
            return StmPacket(start, "TRIG", self.master, self.channel, value=value)
        if third == 0x7:
            value = self.read_value(2)
            timestamp, timestamp_bits = self.read_timestamp()
            return StmPacket(
                start,
                "TRIG_TS",
                self.master,
                self.channel,
                value=value,
                timestamp=timestamp,
                timestamp_bits=timestamp_bits,
            )
        if third == 0x8:
            value = self.read_value(8)
            return StmPacket(start, "FREQ", self.master, self.channel, value=value)
        raise ValueError(f"reserved f0 opcode 0xf0{third:x} at nibble {start}")


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
            if packet.timestamp is not None:
                parts.append(f"timestamp_bits={packet.timestamp_bits}")
                parts.append(f"timestamp=0x{packet.timestamp:x}")
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
    except (OSError, ValueError) as exc:
        print(f"error={exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
