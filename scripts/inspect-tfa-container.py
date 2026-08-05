#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Inspect an NXP TFA98xx parameter container without touching hardware."""

from __future__ import annotations

import argparse
import collections
import hashlib
import re
import struct
import sys
import zlib
from pathlib import Path


DESCRIPTOR_TYPES = (
    "device",
    "profile",
    "register",
    "string",
    "file",
    "patch",
    "marker",
    "mode",
    "set-input-select",
    "set-output-select",
    "set-program-config",
    "set-lag-w",
    "set-gains",
    "set-vbat-factors",
    "set-senses-cal",
    "set-senses-delay",
    "bitfield",
    "default",
    "live-data",
    "live-data-string",
    "group",
    "command",
    "set-mb-drc",
    "filter",
    "no-init",
    "features",
    "cf-memory",
    "set-framework-use-case",
    "set-vddp-config",
)

CONTAINER_HEADER_SIZE = 46
PROFILE_ID = 0x1234


class ContainerError(ValueError):
    pass


def read_c_string(data: bytes, offset: int) -> str:
    if offset < 0 or offset >= len(data):
        raise ContainerError(f"string offset 0x{offset:x} is outside the container")
    end = data.find(b"\0", offset)
    if end < 0:
        raise ContainerError(f"string at 0x{offset:x} is not terminated")
    return data[offset:end].decode("ascii", errors="replace")


def unpack_descriptor(data: bytes, offset: int) -> tuple[int, int]:
    if offset < 0 or offset + 4 > len(data):
        raise ContainerError(f"descriptor at 0x{offset:x} is truncated")
    raw = struct.unpack_from("<I", data, offset)[0]
    return raw & 0x00FFFFFF, raw >> 24


def descriptor_name(type_id: int) -> str:
    if type_id < len(DESCRIPTOR_TYPES):
        return DESCRIPTOR_TYPES[type_id]
    return f"unknown-{type_id}"


def parse_file(data: bytes, offset: int) -> dict[str, object]:
    name_offset, name_type = unpack_descriptor(data, offset)
    if name_type != 3:
        raise ContainerError(f"file at 0x{offset:x} has a non-string name")
    if offset + 8 > len(data):
        raise ContainerError(f"file descriptor at 0x{offset:x} is truncated")

    size = struct.unpack_from("<I", data, offset + 4)[0]
    payload_offset = offset + 8
    payload_end = payload_offset + size
    if payload_end > len(data):
        raise ContainerError(f"file at 0x{offset:x} extends past the container")

    result: dict[str, object] = {
        "name": read_c_string(data, name_offset),
        "size": size,
        "offset": offset,
    }
    if size >= 36:
        file_id = data[payload_offset : payload_offset + 2].decode(
            "ascii", errors="replace"
        )
        version = data[payload_offset + 2 : payload_offset + 4].decode(
            "ascii", errors="replace"
        )
        subversion = data[payload_offset + 4 : payload_offset + 6].decode(
            "ascii", errors="replace"
        )
        declared_size, crc = struct.unpack_from("<HI", data, payload_offset + 6)
        result.update(
            {
                "id": file_id,
                "version": version,
                "subversion": subversion,
                "declared_size": declared_size,
                "crc": crc,
                "customer": data[payload_offset + 12 : payload_offset + 20]
                .rstrip(b"\0")
                .decode("ascii", errors="replace"),
                "application": data[payload_offset + 20 : payload_offset + 28]
                .rstrip(b"\0")
                .decode("ascii", errors="replace"),
                "type": data[payload_offset + 28 : payload_offset + 36]
                .rstrip(b"\0")
                .decode("ascii", errors="replace"),
            }
        )
    return result


