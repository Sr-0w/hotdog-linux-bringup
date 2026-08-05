#!/usr/bin/env python3
"""Inspect or reset a hotdog target in Qualcomm Sahara crashdump mode."""

from __future__ import annotations

import argparse
import logging
import os
import struct
import sys
import time
from pathlib import Path


def physical_address(value: str) -> int:
    address = int(value, 0)
    if not 0 <= address <= 0xFFFFFFFFFFFFFFFF:
        raise argparse.ArgumentTypeError("physical address is outside u64 range")
    return address


def bounded_memory_length(value: str) -> int:
    length = int(value, 0)
    if not 1 <= length <= 0x01000000:
        raise argparse.ArgumentTypeError(
            "memory length must be between 1 byte and 16 MiB"
        )
    return length


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
    if version < 3:
        return decoded
    if len(data) < 0x48:
        raise ValueError("version-3 early breadcrumb is shorter than 72 bytes")

    counter_control_before, counter_control_after = struct.unpack_from(
        "<II", data, 0x30
    )
    virtual_counter_before, virtual_counter_after = struct.unpack_from(
        "<QQ", data, 0x38
    )
    decoded.update(
        {
            "counter_control_before": counter_control_before,
            "counter_control_after": counter_control_after,
            "virtual_counter_before": virtual_counter_before,
            "virtual_counter_after": virtual_counter_after,
            "virtual_counter_delta": (
                virtual_counter_after - virtual_counter_before
            )
            & 0xFFFFFFFFFFFFFFFF,
        }
    )
    return decoded


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "action", choices=("inspect", "reset", "state-reset", "recover")
    )
    parser.add_argument("--edl-source", type=Path, required=True)
    parser.add_argument("--serial", required=True)
    parser.add_argument("--early-breadcrumb-address", type=physical_address)
    parser.add_argument("--memory-address", type=physical_address)
    parser.add_argument("--memory-length", type=bounded_memory_length)
    parser.add_argument("--memory-output", type=Path)
    parser.add_argument(
        "--list-memory-regions",
        action="store_true",
        help="read and print the Sahara memory-debug table without dumping it",
    )
    args = parser.parse_args()

    memory_options = (
        args.memory_address,
        args.memory_length,
        args.memory_output,
    )
    if any(option is not None for option in memory_options) and not all(
        option is not None for option in memory_options
    ):
        parser.error(
            "--memory-address, --memory-length, and --memory-output "
            "must be provided together"
        )
    if args.action != "inspect" and args.memory_address is not None:
        parser.error("physical memory reads require the inspect action")
    if args.action != "inspect" and args.list_memory_regions:
        parser.error("memory-region listing requires the inspect action")
    return args


def print_memory_regions(protocol, response) -> bool:
    """Read and print the crashdump region table without resetting the target."""

    memory_table_addr = response["data"].memory_table_addr
    memory_table_length = response["data"].memory_table_length
    packet_size = 64 if protocol.bit64 else 52

    print(f"memory_table_address=0x{memory_table_addr:016x}")
    print(f"memory_table_length=0x{memory_table_length:x}")
    print(f"memory_table_entry_size={packet_size}")
    if memory_table_length == 0 or memory_table_length % packet_size:
        print("error=invalid-memory-table-length", file=sys.stderr)
        return False

    table = protocol.read_memory(memory_table_addr, memory_table_length)
    if table is None or len(table) != memory_table_length:
        print("error=short-memory-table-read", file=sys.stderr)
        return False

    print(f"memory_region_count={len(table) // packet_size}")
    for index in range(0, len(table), packet_size):
        entry_data = table[index : index + packet_size]
        if protocol.bit64:
            entry = protocol.ch.parttbl_64bit(entry_data)
        else:
            entry = protocol.ch.parttbl(entry_data)
        filename = entry.filename.rstrip(b"\x00").decode("utf-8", "replace")
        description = entry.desc.rstrip(b"\x00").decode("utf-8", "replace")
        print(
            "memory_region="
            f"{index // packet_size}\t{filename}\t{description}\t"
            f"0x{entry.mem_base:016x}\t0x{entry.length:x}\t"
            f"0x{entry.save_pref:x}"
        )
    return True


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

        if args.action == "state-reset":
            accepted = protocol.cmd_reset_state_machine()
            print(f"sahara_state_reset_sent={int(accepted)}")
            return 0 if accepted else 5

        if args.action == "recover":
            accepted = protocol.cmd_reset_state_machine()
            print(f"sahara_state_reset_sent={int(accepted)}")
            if not accepted:
                return 5

            time.sleep(0.5)
            refreshed = protocol.connect()
            print(f"sahara_recovery_mode={refreshed.get('mode')}")
            print(f"sahara_recovery_command={refreshed.get('cmd')}")
            if (
                refreshed.get("mode") == "sahara"
                and refreshed.get("cmd") == cmd_t.SAHARA_HELLO_REQ
            ):
                version = refreshed["data"].version
                if not protocol.cmd_hello(
                    sahara_mode_t.SAHARA_MODE_MEMORY_DEBUG, version=version
                ):
                    print("error=recovery-memory-debug-hello-failed", file=sys.stderr)
                    return 12
                response = protocol.get_rsp()
                print(f"sahara_recovery_response={response.get('cmd')}")

            accepted = protocol.cmd_reset()
            print(f"sahara_recovery_reset_response={int(accepted)}")
            return 0 if accepted else 13

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

        if args.list_memory_regions and not print_memory_regions(protocol, response):
            return 14

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
            early = protocol.read_memory(args.early_breadcrumb_address, 0x50)
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
                elif field.startswith("counter_control"):
                    print(f"early_breadcrumb_{field}=0x{value:08x}")
                elif field.startswith("virtual_counter"):
                    print(f"early_breadcrumb_{field}=0x{value:016x}")
                else:
                    print(f"early_breadcrumb_{field}={value}")

        if args.memory_address is not None:
            args.memory_output.parent.mkdir(parents=True, exist_ok=True)
            print(
                "memory_read_address="
                f"0x{args.memory_address:016x}"
            )
            print(f"memory_read_length=0x{args.memory_length:x}")
            print(f"memory_read_output={args.memory_output}")
            with args.memory_output.open("wb") as output:
                result = protocol.read_memory(
                    args.memory_address,
                    args.memory_length,
                    display=True,
                    wf=output,
                )
                output.flush()
                os.fsync(output.fileno())
                bytes_written = output.tell()
            print(f"memory_read_bytes={bytes_written}")
            if result is None or bytes_written != args.memory_length:
                print("error=short-bounded-memory-read", file=sys.stderr)
                return 11
        return 0
    finally:
        cdc.close()


if __name__ == "__main__":
    raise SystemExit(main())
