#!/usr/bin/env python3
"""Prepare bounded GPT patches for a pmOS image flashed to Hotdog userdata."""

import argparse
import binascii
import hashlib
import json
import pathlib
import struct
import sys


SECTOR_SIZE = 4096
HOTDOG_USERDATA_SIZE = 232382812160
GPT_SIGNATURE = b"EFI PART"
PROTECTIVE_MBR_TYPE = 0xEE


class GptError(Exception):
    pass


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(8 * 1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def checked_header(sector, label):
    if sector[:8] != GPT_SIGNATURE:
        raise GptError(f"{label} GPT signature is missing")
    header_size, stored_crc = struct.unpack_from("<II", sector, 12)
    if not 92 <= header_size <= SECTOR_SIZE:
        raise GptError(f"{label} GPT header size is invalid: {header_size}")
    candidate = bytearray(sector)
    candidate[16:20] = b"\0" * 4
    calculated = binascii.crc32(candidate[:header_size]) & 0xFFFFFFFF
    if calculated != stored_crc:
        raise GptError(
            f"{label} GPT header CRC mismatch: {stored_crc:08x} != {calculated:08x}"
        )
    return header_size


def update_header(sector, *, current_lba, backup_lba, last_usable_lba,
                  entries_lba, entries_crc):
    updated = bytearray(sector)
    header_size = struct.unpack_from("<I", updated, 12)[0]
    struct.pack_into("<Q", updated, 24, current_lba)
    struct.pack_into("<Q", updated, 32, backup_lba)
    struct.pack_into("<Q", updated, 48, last_usable_lba)
    struct.pack_into("<Q", updated, 72, entries_lba)
    struct.pack_into("<I", updated, 88, entries_crc)
    updated[16:20] = b"\0" * 4
    struct.pack_into("<I", updated, 16,
                     binascii.crc32(updated[:header_size]) & 0xFFFFFFFF)
    return bytes(updated)


def prepare(input_path, output_dir, device_size, partition_number,
            expected_sha256):
    if device_size % SECTOR_SIZE:
        raise GptError("device size is not a multiple of 4096")
    if input_path.stat().st_size % SECTOR_SIZE:
        raise GptError("input size is not a multiple of 4096")
    if device_size <= input_path.stat().st_size:
        raise GptError("device size must be larger than the input image")
    if output_dir.exists():
        raise GptError(f"output directory already exists: {output_dir}")

    input_sha256 = sha256_file(input_path)
    if expected_sha256 and input_sha256 != expected_sha256.lower():
        raise GptError("input SHA256 does not match the pinned value")

    with input_path.open("rb") as source:
        mbr_sector = bytearray(source.read(SECTOR_SIZE))
        primary_sector = source.read(SECTOR_SIZE)
    if len(primary_sector) != SECTOR_SIZE:
        raise GptError("input is shorter than the primary GPT header")
    if mbr_sector[510:512] != b"\x55\xaa":
        raise GptError("protective MBR signature is missing")
    if mbr_sector[450] != PROTECTIVE_MBR_TYPE:
        raise GptError("protective MBR partition type is not 0xee")
    checked_header(primary_sector, "primary")

    current_lba, old_backup_lba, first_usable_lba, old_last_usable_lba = \
        struct.unpack_from("<QQQQ", primary_sector, 24)
    entries_lba, entry_count, entry_size, stored_entries_crc = \
        struct.unpack_from("<QIII", primary_sector, 72)
    if current_lba != 1 or entries_lba != 2:
        raise GptError("unsupported primary GPT geometry")
    if entry_size < 128 or entry_size % 8 or not 1 <= entry_count <= 1024:
        raise GptError("unsupported GPT entry geometry")

    entries_bytes = entry_count * entry_size
    entries_sectors = (entries_bytes + SECTOR_SIZE - 1) // SECTOR_SIZE
    with input_path.open("rb") as source:
        source.seek(entries_lba * SECTOR_SIZE)
        entries = bytearray(source.read(entries_bytes))
    if len(entries) != entries_bytes:
        raise GptError("partition entry array is truncated")
    calculated_entries_crc = binascii.crc32(entries) & 0xFFFFFFFF
    if calculated_entries_crc != stored_entries_crc:
        raise GptError("primary partition entry CRC mismatch")

    entry_index = partition_number - 1
    if not 0 <= entry_index < entry_count:
        raise GptError("partition number is outside the GPT entry array")
    entry_offset = entry_index * entry_size
    if entries[entry_offset:entry_offset + 16] == b"\0" * 16:
        raise GptError("selected GPT partition entry is unused")
    partition_start, old_partition_end = struct.unpack_from(
        "<QQ", entries, entry_offset + 32
    )

    target_backup_lba = device_size // SECTOR_SIZE - 1
    target_entries_lba = target_backup_lba - entries_sectors
    target_last_usable_lba = target_entries_lba - 1
    if target_last_usable_lba <= partition_start:
        raise GptError("target device is too small for the selected partition")
    struct.pack_into("<Q", entries, entry_offset + 40, target_last_usable_lba)
    entries_crc = binascii.crc32(entries) & 0xFFFFFFFF

    entries_padded = bytes(entries).ljust(entries_sectors * SECTOR_SIZE, b"\0")
    primary_header = update_header(
        primary_sector,
        current_lba=1,
        backup_lba=target_backup_lba,
        last_usable_lba=target_last_usable_lba,
        entries_lba=entries_lba,
        entries_crc=entries_crc,
    )
    backup_header = update_header(
        primary_sector,
        current_lba=target_backup_lba,
        backup_lba=1,
        last_usable_lba=target_last_usable_lba,
        entries_lba=target_entries_lba,
        entries_crc=entries_crc,
    )

    struct.pack_into("<I", mbr_sector, 458,
                     min(target_backup_lba, 0xFFFFFFFF))
    primary_patch = bytes(mbr_sector) + primary_header + entries_padded
    backup_patch = entries_padded + backup_header
    stale_start_lba = old_backup_lba - entries_sectors
    stale_size = (entries_sectors + 1) * SECTOR_SIZE

    output_dir.mkdir(parents=True)
    primary_path = output_dir / "primary-gpt.bin"
    backup_path = output_dir / "backup-gpt.bin"
    primary_path.write_bytes(primary_patch)
    backup_path.write_bytes(backup_patch)

    manifest = {
        "format": "hotdog-userdata-gpt-patches-v1",
        "sector_size": SECTOR_SIZE,
        "input": {
            "path": str(input_path),
            "size": input_path.stat().st_size,
            "sha256": input_sha256,
            "backup_lba": old_backup_lba,
            "last_usable_lba": old_last_usable_lba,
        },
        "target": {
            "device_size": device_size,
            "backup_lba": target_backup_lba,
            "last_usable_lba": target_last_usable_lba,
            "backup_entries_lba": target_entries_lba,
        },
        "partition": {
            "number": partition_number,
            "start_lba": partition_start,
            "old_end_lba": old_partition_end,
            "new_end_lba": target_last_usable_lba,
        },
        "patches": {
            "primary-gpt.bin": {
                "offset": 0,
                "size": len(primary_patch),
                "sha256": sha256_bytes(primary_patch),
            },
            "backup-gpt.bin": {
                "offset": target_entries_lba * SECTOR_SIZE,
                "size": len(backup_patch),
                "sha256": sha256_bytes(backup_patch),
            },
            "stale-backup-zero": {
                "offset": stale_start_lba * SECTOR_SIZE,
                "size": stale_size,
                "sha256": sha256_bytes(b"\0" * stale_size),
            },
        },
    }
    (output_dir / "manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="ascii"
    )
    return manifest


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path)
    parser.add_argument("--device-size", type=int, default=HOTDOG_USERDATA_SIZE)
    parser.add_argument("--partition", type=int, default=2)
    parser.add_argument("--expect-input-sha256")
    args = parser.parse_args()
    try:
        manifest = prepare(
            args.input, args.output, args.device_size, args.partition,
            args.expect_input_sha256,
        )
    except (GptError, OSError) as error:
        print(f"prepare-hotdog-userdata-gpt: {error}", file=sys.stderr)
        return 2
    print(json.dumps(manifest["target"], sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