def parse_profile(data: bytes, offset: int) -> dict[str, object]:
    if offset < 0 or offset + 8 > len(data):
        raise ContainerError(f"profile at 0x{offset:x} is truncated")
    packed = struct.unpack_from("<I", data, offset)[0]
    length = packed & 0xFF
    group = (packed >> 8) & 0xFF
    profile_id = packed >> 16
    if profile_id != PROFILE_ID:
        raise ContainerError(
            f"profile at 0x{offset:x} has invalid ID 0x{profile_id:04x}"
        )
    if length == 0 or offset + 4 + length * 4 > len(data):
        raise ContainerError(f"profile at 0x{offset:x} has invalid length {length}")

    name_offset, name_type = unpack_descriptor(data, offset + 4)
    if name_type != 3:
        raise ContainerError(f"profile at 0x{offset:x} has a non-string name")

    descriptors: list[tuple[int, int]] = []
    counts: collections.Counter[str] = collections.Counter()
    files: list[dict[str, object]] = []
    for index in range(1, length):
        target, type_id = unpack_descriptor(data, offset + 4 + index * 4)
        descriptors.append((target, type_id))
        counts[descriptor_name(type_id)] += 1
        if type_id in (4, 5):
            files.append(parse_file(data, target))

    return {
        "offset": offset,
        "length": length,
        "group": group,
        "name": read_c_string(data, name_offset),
        "descriptors": descriptors,
        "counts": counts,
        "files": files,
    }


def parse_device(data: bytes, offset: int) -> dict[str, object]:
    if offset < 0 or offset + 12 > len(data):
        raise ContainerError(f"device at 0x{offset:x} is truncated")
    length, bus, address, function, device_id = struct.unpack_from(
        "<BBBBI", data, offset
    )
    if offset + 12 + length * 4 > len(data):
        raise ContainerError(f"device at 0x{offset:x} has invalid length {length}")
    name_offset, name_type = unpack_descriptor(data, offset + 8)
    if name_type != 3:
        raise ContainerError(f"device at 0x{offset:x} has a non-string name")

    descriptors: list[tuple[int, int]] = []
    counts: collections.Counter[str] = collections.Counter()
    profiles: list[dict[str, object]] = []
    files: list[dict[str, object]] = []
    for index in range(length):
        target, type_id = unpack_descriptor(data, offset + 12 + index * 4)
        descriptors.append((target, type_id))
        counts[descriptor_name(type_id)] += 1
        if type_id == 1:
            profiles.append(parse_profile(data, target))
        elif type_id in (4, 5):
            files.append(parse_file(data, target))

    return {
        "offset": offset,
        "length": length,
        "bus": bus,
        "address": address,
        "function": function,
        "device_id": device_id,
        "name": read_c_string(data, name_offset),
        "counts": counts,
        "descriptors": descriptors,
        "profiles": profiles,
        "files": files,
    }


def fixed_string(data: bytes) -> str:
    return data.rstrip(b"\0").decode("ascii", errors="replace")


def format_counts(counts: collections.Counter[str]) -> str:
    return ", ".join(f"{name}={count}" for name, count in sorted(counts.items()))


def load_field_names(path: Path | None) -> dict[int, str]:
    if path is None:
        return {}
    field_names: dict[int, str] = {}
    pattern = re.compile(r"BF_([A-Z0-9_]+)\s*=\s*0x([0-9a-fA-F]+)")
    for match in pattern.finditer(path.read_text(encoding="utf-8")):
        field_names[int(match.group(2), 16)] = match.group(1)
    if not field_names:
        raise ContainerError(f"no TFA bitfield names found in {path}")
    return field_names


def describe_descriptor(
    data: bytes, descriptor: tuple[int, int], field_names: dict[int, str]
) -> str:
    target, type_id = descriptor
    type_name = descriptor_name(type_id)
    if type_id == 2:
        if target + 5 > len(data):
            raise ContainerError(f"register descriptor at 0x{target:x} is truncated")
        address, value, mask = struct.unpack_from("<BHH", data, target)
        return (
            f"{type_name}: reg 0x{address:02x}, value 0x{value:04x}, "
            f"mask 0x{mask:04x}"
        )
    if type_id == 16:
        if target + 4 > len(data):
            raise ContainerError(f"bitfield descriptor at 0x{target:x} is truncated")
        value, field = struct.unpack_from("<HH", data, target)
        register = field >> 8
        position = (field >> 4) & 0xF
        width = (field & 0xF) + 1
        name = field_names.get(field, "unknown")
        return (
            f"{type_name}: {name} field 0x{field:04x} "
            f"(reg 0x{register:02x}, bit {position}, width {width}) = 0x{value:x}"
        )
    return f"{type_name}: target 0x{target:x}"


