#!/usr/bin/env python3
"""Extract a ramoops console zone from a raw physical DDR segment."""

from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path


PERSISTENT_RAM_SIG = 0x43474244
HEADER_SIZE = 12


def parse_int(value: str) -> int:
    return int(value, 0)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("ddr", type=Path, help="Raw DDR segment containing the ramoops zone")
    parser.add_argument("--ddr-phys-base", type=parse_int, default=0x80000000)
    parser.add_argument("--console-phys", type=parse_int, default=0xA9980000)
    parser.add_argument("--zone-size", type=parse_int, default=0x40000)
    parser.add_argument("--reservation-phys", type=parse_int, default=0xA9800000)
    parser.add_argument("--reservation-size", type=parse_int, default=0x400000)
    parser.add_argument(
        "--scan-reservation",
        action="store_true",
        help="scan the complete ramoops reservation and emit every populated zone",
    )
    return parser.parse_args()


def extract_zone(zone: bytes) -> bytes:
    signature, start, size = struct.unpack_from("<III", zone)
    if signature != PERSISTENT_RAM_SIG:
        raise ValueError(f"unexpected ramoops signature 0x{signature:08x}")

    data = zone[HEADER_SIZE:]
    capacity = len(data)
    if start > capacity or size > capacity:
        raise ValueError(
            f"invalid ramoops cursor: start={start}, size={size}, capacity={capacity}"
        )

    if size < capacity:
        return data[:size]
    return data[start:] + data[:start]


def scan_reservation(args: argparse.Namespace) -> int:
    file_offset = args.reservation_phys - args.ddr_phys_base
    if file_offset < 0:
        raise SystemExit("ramoops reservation is below the DDR segment base")

    with args.ddr.open("rb") as stream:
        stream.seek(file_offset)
        reservation = stream.read(args.reservation_size)

    if len(reservation) != args.reservation_size:
        raise SystemExit(
            "short ramoops reservation: "
            f"expected {args.reservation_size} bytes, got {len(reservation)}"
        )

    signature = struct.pack("<I", PERSISTENT_RAM_SIG)
    offset = 0
    populated = 0
    while True:
        offset = reservation.find(signature, offset)
        if offset < 0:
            break
        if offset + args.zone_size > len(reservation):
            break
        zone = reservation[offset : offset + args.zone_size]
        try:
            payload = extract_zone(zone)
        except ValueError:
            offset += 1
            continue
        if payload:
            populated += 1
            sys.stdout.buffer.write(
                f"\n--- RAMOOPS_ZONE offset=0x{offset:x} bytes={len(payload)} ---\n".encode()
            )
            sys.stdout.buffer.write(payload)
            if not payload.endswith(b"\n"):
                sys.stdout.buffer.write(b"\n")
        offset += 1

    if not populated:
        raise SystemExit("no populated ramoops zone found in reservation")
    return 0


def main() -> int:
    args = parse_args()
    if args.scan_reservation:
        return scan_reservation(args)

    file_offset = args.console_phys - args.ddr_phys_base
    if file_offset < 0:
        raise SystemExit("console physical address is below the DDR segment base")

    with args.ddr.open("rb") as stream:
        stream.seek(file_offset)
        zone = stream.read(args.zone_size)

    if len(zone) != args.zone_size:
        raise SystemExit(
            f"short ramoops zone: expected {args.zone_size} bytes, got {len(zone)}"
        )

    try:
        sys.stdout.buffer.write(extract_zone(zone))
    except ValueError as error:
        raise SystemExit(str(error)) from error
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
