#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Inspect and optionally extract entries from an Android DT table image."""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path


DT_TABLE_MAGIC = 0xD7B7AB1E
FDT_MAGIC = 0xD00DFEED
HEADER = struct.Struct(">8I")
ENTRY = struct.Struct(">8I")


class ImageError(ValueError):
    """Raised when the DT table or one of its entries is malformed."""


def parse_image(path: Path) -> tuple[dict[str, int], list[dict[str, object]], bytes]:
    data = path.read_bytes()
    if len(data) < HEADER.size:
        raise ImageError(f"image is smaller than the {HEADER.size}-byte header")

    values = HEADER.unpack_from(data)
    names = (
        "magic",
        "total_size",
        "header_size",
        "entry_size",
        "entry_count",
        "entries_offset",
        "page_size",
        "version",
    )
    header = dict(zip(names, values, strict=True))
    if header["magic"] != DT_TABLE_MAGIC:
        raise ImageError(f"bad magic 0x{header['magic']:08x}")
    if header["header_size"] < HEADER.size:
        raise ImageError("header_size is smaller than the standard header")
    if header["entry_size"] < ENTRY.size:
        raise ImageError("entry_size is smaller than the standard entry")
    if header["total_size"] > len(data):
        raise ImageError("declared total_size exceeds the image size")

    table_end = header["entries_offset"] + header["entry_count"] * header["entry_size"]
    if table_end > header["total_size"]:
        raise ImageError("entry table exceeds declared total_size")

    entries: list[dict[str, object]] = []
    for index in range(header["entry_count"]):
        position = header["entries_offset"] + index * header["entry_size"]
        dt_size, dt_offset, entry_id, revision, *custom = ENTRY.unpack_from(data, position)
        end = dt_offset + dt_size
        if dt_offset < table_end or end > header["total_size"]:
            raise ImageError(f"entry {index} points outside the payload area")
        blob = data[dt_offset:end]
        if len(blob) < 4 or struct.unpack_from(">I", blob)[0] != FDT_MAGIC:
            raise ImageError(f"entry {index} is not a flattened device tree")
        entries.append(
            {
                "index": index,
                "offset": dt_offset,
                "size": dt_size,
                "id": entry_id,
                "revision": revision,
                "custom": custom,
                "sha256": hashlib.sha256(blob).hexdigest(),
            }
        )
    return header, entries, data


def fdtget(path: Path, prop: str, value_type: str) -> list[str] | None:
    result = subprocess.run(
        ["fdtget", "-t", value_type, str(path), "/", prop],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return None
    return result.stdout.strip().split()


def inspect_fdt(entries: list[dict[str, object]], data: bytes) -> None:
    if shutil.which("fdtget") is None:
        raise ImageError("--inspect-fdt requires fdtget from dtc")

    with tempfile.TemporaryDirectory(prefix="android-dt-table-") as directory:
        root = Path(directory)
        for entry in entries:
            offset = int(entry["offset"])
            size = int(entry["size"])
            path = root / f"{entry['index']:02d}.dtb"
            path.write_bytes(data[offset : offset + size])
            properties: dict[str, object] = {}
            for prop in ("model", "compatible"):
                value = fdtget(path, prop, "s")
                if value is not None:
                    properties[prop] = value
            for prop in ("oplus,dtsi_no", "qcom,board-id", "qcom,msm-id"):
                value = fdtget(path, prop, "x")
                if value is not None:
                    properties[prop] = [f"0x{int(item, 16):x}" for item in value]
            entry["root_properties"] = properties


def extract(entries: list[dict[str, object]], data: bytes, directory: Path) -> None:
    targets = [directory / f"{int(entry['index']):02d}.dtb" for entry in entries]
    existing = [path for path in targets if path.exists()]
    if existing:
        raise ImageError(f"refusing to overwrite {existing[0]}")
    directory.mkdir(parents=True, exist_ok=True)
    for entry, path in zip(entries, targets, strict=True):
        offset = int(entry["offset"])
        size = int(entry["size"])
        path.write_bytes(data[offset : offset + size])


def print_tsv(entries: list[dict[str, object]]) -> None:
    print(
        "index\toffset\tsize\tid\trevision\tcustom\tsha256\tmodel\tcompatible"
        "\toplus,dtsi_no\tqcom,board-id\tqcom,msm-id"
    )
    for entry in entries:
        properties = entry.get("root_properties", {})
        assert isinstance(properties, dict)

        def join(name: str) -> str:
            value = properties.get(name, [])
            assert isinstance(value, list)
            return ",".join(str(item) for item in value)

        fields = (
            entry["index"],
            entry["offset"],
            entry["size"],
            f"0x{int(entry['id']):08x}",
            f"0x{int(entry['revision']):08x}",
            ",".join(f"0x{int(value):08x}" for value in entry["custom"]),
            entry["sha256"],
            join("model"),
            join("compatible"),
            join("oplus,dtsi_no"),
            join("qcom,board-id"),
            join("qcom,msm-id"),
        )
        print("\t".join(str(field).replace("\t", " ") for field in fields))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", type=Path, help="Android dtbo.img or DT table image")
    parser.add_argument(
        "--extract-dir",
        type=Path,
        help="write each table entry to this directory without overwriting files",
    )
    parser.add_argument(
        "--inspect-fdt",
        action="store_true",
        help="read identifying root properties using fdtget",
    )
    parser.add_argument(
        "--format",
        choices=("json", "tsv"),
        default="json",
        help="output format (default: json)",
    )
    args = parser.parse_args()

    try:
        header, entries, data = parse_image(args.image)
        if args.inspect_fdt:
            inspect_fdt(entries, data)
        if args.extract_dir is not None:
            extract(entries, data, args.extract_dir)
    except (OSError, ImageError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    if args.format == "tsv":
        print_tsv(entries)
    else:
        document = {
            "schema": 1,
            "image": str(args.image),
            "image_size": len(data),
            "header": header,
            "entries": entries,
        }
        json.dump(document, sys.stdout, indent=2, sort_keys=True)
        print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
