#!/usr/bin/env python3
"""Apply OnePlus QFIL GPT-file patches offline and validate the result."""

from __future__ import annotations

import argparse
import re
import struct
import sys
import xml.etree.ElementTree as ET
import zlib
from pathlib import Path


SECTOR_SIZE = 4096
HEADER_FORMAT = "<8sIIIIQQQQ16sQIII"


def fail(message: str) -> None:
    raise SystemExit(f"ERROR: {message}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Patch stock hotdog GPT images using the packaged QFIL XML"
    )
    parser.add_argument("source_plan", type=Path)
    parser.add_argument("live_capture", type=Path)
    parser.add_argument("output_dir", type=Path)
    return parser.parse_args()


def arithmetic(expression: str, disk_sectors: int) -> int:
    normalized = expression.replace("NUM_DISK_SECTORS", str(disk_sectors)).replace(".", "")
    if not re.fullmatch(r"[0-9+*/() -]+", normalized):
        fail(f"unsupported arithmetic expression: {expression}")
    return int(eval(normalized, {"__builtins__": {}}, {}))  # noqa: S307


def patch_value(expression: str, image: bytearray, disk_sectors: int) -> int:
    match = re.fullmatch(r"CRC32\(([^,]+),([^)]+)\)", expression)
    if match:
        start_sector = arithmetic(match.group(1), disk_sectors)
        byte_count = arithmetic(match.group(2), disk_sectors)
        start = start_sector * SECTOR_SIZE
        end = start + byte_count
        if start < 0 or end > len(image):
            fail(f"CRC32 range outside local GPT image: {expression}")
        return zlib.crc32(image[start:end]) & 0xFFFFFFFF
    return arithmetic(expression, disk_sectors)


def gpt_header(image: bytes, header_sector: int) -> tuple:
    offset = header_sector * SECTOR_SIZE
    values = struct.unpack_from(HEADER_FORMAT, image, offset)
    if values[0] != b"EFI PART":
        fail(f"invalid GPT signature at local sector {header_sector}")
    return values


def validate_gpt(image: bytes, lun: int, disk_sectors: int, backup: bool) -> None:
    header_sector = 4 if backup else 1
    array_sector = 0 if backup else 2
    values = gpt_header(image, header_sector)
    (
        _,
        _,
        header_size,
        stored_header_crc,
        _,
        current_lba,
        backup_lba,
        _,
        _,
        _,
        entries_lba,
        entry_count,
        entry_size,
        stored_array_crc,
    ) = values

    expected_current = disk_sectors - 1 if backup else 1
    expected_backup = 1 if backup else disk_sectors - 1
    expected_entries = disk_sectors - 5 if backup else 2
    if (current_lba, backup_lba, entries_lba) != (
        expected_current,
        expected_backup,
        expected_entries,
    ):
        fail(
            f"LUN {lun} {'backup' if backup else 'primary'} GPT locations are invalid"
        )

    header_offset = header_sector * SECTOR_SIZE
    header = bytearray(image[header_offset : header_offset + header_size])
    struct.pack_into("<I", header, 16, 0)
    actual_header_crc = zlib.crc32(header) & 0xFFFFFFFF
    if actual_header_crc != stored_header_crc:
        fail(f"LUN {lun} GPT header CRC mismatch")

    array_size = entry_count * entry_size
    array_offset = array_sector * SECTOR_SIZE
    actual_array_crc = zlib.crc32(image[array_offset : array_offset + array_size]) & 0xFFFFFFFF
    if actual_array_crc != stored_array_crc:
        fail(f"LUN {lun} GPT partition-array CRC mismatch")


def main() -> int:
    args = parse_args()
    source = args.source_plan.resolve()
    capture = args.live_capture.resolve()
    output = args.output_dir

    if not source.is_dir():
        fail(f"missing source plan: {source}")
    if not capture.is_dir():
        fail(f"missing live capture: {capture}")
    if output.exists():
        fail(f"output already exists: {output}")
    output.mkdir(parents=True)

    for lun in range(6):
        live_primary = (capture / "gpt" / "raw" / f"lun{lun}-primary.bin").read_bytes()
        live_header = gpt_header(live_primary, 1)
        disk_sectors = int(live_header[6]) + 1

        images = {
            f"gpt_main{lun}.bin": bytearray((source / f"gpt_main{lun}.bin").read_bytes()),
            f"gpt_backup{lun}.bin": bytearray((source / f"gpt_backup{lun}.bin").read_bytes()),
        }

        patch_root = ET.parse(source / f"patch{lun}.xml").getroot()
        applied = 0
        for element in patch_root.findall("patch"):
            filename = element.get("filename", "")
            if filename == "DISK":
                continue
            if filename not in images:
                fail(f"unexpected local patch target in LUN {lun}: {filename}")
            if int(element.get("physical_partition_number", "-1")) != lun:
                fail(f"patch LUN mismatch in patch{lun}.xml")
            if int(element.get("SECTOR_SIZE_IN_BYTES", "0")) != SECTOR_SIZE:
                fail(f"unexpected sector size in patch{lun}.xml")

            image = images[filename]
            start_sector = arithmetic(element.get("start_sector", ""), disk_sectors)
            byte_offset = int(element.get("byte_offset", ""))
            size = int(element.get("size_in_bytes", ""))
            if size not in (4, 8):
                fail(f"unsupported patch width in patch{lun}.xml: {size}")
            offset = start_sector * SECTOR_SIZE + byte_offset
            value = patch_value(element.get("value", ""), image, disk_sectors)
            if offset < 0 or offset + size > len(image):
                fail(f"patch outside local image {filename}")
            struct.pack_into("<I" if size == 4 else "<Q", image, offset, value)
            applied += 1

        if applied == 0:
            fail(f"no local GPT patches found for LUN {lun}")

        primary = bytes(images[f"gpt_main{lun}.bin"])
        backup = bytes(images[f"gpt_backup{lun}.bin"])
        validate_gpt(primary, lun, disk_sectors, backup=False)
        validate_gpt(backup, lun, disk_sectors, backup=True)
        (output / f"gpt_main{lun}.bin").write_bytes(primary)
        (output / f"gpt_backup{lun}.bin").write_bytes(backup)
        print(
            f"LUN {lun}: sectors={disk_sectors} local_patches={applied} "
            "primary_crc=ok backup_crc=ok"
        )

    print("PATCHED_STOCK_GPT_VALIDATED")
    return 0


if __name__ == "__main__":
    sys.exit(main())

