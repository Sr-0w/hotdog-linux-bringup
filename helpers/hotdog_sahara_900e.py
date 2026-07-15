#!/usr/bin/env python3
"""Inspect or reset a hotdog target in Qualcomm Sahara crashdump mode."""

from __future__ import annotations

import argparse
import logging
import struct
import sys
from pathlib import Path


def physical_address(value: str) -> int:
    address = int(value, 0)
    if not 0 <= address <= 0xFFFFFFFFFFFFFFFF:
        raise argparse.ArgumentTypeError("physical address is outside u64 range")
    return address


def decode_early_breadcrumb(data: bytes) -> dict[str, int]:
    if len(data) < 0x18:
        raise ValueError("early breadcrumb is shorter than 24 bytes")

    magic, version, stage, stage_inverse, detail, detail_inverse = (
        struct.unpack_from("<IIIIII", data)
    )
    decoded = {
        "magic": magic,
        "version": version,
        "stage": stage,
        "stage_inverse": stage_inverse,
        "detail": detail,
        "detail_inverse": detail_inverse,
        "stage_valid": int(stage_inverse == ((~stage) & 0xFFFFFFFF)),
        "detail_valid": int(detail_inverse == ((~detail) & 0xFFFFFFFF)),
    }
    if version < 2:
        return decoded
    if len(data) < 0x30:
        raise ValueError("version-2 early breadcrumb is shorter than 48 bytes")

    (
        level,
        level_inverse,
        address_low,
        address_high,
        address_low_inverse,
        address_high_inverse,
    ) = struct.unpack_from("<IIIIII", data, 0x18)
    decoded.update(
        {
            "level": level,
            "level_inverse": level_inverse,
            "level_valid": int(level_inverse == ((~level) & 0xFFFFFFFF)),
            "initcall_address": address_low | (address_high << 32),
            "address_valid": int(
                address_low_inverse == ((~address_low) & 0xFFFFFFFF)
                and address_high_inverse == ((~address_high) & 0xFFFFFFFF)
            ),
        }
    )
    return decoded


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("inspect", "reset"))
    parser.add_argument("--edl-source", type=Path, required=True)
    parser.add_argument("--serial", required=True)
    parser.add_argument("--early-breadcrumb-address", type=physical_address)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    sys.path.insert(0, str(args.edl_source))

    from edlclient.Library.Connection.usblib import usb_class
    from edlclient.Library.sahara import sahara
    from edlclient.Library.sahara_defs import cmd_t, sahara_mode_t

    cdc = usb_class(
        loglevel=logging.INFO,
        portconfig=[[0x05C6, 0x900E, -1]],
        serial_number=None,
    )
    # The bundled client retries indefinitely for most timeout values. Ten
    # returns cleanly after one USB timeout and keeps this helper bounded.
    cdc.timeout = 10
    try:
        connected = cdc.connect()
    except (OSError, ValueError) as error:
        print(f"error=usb-enumeration-incomplete detail={error}", file=sys.stderr)
        return 3
    if not connected:
        print("error=qualcomm-900e-not-connectable", file=sys.stderr)
        return 3
    if cdc.serial_number != args.serial:
        print(
            f"error=serial-mismatch expected={args.serial} actual={cdc.serial_number}",
            file=sys.stderr,
        )
        cdc.close()
        return 4

    try:
        protocol = sahara(cdc, loglevel=logging.INFO)
        state = protocol.connect()
        print(f"sahara_mode={state.get('mode')}")
        print(f"sahara_command={state.get('cmd')}")

        if args.action == "reset":
            accepted = protocol.cmd_reset()
            print(f"sahara_reset_response={int(accepted)}")
            return 0 if accepted else 5

        if (
            state.get("mode") != "sahara"
            or state.get("cmd") != cmd_t.SAHARA_HELLO_REQ
        ):
            print("error=fresh-sahara-hello-required", file=sys.stderr)
            return 6

        version = state["data"].version
        if not protocol.cmd_hello(
            sahara_mode_t.SAHARA_MODE_MEMORY_DEBUG, version=version
        ):
            print("error=memory-debug-hello-failed", file=sys.stderr)
            return 7
        response = protocol.get_rsp()
        if response.get("cmd") not in (
            cmd_t.SAHARA_MEMORY_DEBUG,
            cmd_t.SAHARA_64BIT_MEMORY_DEBUG,
        ):
            print("error=memory-debug-transfer-unavailable", file=sys.stderr)
            return 8

        breadcrumb = protocol.read_memory(0xA9BFF000, 0x40)
        restart_reason = protocol.read_memory(0x146BF65C, 0x04)
        print(f"breadcrumb_hex={breadcrumb.hex()}")
        print(f"restart_reason_hex={restart_reason.hex()}")
        if len(breadcrumb) < 8 or len(restart_reason) != 4:
            print("error=short-physical-read", file=sys.stderr)
            return 9

        magic, stage = struct.unpack_from("<II", breadcrumb)
        print(f"breadcrumb_magic=0x{magic:08x}")
        print(f"breadcrumb_stage={stage}")
        if stage >= 2 and len(breadcrumb) >= 0x18:
            level, index, low, high = struct.unpack_from("<IIII", breadcrumb, 8)
            print(f"breadcrumb_level={level}")
            print(f"breadcrumb_index={index}")
            print(f"breadcrumb_initcall_address=0x{low | (high << 32):016x}")
        print(f"restart_reason=0x{struct.unpack('<I', restart_reason)[0]:08x}")

        if args.early_breadcrumb_address is not None:
            early = protocol.read_memory(args.early_breadcrumb_address, 0x40)
            print(
                "early_breadcrumb_address="
                f"0x{args.early_breadcrumb_address:016x}"
            )
            print(f"early_breadcrumb_hex={early.hex()}")
            try:
                decoded = decode_early_breadcrumb(early)
            except ValueError as error:
                print(f"error={error}", file=sys.stderr)
                return 10
            for field, value in decoded.items():
                if field == "magic":
                    print(f"early_breadcrumb_magic=0x{value:08x}")
                elif field == "initcall_address":
                    print(f"early_breadcrumb_{field}=0x{value:016x}")
                else:
                    print(f"early_breadcrumb_{field}={value}")
        return 0
    finally:
        cdc.close()


if __name__ == "__main__":
    raise SystemExit(main())
