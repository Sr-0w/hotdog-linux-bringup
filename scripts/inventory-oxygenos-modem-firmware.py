#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Inventory nested OnePlus firmware ZIPs and their modem MCFG catalogs."""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import tempfile
import zipfile
from pathlib import Path


MODEM_MEMBER = "firmware-update/modem.img"
MCFG_SUFFIX = "/mcfg_sw.mbn"
MCFG_SIG_SUFFIX = "/mcfg_sw.sig"


def copy_and_hash(source, destination) -> str:
    digest = hashlib.sha256()
    while block := source.read(1024 * 1024):
        destination.write(block)
        digest.update(block)
    destination.flush()
    return digest.hexdigest()


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while block := source.read(1024 * 1024):
            digest.update(block)
    return digest.hexdigest()


def parse_7z_paths(output: str) -> list[str]:
    paths = []
    for line in output.splitlines():
        if not line.startswith("Path = "):
            continue
        path = line[7:].replace("\\", "/")
        if path.startswith("image/") or path.startswith("verinfo/"):
            paths.append(path)
    return paths


def classify_mcfg_paths(paths: list[str]) -> dict[str, object]:
    profiles = [path for path in paths if path.casefold().endswith(MCFG_SUFFIX)]
    signatures = [path for path in paths if path.casefold().endswith(MCFG_SIG_SUFFIX)]
    folded = {}
    for path in profiles:
        folded.setdefault(path.casefold(), []).append(path)
    return {
        "profiles_listed": len(profiles),
        "profiles_unique_casefold": len(folded),
        "profile_duplicate_groups": sum(len(group) > 1 for group in folded.values()),
        "signatures_listed": len(signatures),
        "regions": sorted({
            parts[6].lower()
            for path in folded
            if len((parts := path.split("/"))) > 6
            and parts[:5] == ["image", "modem_pr", "mcfg", "configs", "mcfg_sw"]
            and parts[5].lower() == "generic"
        }),
    }


def seven_zip_paths(modem_path: Path, seven_zip: str) -> list[str]:
    result = subprocess.run(
        [seven_zip, "l", "-slt", str(modem_path)],
        capture_output=True,
        text=True,
    )
    paths = parse_7z_paths(result.stdout)
    if not paths:
        raise ValueError("7z did not expose a FAT image file listing")
    return paths


def inspect_inner(outer: zipfile.ZipFile, member: zipfile.ZipInfo,
                  directory: Path, seven_zip: str) -> dict[str, object]:
    inner_path = directory / "firmware.zip"
    with outer.open(member) as source, inner_path.open("wb") as destination:
        inner_sha = copy_and_hash(source, destination)
    with zipfile.ZipFile(inner_path) as inner:
        try:
            modem = inner.getinfo(MODEM_MEMBER)
        except KeyError as error:
            raise ValueError(f"nested firmware lacks {MODEM_MEMBER}") from error
        modem_path = directory / "modem.img"
        with inner.open(modem) as source, modem_path.open("wb") as destination:
            modem_sha = copy_and_hash(source, destination)
        paths = seven_zip_paths(modem_path, seven_zip)
        firmware_entries = sorted(
            entry.filename
            for entry in inner.infolist()
            if entry.filename.startswith("firmware-update/") and not entry.is_dir()
        )
    return {
        "member": member.filename,
        "inner_size": member.file_size,
        "inner_sha256": inner_sha,
        "modem_size": modem.file_size,
        "modem_sha256": modem_sha,
        "firmware_entry_count": len(firmware_entries),
        "mcfg": classify_mcfg_paths(paths),
    }


def inventory_bundle(path: Path, seven_zip: str = "7z") -> dict[str, object]:
    if not path.is_file():
        raise ValueError("firmware bundle is not a file")
    records = []
    with zipfile.ZipFile(path) as outer:
        members = sorted(
            (entry for entry in outer.infolist() if entry.filename.lower().endswith(".zip")),
            key=lambda entry: entry.filename,
        )
        if not members:
            raise ValueError("firmware bundle contains no nested ZIP")
        for member in members:
            with tempfile.TemporaryDirectory(prefix="hotdog-oos-firmware-") as temporary:
                records.append(inspect_inner(outer, member, Path(temporary), seven_zip))
    return {
        "schema": 1,
        "bundle_size": path.stat().st_size,
        "bundle_sha256": file_sha256(path),
        "firmware_packages": records,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    parser.add_argument("--7z", default="7z", dest="seven_zip")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        document = inventory_bundle(args.bundle, args.seven_zip)
    except (OSError, ValueError, zipfile.BadZipFile) as error:
        print(f"error: {error}", file=__import__("sys").stderr)
        return 1
    encoded = json.dumps(document, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.write_text(encoded)
    else:
        print(encoded, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