def inspect(path: Path, details: bool, field_names: dict[int, str]) -> None:
    data = path.read_bytes()
    if len(data) < CONTAINER_HEADER_SIZE:
        raise ContainerError("file is shorter than an NXP container header")

    container_id = fixed_string(data[0:2])
    version = fixed_string(data[2:4])
    subversion = fixed_string(data[4:6])
    size, expected_crc, revision = struct.unpack_from("<IIH", data, 6)
    customer = fixed_string(data[16:24])
    application = fixed_string(data[24:32])
    product_type = fixed_string(data[32:40])
    device_count, profile_count, live_data_count = struct.unpack_from(
        "<HHH", data, 40
    )
    if size > len(data):
        raise ContainerError(
            f"declared size {size} is larger than the {len(data)}-byte file"
        )
    actual_crc = zlib.crc32(data[14:size])

    print(f"File: {path}")
    print(f"SHA256: {hashlib.sha256(data).hexdigest()}")
    print(f"Container: {container_id}{version}{subversion}")
    print(f"Size: {size} bytes (file: {len(data)} bytes)")
    print(
        f"CRC32: 0x{expected_crc:08x} "
        f"({'valid' if actual_crc == expected_crc else f'invalid, got 0x{actual_crc:08x}'})"
    )
    print(f"Revision: {revision}")
    print(f"Customer: {customer}")
    print(f"Application: {application}")
    print(f"Type: {product_type}")
    print(
        f"Devices: {device_count}; profiles: {profile_count}; "
        f"live-data lists: {live_data_count}"
    )

    devices: list[dict[str, object]] = []
    for index in range(device_count):
        target, type_id = unpack_descriptor(data, CONTAINER_HEADER_SIZE + index * 4)
        if type_id != 0:
            raise ContainerError(f"index {index} is not a device descriptor")
        devices.append(parse_device(data, target))

    for index, device in enumerate(devices):
        print()
        print(
            f"Device {index}: {device['name']} at I2C 0x{device['address']:02x} "
            f"(bus {device['bus']}, function {device['function']}, "
            f"ID 0x{device['device_id']:08x})"
        )
        print(f"  Container offset: 0x{device['offset']:x}")
        print(f"  Descriptors: {format_counts(device['counts'])}")
        if details:
            for descriptor in device["descriptors"]:
                print(f"    {describe_descriptor(data, descriptor, field_names)}")
        for file_info in device["files"]:
            print(
                f"  Device file: {file_info['name']} ({file_info['size']} bytes, "
                f"type {file_info.get('id', 'unknown')})"
            )
        for profile_index, profile in enumerate(device["profiles"]):
            print(
                f"  Profile {profile_index}: {profile['name']} "
                f"(group {profile['group']}, offset 0x{profile['offset']:x})"
            )
            print(f"    Descriptors: {format_counts(profile['counts']) or 'none'}")
            if details:
                for descriptor in profile["descriptors"]:
                    print(f"      {describe_descriptor(data, descriptor, field_names)}")
            for file_info in profile["files"]:
                print(
                    f"    File: {file_info['name']} ({file_info['size']} bytes, "
                    f"type {file_info.get('id', 'unknown')})"
                )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("container", type=Path, help="path to tfa98xx.cnt")
    parser.add_argument(
        "--details", action="store_true", help="show every register and bitfield entry"
    )
    parser.add_argument(
        "--field-header",
        type=Path,
        help="generated TFA field-name header used to decode bitfield IDs",
    )
    args = parser.parse_args()
    try:
        inspect(args.container, args.details, load_field_names(args.field_header))
    except (ContainerError, OSError, struct.error) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
