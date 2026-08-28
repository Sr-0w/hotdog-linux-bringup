#!/usr/bin/env python3
"""Build the Hotdog verification-disabled vbmeta from regional stock images."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import sys


AVB_MAGIC = b"AVB0"
FLAGS_OFFSET = 120
FLAGS_SIZE = 4
EXPECTED_INPUT_FLAGS = 0
OUTPUT_FLAGS = 3
DEFAULT_PARTITION_SIZE = 65536


class VbmetaError(ValueError):
    pass


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def patch_vbmeta(path: pathlib.Path, partition_size: int) -> tuple[bytes, dict[str, object]]:
    data = path.read_bytes()
    if len(data) < FLAGS_OFFSET + FLAGS_SIZE or data[:4] != AVB_MAGIC:
        raise VbmetaError(f"{path.name}: not an AVB vbmeta image")
    if len(data) > partition_size:
        raise VbmetaError(f"{path.name}: image exceeds partition size")

    flags = int.from_bytes(data[FLAGS_OFFSET : FLAGS_OFFSET + FLAGS_SIZE], "big")
    if flags != EXPECTED_INPUT_FLAGS:
        raise VbmetaError(f"{path.name}: expected stock flags 0, found {flags}")

    output = bytearray(data)
    output[FLAGS_OFFSET : FLAGS_OFFSET + FLAGS_SIZE] = OUTPUT_FLAGS.to_bytes(
        FLAGS_SIZE, "big"
    )
    output.extend(bytes(partition_size - len(output)))
    return bytes(output), {
        "name": path.name,
        "size": len(data),
        "sha256": sha256(data),
        "input_flags": flags,
    }


def write_output(path: pathlib.Path, data: bytes) -> dict[str, object]:
    path.parent.mkdir(parents=True, exist_ok=False)
    path.write_bytes(data)
    return {"path": str(path.relative_to(path.parents[1])), "size": len(data), "sha256": sha256(data)}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--in-vbmeta", required=True, type=pathlib.Path)
    parser.add_argument("--eu-vbmeta", required=True, type=pathlib.Path)
    parser.add_argument("--outdir", required=True, type=pathlib.Path)
    parser.add_argument("--partition-size", type=int, default=DEFAULT_PARTITION_SIZE)
    args = parser.parse_args()

    if args.partition_size < FLAGS_OFFSET + FLAGS_SIZE:
        parser.error("--partition-size is too small")
    if args.outdir.exists():
        parser.error(f"output directory already exists: {args.outdir}")

    try:
        in_output, in_source = patch_vbmeta(args.in_vbmeta, args.partition_size)
        eu_output, eu_source = patch_vbmeta(args.eu_vbmeta, args.partition_size)
    except (OSError, VbmetaError) as error:
        print(f"build-hotdog-regional-vbmeta: {error}", file=sys.stderr)
        return 2

    args.outdir.mkdir(parents=True)
    outputs: dict[str, dict[str, object]] = {}
    split_required = in_output != eu_output
    if split_required:
        outputs["HD1911-IN"] = write_output(
            args.outdir / "HD1911-IN" / "vbmeta-disabled.img", in_output
        )
        outputs["HD1913-EU"] = write_output(
            args.outdir / "HD1913-EU" / "vbmeta-disabled.img", eu_output
        )
    else:
        outputs["common"] = write_output(
            args.outdir / "common" / "vbmeta-disabled.img", in_output
        )

    manifest = {
        "format": "hotdog-regional-vbmeta-v1",
        "partition_size": args.partition_size,
        "flags_offset": FLAGS_OFFSET,
        "output_flags": OUTPUT_FLAGS,
        "regional_split_required": split_required,
        "sources": {"HD1911-IN": in_source, "HD1913-EU": eu_source},
        "outputs": outputs,
    }
    (args.outdir / "manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n"
    )
    print(json.dumps(manifest, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
