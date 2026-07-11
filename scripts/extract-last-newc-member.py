#!/usr/bin/env python3
"""Write the final occurrence of a member from concatenated newc archives."""

from __future__ import annotations

import argparse
import gzip
import sys
from pathlib import Path


HEADER_SIZE = 110
MAGICS = (b"070701", b"070702")


def align4(value: int) -> int:
    return (value + 3) & ~3


def normalized_name(raw: bytes) -> str:
    name = raw.rstrip(b"\0").decode("utf-8", "surrogateescape")
    while name.startswith("./"):
        name = name[2:]
    return name


def extract_last(payload: bytes, wanted: str) -> tuple[bytes, int, int]:
    offset = 0
    archive_count = 0
    matches: list[bytes] = []

    while offset < len(payload):
        while offset < len(payload) and payload[offset] == 0:
            offset += 1
        if offset == len(payload):
            break
        if payload[offset : offset + 6] not in MAGICS:
            raise ValueError(f"invalid newc magic at offset {offset}")
        if offset + HEADER_SIZE > len(payload):
            raise ValueError(f"truncated newc header at offset {offset}")

        header = payload[offset : offset + HEADER_SIZE]
        try:
            fields = [
                int(header[6 + index * 8 : 14 + index * 8], 16)
                for index in range(13)
            ]
        except ValueError as error:
            raise ValueError(f"invalid hexadecimal field at offset {offset}") from error

        file_size = fields[6]
        name_size = fields[11]
        if name_size < 1:
            raise ValueError(f"invalid zero-length member name at offset {offset}")

        name_start = offset + HEADER_SIZE
        name_end = name_start + name_size
        if name_end > len(payload):
            raise ValueError(f"truncated member name at offset {offset}")
        if payload[name_end - 1] != 0:
            raise ValueError(f"unterminated member name at offset {offset}")

        name = normalized_name(payload[name_start:name_end])
        data_start = align4(name_end)
        data_end = data_start + file_size
        if data_end > len(payload):
            raise ValueError(f"truncated member data for {name!r} at offset {offset}")

        if name == "TRAILER!!!":
            archive_count += 1
        elif name == wanted:
            matches.append(payload[data_start:data_end])

        next_offset = align4(data_end)
        if next_offset <= offset:
            raise ValueError(f"newc parser made no progress at offset {offset}")
        offset = next_offset

    if not matches:
        raise ValueError(f"member not found: {wanted}")
    return matches[-1], len(matches), archive_count


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Extract the final effective member from concatenated newc archives."
    )
    parser.add_argument("archive", type=Path)
    parser.add_argument("member")
    parser.add_argument(
        "--metadata",
        action="store_true",
        help="print archive/member counts to stderr",
    )
    args = parser.parse_args()

    payload = args.archive.read_bytes()
    if payload.startswith(b"\x1f\x8b"):
        payload = gzip.decompress(payload)

    try:
        content, occurrences, archives = extract_last(payload, args.member)
    except ValueError as error:
        parser.error(str(error))

    if args.metadata:
        print(f"archives={archives} occurrences={occurrences}", file=sys.stderr)
    sys.stdout.buffer.write(content)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
