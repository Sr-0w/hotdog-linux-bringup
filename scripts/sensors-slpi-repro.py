#!/usr/bin/env python3
"""Stage and verify the curated hotdog SLPI sensor runtime.

This tool deliberately treats SLPI firmware and the registry as external
inputs.  It never reads from a phone and it never installs the 65-file source
pool as a runtime configuration.  The only Git-owned runtime inputs are the
curated 45-file set and the explicit 47-file ALSPS variant.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import sys
from typing import Iterable


DEFAULT_MANIFEST = "manifests/sensors-slpi-v1.json"
RUNTIME_NAMES = ("sns_reg.conf", "sns_reg_version")
RUNTIME_DIRS = ("config", "registry")


def fail(message: str) -> "NoReturn":
    raise SystemExit(f"error: {message}")


def digest(path: Path) -> tuple[int, str]:
    size = 0
    sha = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            size += len(chunk)
            sha.update(chunk)
    return size, sha.hexdigest()


def load_manifest(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"cannot read manifest {path}: {exc}")


def selection(manifest: dict, variant: str) -> list[dict]:
    if variant not in ("45", "47"):
        fail(f"unsupported variant {variant}; expected 45 or 47")
    entries = list(manifest["config_selection"]["baseline_45"])
    if variant == "47":
        entries.extend(manifest["config_selection"]["alsps_variant_47_additions"])
    names = [entry["path"] for entry in entries]
    if len(names) != int(variant) or len(set(names)) != len(names):
        fail(f"manifest selection {variant} has an invalid file count")
    return entries


def check_entry(path: Path, entry: dict) -> None:
    if not path.is_file() or path.is_symlink():
        fail(f"missing or non-regular file: {path}")
    size, sha = digest(path)
    if size != entry["size"] or sha != entry["sha256"]:
        fail(
            f"hash mismatch for {path}: got size={size} sha256={sha}, "
            f"expected size={entry['size']} sha256={entry['sha256']}"
        )


def verify_selection(repo_root: Path, manifest: dict, variant: str) -> None:
    for entry in selection(manifest, variant):
        check_entry(repo_root / entry["source"], entry)
    print(f"verified curated sensor config variant {variant}: {variant} files")


def verify_helpers(repo_root: Path, manifest: dict) -> None:
    for entry in manifest["tracked_helpers"]:
        check_entry(repo_root / entry["path"], entry)
    print(f"verified helper sources: {len(manifest['tracked_helpers'])} files")


def external_entries(manifest: dict) -> list[dict]:
    entries = list(manifest["image_v16"]["artifacts"])
    entries.append(manifest["image_v16"]["kernel_config"])
    entries.append(manifest["slpi_00121"]["active_mbn"])
    split_root = manifest["slpi_00121"]["split_capture_root"]
    entries.extend(
        {**entry, "path": f"{split_root}/{entry['name']}"}
        for entry in manifest["slpi_00121"]["split_files"]
    )
    entries.extend(manifest["qrtr_kernel_modules"])
    return entries


def verify_external(artifact_root: Path, manifest: dict) -> None:
    for entry in external_entries(manifest):
        check_entry(artifact_root / entry["path"], entry)
    print(f"verified external build and firmware captures: {len(external_entries(manifest))} files")


def ensure_new_directory(path: Path) -> None:
    if path.exists():
        if not path.is_dir() or any(path.iterdir()):
            fail(f"refusing to overwrite non-empty destination: {path}")
    else:
        path.mkdir(parents=True)


def copy_regular(source: Path, destination: Path, mode: int | None = None) -> None:
    if source.is_symlink() or not source.is_file():
        fail(f"external runtime input is not a regular file: {source}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, destination)
    os.chmod(destination, mode if mode is not None else stat.S_IMODE(source.stat().st_mode))


def copy_tree(source: Path, destination: Path) -> list[str]:
    if not source.is_dir() or source.is_symlink():
        fail(f"external runtime directory is missing or unsafe: {source}")
    copied: list[str] = []
    for item in sorted(source.rglob("*")):
        relative = item.relative_to(source)
        target = destination / relative
        if item.is_symlink():
            fail(f"refusing symlink in runtime tree: {item}")
        if item.is_dir():
            target.mkdir(parents=True, exist_ok=True)
            continue
        if not item.is_file():
            fail(f"unsupported runtime tree entry: {item}")
        copy_regular(item, target)
        copied.append(relative.as_posix())
    return copied


def stage(repo_root: Path, manifest: dict, variant: str, out_root: Path,
          external_root: Path | None, replace: bool) -> None:
    verify_selection(repo_root, manifest, variant)
    target = out_root / "sensors"
    if target.exists():
        if not replace:
            fail(f"destination exists; pass --replace only for an intentional replacement: {target}")
        if target.is_symlink() or not target.is_dir():
            fail(f"refusing unsafe destination: {target}")
        shutil.rmtree(target)
    (target / "config").mkdir(parents=True, exist_ok=False)

    for entry in selection(manifest, variant):
        source = repo_root / entry["source"]
        destination = target / "config" / entry["path"]
        copy_regular(source, destination, 0o644)

    if external_root is not None:
        for name in RUNTIME_NAMES:
            copy_regular(external_root / name, target / name)
        for name in RUNTIME_DIRS:
            copy_tree(external_root / name, target / name)
    print(f"staged sensor runtime variant {variant} at {target}")
    if external_root is None:
        print("registry inputs not staged: pass --external-root with a captured sensors root")


def runtime_files(root: Path) -> Iterable[Path]:
    for name in RUNTIME_NAMES:
        path = root / name
        if not path.is_file() or path.is_symlink():
            fail(f"runtime input missing or unsafe: {path}")
        yield path
    for directory in RUNTIME_DIRS:
        path = root / directory
        if not path.is_dir() or path.is_symlink():
            fail(f"runtime directory missing or unsafe: {path}")
        for item in sorted(path.rglob("*")):
            if item.is_symlink():
                fail(f"runtime tree contains symlink: {item}")
            if item.is_file():
                yield item


def snapshot(served_root: Path, destination: Path) -> None:
    if destination.exists():
        fail(f"snapshot destination already exists: {destination}")
    files = list(runtime_files(served_root))
    payload = destination / "payload"
    payload.mkdir(parents=True)
    records = []
    for source in files:
        relative = source.relative_to(served_root)
        target = payload / relative
        copy_regular(source, target)
        size, sha = digest(source)
        records.append({
            "path": relative.as_posix(),
            "size": size,
            "sha256": sha,
            "mode": f"{stat.S_IMODE(source.stat().st_mode):04o}",
        })
    manifest = {
        "schema": "hotdog-sensors-runtime-snapshot-v1",
        "source": "captured sensors root; bytes copied without normalization",
        "files": records,
    }
    (destination / "snapshot.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    print(f"snapshotted {len(records)} runtime files at {destination}")


def restore(snapshot_root: Path, target: Path, replace: bool) -> None:
    manifest_path = snapshot_root / "snapshot.json"
    payload = snapshot_root / "payload"
    if not manifest_path.is_file() or not payload.is_dir():
        fail(f"invalid snapshot: {snapshot_root}")
    manifest = load_manifest(manifest_path)
    if target.exists():
        if not replace:
            fail(f"target exists; pass --replace for intentional rollback: {target}")
        if target.is_symlink() or not target.is_dir():
            fail(f"refusing unsafe rollback target: {target}")
        shutil.rmtree(target)
    target.mkdir(parents=True)
    for entry in manifest["files"]:
        source = payload / entry["path"]
        destination = target / entry["path"]
        if not source.is_file() or source.is_symlink():
            fail(f"snapshot payload is incomplete: {source}")
        copy_regular(source, destination, int(entry["mode"], 8))
        check_entry(destination, entry)
    print(f"restored {len(manifest['files'])} runtime files at {target}")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", default=DEFAULT_MANIFEST, type=Path)
    sub = parser.add_subparsers(dest="command", required=True)

    verify = sub.add_parser("verify", help="verify Git-owned selection and helpers")
    verify.add_argument("--repo-root", default=Path("."), type=Path)
    verify.add_argument("--variant", choices=("45", "47"), default="45")

    external = sub.add_parser("verify-external", help="verify image, SLPI and QRTR captures")
    external.add_argument("--artifact-root", required=True, type=Path)

    stage_parser = sub.add_parser("stage", help="stage config and optional captured registry")
    stage_parser.add_argument("--repo-root", default=Path("."), type=Path)
    stage_parser.add_argument("--variant", choices=("45", "47"), default="45")
    stage_parser.add_argument("--out-root", required=True, type=Path)
    stage_parser.add_argument("--external-root", type=Path)
    stage_parser.add_argument("--replace", action="store_true")

    snap = sub.add_parser("snapshot", help="make a byte-preserving runtime snapshot")
    snap.add_argument("--served-root", required=True, type=Path)
    snap.add_argument("--out", required=True, type=Path)

    rollback = sub.add_parser("restore", help="restore a snapshot into an offline target")
    rollback.add_argument("--snapshot", required=True, type=Path)
    rollback.add_argument("--target", required=True, type=Path)
    rollback.add_argument("--replace", action="store_true")
    return parser


def main() -> int:
    args = build_parser().parse_args()
    manifest_path = args.manifest.resolve()
    manifest = load_manifest(manifest_path)
    repo_root = args.repo_root.resolve() if hasattr(args, "repo_root") else None

    if args.command == "verify":
        verify_selection(repo_root, manifest, args.variant)
        verify_helpers(repo_root, manifest)
    elif args.command == "verify-external":
        verify_external(args.artifact_root.resolve(), manifest)
    elif args.command == "stage":
        stage(repo_root, manifest, args.variant, args.out_root.resolve(),
              args.external_root.resolve() if args.external_root else None,
              args.replace)
    elif args.command == "snapshot":
        snapshot(args.served_root.resolve(), args.out.resolve())
    elif args.command == "restore":
        restore(args.snapshot.resolve(), args.target.resolve(), args.replace)
    else:
        fail(f"unknown command {args.command}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
