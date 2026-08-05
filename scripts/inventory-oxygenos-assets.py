#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Create a hash-only inventory of hardware assets from an OxygenOS dump."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
from collections import Counter
from pathlib import Path


FIRMWARE_IMAGE_NAMES = {
    "BTFM.bin",
    "NON-HLOS.bin",
    "aop.mbn",
    "apdp.mbn",
    "cmnlib.mbn",
    "cmnlib64.mbn",
    "devcfg.mbn",
    "dspso.bin",
    "fw_ufs1.bin",
    "fw_ufs2.bin",
    "hyp.mbn",
    "imagefv.elf",
    "km4.mbn",
    "msadp.mbn",
    "multi_image.mbn",
    "qupv3fw.elf",
    "sec.elf",
    "storsec.mbn",
    "tz.mbn",
    "uefi_sec.mbn",
    "xbl.elf",
    "xbl_config.elf",
}

CONFIG_KEYWORDS = {
    "audio",
    "bluetooth",
    "camera",
    "charger",
    "display",
    "gps",
    "haptic",
    "media",
    "mixer",
    "modem",
    "power",
    "sensor",
    "thermal",
    "touch",
    "usb",
    "wifi",
    "wlan",
}

CONFIG_SUFFIXES = {
    ".conf",
    ".ini",
    ".json",
    ".prop",
    ".txt",
    ".xml",
}

MEDIA_PREFIXES = ("alarm_", "notif_", "ring_")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def run_modinfo(path: Path) -> dict[str, object]:
    try:
        result = subprocess.run(
            ["modinfo", str(path)],
            check=True,
            capture_output=True,
            text=True,
        )
    except (FileNotFoundError, subprocess.CalledProcessError):
        return {}

    values: dict[str, list[str]] = {}
    for line in result.stdout.splitlines():
        key, separator, value = line.partition(":")
        if not separator:
            continue
        values.setdefault(key.strip(), []).append(value.strip())

    metadata: dict[str, object] = {}
    for key in ("name", "license", "description", "depends", "vermagic"):
        if key in values:
            metadata[key] = values[key][0]
    if "alias" in values:
        metadata["aliases"] = values["alias"]
    return metadata


def classify(path: Path, relative: Path) -> str | None:
    lower_parts = tuple(part.lower() for part in relative.parts)
    lower_name = path.name.lower()

    if path.suffix == ".ko":
        return "kernel-module"
    if path.suffix == ".acdb" or lower_name.endswith(".cnt"):
        return "calibration"
    if "firmware" in lower_parts:
        if lower_name.startswith(MEDIA_PREFIXES):
            return "media-payload"
        return "firmware"
    if any(part in {"lib", "lib64"} for part in lower_parts) and "hw" in lower_parts:
        return "android-hal"
    if "bin" in lower_parts and "hw" in lower_parts:
        return "android-hal"
    if "etc" in lower_parts and path.suffix.lower() in CONFIG_SUFFIXES:
        joined = "/".join(lower_parts)
        if any(keyword in joined for keyword in CONFIG_KEYWORDS):
            return "hardware-config"
    return None


def make_asset(kind: str, source: str, relative: Path, path: Path) -> dict[str, object]:
    asset: dict[str, object] = {
        "kind": kind,
        "source": source,
        "path": relative.as_posix(),
        "size": path.stat().st_size,
        "sha256": sha256(path),
    }
    if kind == "kernel-module":
        asset["module"] = run_modinfo(path)
    return asset


def scan_root(label: str, root: Path) -> list[dict[str, object]]:
    if not root.is_dir():
        raise ValueError(f"{label} root is not a directory: {root}")

    assets: list[dict[str, object]] = []

    def on_error(error: OSError) -> None:
        print(f"warning: {error}", file=sys.stderr)

    for directory, names, files in os.walk(root, onerror=on_error):
        names.sort()
        files.sort()
        base = Path(directory)
        for name in files:
            path = base / name
            if not path.is_file() or path.is_symlink():
                continue
            relative = path.relative_to(root)
            kind = classify(path, relative)
            if kind is not None:
                assets.append(make_asset(kind, label, relative, path))
    return assets


def scan_images(root: Path) -> list[dict[str, object]]:
    if not root.is_dir():
        raise ValueError(f"image root is not a directory: {root}")
    assets = []
    for name in sorted(FIRMWARE_IMAGE_NAMES):
        path = root / name
        if path.is_file():
            assets.append(make_asset("firmware-partition", "images", Path(name), path))
    return assets


def parse_root(value: str) -> tuple[str, Path]:
    label, separator, path = value.partition("=")
    if not separator or not label or not path:
        raise argparse.ArgumentTypeError("root must be written as LABEL=PATH")
    return label, Path(path)


def print_tsv(assets: list[dict[str, object]]) -> None:
    print("kind\tsource\tpath\tsize\tsha256\tmodule\tlicense\tdescription\tvermagic")
    for asset in assets:
        module = asset.get("module", {})
        assert isinstance(module, dict)
        fields = [
            asset["kind"],
            asset["source"],
            asset["path"],
            asset["size"],
            asset["sha256"],
            module.get("name", ""),
            module.get("license", ""),
            module.get("description", ""),
            module.get("vermagic", ""),
        ]
        print("\t".join(str(field).replace("\t", " ") for field in fields))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        type=parse_root,
        action="append",
        default=[],
        metavar="LABEL=PATH",
        help="mounted partition root to scan; may be repeated",
    )
    parser.add_argument(
        "--images",
        type=Path,
        help="directory containing decrypted partition and firmware images",
    )
    parser.add_argument(
        "--format",
        choices=("json", "tsv"),
        default="json",
        help="output format (default: json)",
    )
    args = parser.parse_args()
    if not args.root and args.images is None:
        parser.error("at least one --root or --images argument is required")

    try:
        assets: list[dict[str, object]] = []
        for label, path in args.root:
            assets.extend(scan_root(label, path))
        if args.images is not None:
            assets.extend(scan_images(args.images))
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    assets.sort(key=lambda asset: (asset["kind"], asset["source"], asset["path"]))
    if args.format == "tsv":
        print_tsv(assets)
    else:
        document = {
            "schema": 1,
            "counts": dict(sorted(Counter(asset["kind"] for asset in assets).items())),
            "assets": assets,
        }
        json.dump(document, sys.stdout, indent=2, sort_keys=True)
        print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
