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
from pathlib import PurePosixPath
import re
import shutil
import stat
import sys
import tempfile
from typing import NoReturn
import uuid


DEFAULT_MANIFEST = "manifests/sensors-slpi-v1.json"
RUNTIME_NAMES = ("sns_reg.conf", "sns_reg_version")
RUNTIME_DIRS = ("config", "registry")
SNAPSHOT_SCHEMA = "hotdog-sensors-runtime-snapshot-v1"
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
CANDIDATE_READY = "READY"
LOCAL_MANIFEST_HEADER = (
    "path",
    "type",
    "mode",
    "size",
    "uid",
    "gid",
    "sha256_or_target",
)


def fail(message: str) -> NoReturn:
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


def path_exists(path: Path) -> bool:
    """Return true for ordinary and dangling symlinks."""
    return os.path.lexists(path)


def canonical(path: Path) -> Path:
    path = path.expanduser()
    for component in (path, *path.parents):
        if path_exists(component) and component.is_symlink():
            fail(f"path contains a symlink component: {component}")
    return path.resolve(strict=False)


def ensure_disjoint(label_a: str, path_a: Path, label_b: str, path_b: Path) -> None:
    a = canonical(path_a)
    b = canonical(path_b)
    if a == b or a in b.parents or b in a.parents:
        fail(f"{label_a} and {label_b} overlap: {a} / {b}")


def relative_path(value: object, label: str) -> Path:
    if not isinstance(value, str) or not value:
        fail(f"{label} must be a non-empty relative POSIX path")
    if "\\" in value or value.startswith("/"):
        fail(f"{label} must not be absolute or contain backslashes: {value!r}")
    parsed = PurePosixPath(value)
    if (parsed.is_absolute() or parsed.as_posix() != value or
            any(part in ("", ".", "..") for part in parsed.parts)):
        fail(f"{label} is not normalized and relative: {value!r}")
    return Path(*parsed.parts)


def mode_text(value: object, label: str) -> str:
    if not isinstance(value, str) or not re.fullmatch(r"[0-7]{3,4}", value):
        fail(f"{label} must be an octal permission mode")
    mode = int(value, 8)
    if mode > 0o7777:
        fail(f"{label} is outside the permission-mode range")
    return f"{mode:03o}"


def decimal_text(value: object, label: str) -> None:
    if not isinstance(value, str) or not re.fullmatch(r"[0-9]+", value):
        fail(f"{label} must be a decimal integer")


def safe_join(root: Path, value: object, label: str) -> Path:
    root = canonical(root)
    if path_exists(root) and root.is_symlink():
        fail(f"{label} root is a symlink: {root}")
    relative = relative_path(value, label)
    current = root
    for part in relative.parts:
        current = current / part
        if path_exists(current) and current.is_symlink():
            fail(f"{label} traverses a symlink: {current}")
    candidate = canonical(current)
    if candidate != root and root not in candidate.parents:
        fail(f"{label} escapes its root: {value!r}")
    return current


def validate_hash_entry(entry: object, label: str, require_path: bool = True) -> dict:
    if not isinstance(entry, dict):
        fail(f"{label} must be an object")
    required = {"size", "sha256"}
    if require_path:
        required.add("path")
    if not required.issubset(entry):
        fail(f"{label} has missing fields: {sorted(required - set(entry))}")
    if not isinstance(entry["size"], int) or isinstance(entry["size"], bool) or entry["size"] < 0:
        fail(f"{label}.size must be a non-negative integer")
    if not isinstance(entry["sha256"], str) or not SHA256_RE.fullmatch(entry["sha256"]):
        fail(f"{label}.sha256 must be a lowercase SHA256")
    if require_path:
        relative_path(entry["path"], f"{label}.path")
    return entry


def validate_baseline_manifest(manifest: dict) -> None:
    if not isinstance(manifest, dict) or manifest.get("schema") != "hotdog-sensors-slpi-repro-v1":
        fail("unsupported baseline manifest schema")
    status = manifest.get("hardware_candidate_status")
    if status not in (CANDIDATE_READY, "BLOCKED_NEEDS_QUALCOMM_PARSER_EVIDENCE"):
        fail(f"invalid hardware_candidate_status: {status!r}")
    config = manifest.get("config_selection")
    if not isinstance(config, dict):
        fail("config_selection must be an object")
    for key in ("baseline_45", "alsps_variant_47_additions"):
        entries = config.get(key)
        if not isinstance(entries, list):
            fail(f"config_selection.{key} must be an array")
        names = set()
        for index, entry in enumerate(entries):
            validate_hash_entry(entry, f"config_selection.{key}[{index}]")
            name = entry["path"]
            if len(relative_path(name, f"config_selection.{key}[{index}].path").parts) != 1 or not name.endswith(".json"):
                fail(f"config selection path must be a single JSON basename: {name!r}")
            if name in names:
                fail(f"duplicate config path: {name}")
            names.add(name)
            relative_path(entry["source"], f"config_selection.{key}[{index}].source")
    if len(config["baseline_45"]) != 45 or len(config["alsps_variant_47_additions"]) != 2:
        fail("baseline manifest has invalid 45/47 selection counts")
    helpers = manifest.get("tracked_helpers")
    if not isinstance(helpers, list):
        fail("tracked_helpers must be an array")
    for index, entry in enumerate(helpers):
        validate_hash_entry(entry, f"tracked_helpers[{index}]")
    for index, entry in enumerate(manifest.get("image_v16", {}).get("artifacts", [])):
        validate_hash_entry(entry, f"image_v16.artifacts[{index}]")
        relative_path(entry["path"], f"image_v16.artifacts[{index}].path")
    for key in ("kernel_config",):
        entry = manifest.get("image_v16", {}).get(key)
        validate_hash_entry(entry, f"image_v16.{key}")
        relative_path(entry["path"], f"image_v16.{key}.path")
    slpi = manifest.get("slpi_00121", {})
    validate_hash_entry(slpi.get("active_mbn"), "slpi_00121.active_mbn")
    relative_path(slpi["active_mbn"]["path"], "slpi_00121.active_mbn.path")
    relative_path(slpi["split_capture_root"], "slpi_00121.split_capture_root")
    for index, entry in enumerate(slpi.get("split_files", [])):
        if not isinstance(entry, dict) or set(entry) != {"name", "size", "sha256"}:
            fail(f"invalid slpi_00121.split_files[{index}]")
        validate_hash_entry({"path": entry["name"], "size": entry["size"], "sha256": entry["sha256"]},
                            f"slpi_00121.split_files[{index}]")
    if len(slpi.get("split_files", [])) != 22:
        fail("SLPI split manifest must contain 22 files")
    for index, entry in enumerate(manifest.get("qrtr_kernel_modules", [])):
        validate_hash_entry(entry, f"qrtr_kernel_modules[{index}]")
    capture = manifest.get("runtime_capture_candidate")
    if not isinstance(capture, dict):
        fail("runtime_capture_candidate must be an object")
    for key in ("archive", "local_manifest"):
        validate_hash_entry(capture.get(key), f"runtime_capture_candidate.{key}")
        relative_path(capture[key]["path"], f"runtime_capture_candidate.{key}.path")
    runtime = capture.get("runtime")
    if not isinstance(runtime, dict):
        fail("runtime_capture_candidate.runtime must be an object")
    for key in ("config_files", "config_bytes", "registry_files", "registry_bytes"):
        if not isinstance(runtime.get(key), int) or runtime[key] < 0:
            fail(f"runtime_capture_candidate.runtime.{key} must be a non-negative integer")
    for key in ("sns_reg_conf", "sns_reg_version"):
        validate_hash_entry(runtime.get(key), f"runtime_capture_candidate.runtime.{key}")
    slpi_capture = capture.get("slpi_00121")
    if not isinstance(slpi_capture, dict) or not isinstance(slpi_capture.get("mbn_sha256"), str) or not SHA256_RE.fullmatch(slpi_capture["mbn_sha256"]):
        fail("runtime_capture_candidate.slpi_00121.mbn_sha256 is invalid")
    mapping = capture.get("mapping")
    if not isinstance(mapping, dict):
        fail("runtime_capture_candidate.mapping must be an object")
    for key in ("variant_45", "variant_47"):
        variant = mapping.get(key)
        if not isinstance(variant, dict) or not isinstance(variant.get("allowed_extras"), list):
            fail(f"runtime_capture_candidate.mapping.{key} is invalid")
        for extra in variant["allowed_extras"]:
            relative_path(f"config/{extra}", f"runtime_capture_candidate.mapping.{key}.allowed_extras")


def candidate_status(manifest: dict, allow_blocked: bool) -> None:
    if manifest["hardware_candidate_status"] != CANDIDATE_READY and not allow_blocked:
        fail("hardware candidate is BLOCKED pending Qualcomm parser evidence; pass --allow-blocked only for opaque offline staging")


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


def runtime_manifest_path(value: object, expected_type: str, label: str) -> str:
    relative = relative_path(value, label)
    parts = relative.parts
    if len(parts) < 2 or parts[0] != "sensors":
        fail(f"{label} must be under sensors/: {value!r}")
    runtime_parts = parts[1:]
    root = runtime_parts[0]
    if root in RUNTIME_NAMES:
        if len(runtime_parts) != 1 or expected_type != "f":
            fail(f"{label} has invalid runtime file path/type: {value!r}")
    elif root in RUNTIME_DIRS:
        if len(runtime_parts) == 1 and expected_type != "d":
            fail(f"{label} has invalid runtime directory type: {value!r}")
        if len(runtime_parts) > 1 and expected_type not in ("f", "d"):
            fail(f"{label} has invalid runtime nested path type: {value!r}")
    else:
        fail(f"{label} is outside the declared sensor runtime: {value!r}")
    return PurePosixPath(*runtime_parts).as_posix()


def parse_local_manifest(path: Path) -> dict[str, dict]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        fail(f"cannot read local runtime manifest {path}: {exc}")
    if not lines:
        fail("local runtime manifest is empty")
    header = tuple(lines[0].split("\t"))
    if header != LOCAL_MANIFEST_HEADER:
        fail(f"local runtime manifest header mismatch: {header!r}")
    records: dict[str, dict] = {}
    for index, line in enumerate(lines[1:], start=2):
        fields = line.split("\t")
        if len(fields) != len(LOCAL_MANIFEST_HEADER):
            fail(f"local runtime manifest line {index} has invalid field count")
        raw_path, kind, raw_mode, raw_size, uid, gid, sha_or_target = fields
        if kind not in ("f", "d"):
            fail(f"local runtime manifest line {index} has unsupported type: {kind!r}")
        relative = runtime_manifest_path(raw_path, kind, f"local manifest line {index}.path")
        if relative in records:
            fail(f"duplicate local runtime manifest path: {relative}")
        mode = mode_text(raw_mode, f"local manifest line {index}.mode")
        decimal_text(uid, f"local manifest line {index}.uid")
        decimal_text(gid, f"local manifest line {index}.gid")
        try:
            size = int(raw_size, 10)
        except ValueError:
            fail(f"local manifest line {index}.size must be a decimal integer")
        if size < 0:
            fail(f"local manifest line {index}.size must be non-negative")
        record = {"path": relative, "type": kind, "mode": mode, "size": size}
        if kind == "f":
            if not SHA256_RE.fullmatch(sha_or_target):
                fail(f"local manifest line {index}.sha256_or_target must be a SHA256")
            record["sha256"] = sha_or_target
        elif sha_or_target:
            fail(f"local manifest line {index}.sha256_or_target must be empty for directories")
        records[relative] = record
    return dict(sorted(records.items()))


def tree_record(path: Path, relative: str, label: str) -> dict:
    if path.is_symlink():
        fail(f"{label} contains a symlink: {path}")
    stat_result = path.stat()
    record = {
        "path": relative,
        "mode": f"{stat.S_IMODE(stat_result.st_mode):03o}",
        "size": stat_result.st_size,
    }
    if path.is_dir():
        record["type"] = "d"
    elif path.is_file():
        record["type"] = "f"
        record["sha256"] = digest(path)[1]
    else:
        fail(f"{label} contains a non-regular entry: {path}")
    return record


def runtime_tree_records(root: Path) -> dict[str, dict]:
    root = canonical(root)
    if not root.is_dir() or root.is_symlink():
        fail(f"runtime root is missing or unsafe: {root}")
    allowed = set(RUNTIME_NAMES) | set(RUNTIME_DIRS)
    records: dict[str, dict] = {}
    for child in root.iterdir():
        if child.name not in allowed:
            fail(f"runtime root has undeclared entry: {child}")
        if child.is_symlink():
            fail(f"runtime root has a symlink: {child}")
    for current, directories, files in os.walk(root, topdown=True, followlinks=False):
        current_path = Path(current)
        for name in sorted(directories):
            path = current_path / name
            relative = path.relative_to(root).as_posix()
            safe_join(root, relative, "runtime tree directory")
            if relative in records:
                fail(f"duplicate runtime tree path: {relative}")
            records[relative] = tree_record(path, relative, "runtime tree")
        for name in sorted(files):
            path = current_path / name
            relative = path.relative_to(root).as_posix()
            safe_join(root, relative, "runtime tree file")
            if relative in records:
                fail(f"duplicate runtime tree path: {relative}")
            records[relative] = tree_record(path, relative, "runtime tree")
    return dict(sorted(records.items()))


def verify_local_manifest_tree(runtime_root: Path, local_manifest: Path) -> dict[str, dict]:
    expected = parse_local_manifest(local_manifest)
    actual = runtime_tree_records(runtime_root)
    if set(actual) != set(expected):
        missing = sorted(set(expected) - set(actual))
        extra = sorted(set(actual) - set(expected))
        fail(f"runtime tree/local manifest mismatch: missing={missing} extra={extra}")
    for relative, expected_entry in expected.items():
        actual_entry = actual[relative]
        for key in ("type", "mode", "size"):
            if actual_entry[key] != expected_entry[key]:
                fail(f"runtime tree {key} mismatch for {relative}")
        if expected_entry["type"] == "f" and actual_entry["sha256"] != expected_entry["sha256"]:
            fail(f"runtime tree SHA256 mismatch for {relative}")
    return expected


def verify_selection(repo_root: Path, manifest: dict, variant: str) -> None:
    for entry in selection(manifest, variant):
        check_entry(repo_root / entry["source"], entry)
    print(f"verified curated sensor config variant {variant}: {variant} files")
    if manifest["hardware_candidate_status"] != CANDIDATE_READY:
        print(f"hardware candidate status: {manifest['hardware_candidate_status']}")


def verify_helpers(repo_root: Path, manifest: dict) -> None:
    for entry in manifest["tracked_helpers"]:
        check_entry(repo_root / entry["path"], entry)
    print(f"verified helper sources: {len(manifest['tracked_helpers'])} files")


def verify_standard_json(repo_root: Path, manifest: dict, variant: str) -> None:
    errors = []
    for entry in selection(manifest, variant):
        path = repo_root / entry["source"]
        try:
            json.loads(path.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
            errors.append(f"{entry['path']}: {exc}")
    if errors:
        fail("standard JSON validation failed; Qualcomm parser evidence is required:\n" + "\n".join(errors))
    print(f"standard JSON validation passed for variant {variant}")


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


def verify_external(artifact_root: Path, manifest: dict, quiet: bool = False) -> None:
    for entry in external_entries(manifest):
        check_entry(artifact_root / entry["path"], entry)
    if not quiet:
        print(f"verified external build and firmware captures: {len(external_entries(manifest))} files")


def gate3(capture_root: Path, manifest: dict, variant: str,
          artifact_root: Path | None) -> None:
    capture = manifest["runtime_capture_candidate"]
    capture_root = canonical(capture_root)
    runtime_root = safe_join(capture_root, "extracted/sensors", "runtime capture root")
    archive = safe_join(capture_root, Path(capture["archive"]["path"]).name, "runtime archive")
    local_manifest = safe_join(capture_root, Path(capture["local_manifest"]["path"]).name, "runtime local manifest")
    check_entry(archive, capture["archive"])
    check_entry(local_manifest, capture["local_manifest"])

    local_records = verify_local_manifest_tree(runtime_root, local_manifest)
    inventory = runtime_inventory(runtime_root)
    config_records = scan_files(safe_join(runtime_root, "config", "runtime config"), "runtime config")
    selected = selection(manifest, variant)
    selected_names = {entry["path"] for entry in selected}
    mapping = capture["mapping"][f"variant_{variant}"]
    allowed_names = set(mapping["allowed_extras"])
    expected_names = selected_names | allowed_names
    if set(config_records) != expected_names:
        fail(f"gate3 config mapping mismatch: got {sorted(config_records)}, expected {sorted(expected_names)}")
    for entry in selected:
        check_entry(safe_join(runtime_root, f"config/{entry['path']}", "runtime selected config"), entry)

    all_configs = {entry["path"]: entry for entry in selection(manifest, "47")}
    extra_summary = []
    extra_metadata = {entry["path"].removeprefix("config/"): entry for entry in capture["extras"]}
    for name in sorted(allowed_names):
        path = safe_join(runtime_root, f"config/{name}", "runtime extra config")
        expected = all_configs.get(name) or extra_metadata.get(name)
        if expected is None:
            fail(f"gate3 has no metadata for allowed extra: {name}")
        check_entry(path, expected)
        extra_summary.append({
            "path": f"config/{name}",
            "sha256": config_records[name]["sha256"],
            "classification": "selected alternative" if name in all_configs else expected["classification"],
        })

    runtime_expected = capture["runtime"]
    if len(config_records) != runtime_expected["config_files"] or sum(e["size"] for e in config_records.values()) != runtime_expected["config_bytes"]:
        fail("gate3 runtime config count/size mismatch")
    registry_records = scan_files(safe_join(runtime_root, "registry", "runtime registry"), "runtime registry")
    if len(registry_records) != runtime_expected["registry_files"] or sum(e["size"] for e in registry_records.values()) != runtime_expected["registry_bytes"]:
        fail("gate3 runtime registry count/size mismatch")
    for key in ("sns_reg_conf", "sns_reg_version"):
        entry = runtime_expected[key]
        check_entry(safe_join(runtime_root, entry["path"], f"runtime {key}"), entry)

    slpi_status = "IDENTITY_MATCH_MANIFEST"
    if artifact_root is not None:
        verify_external(canonical(artifact_root), manifest, quiet=True)
        slpi_status = "37_EXTERNAL_ARTIFACTS_VERIFIED"
    summary = {
        "schema": "hotdog-sensors-gate3-result-v1",
        "capture_id": capture["id"],
        "private_capture": True,
        "variant": variant,
        "archive_sha256": capture["archive"]["sha256"],
        "local_manifest_sha256": capture["local_manifest"]["sha256"],
        "runtime_files": len(inventory),
        "local_manifest_entries": len(local_records),
        "config": {"files": len(config_records), "bytes": sum(e["size"] for e in config_records.values()), "selected_exact": len(selected), "extras": extra_summary},
        "registry": {"files": len(registry_records), "bytes": sum(e["size"] for e in registry_records.values())},
        "sns_reg_conf_sha256": runtime_expected["sns_reg_conf"]["sha256"],
        "sns_reg_version_sha256": runtime_expected["sns_reg_version"]["sha256"],
        "slpi_00121": slpi_status,
        "hardware_ready": False,
        "status": "OFFLINE_GATE_3_PASS_PRIVATE_CAPTURE",
        "blocker": "Qualcomm parser evidence is still required before hardware Working",
    }
    print(json.dumps(summary, indent=2, sort_keys=True))


def file_record(path: Path, relative: str, label: str) -> dict:
    if path.is_symlink() or not path.is_file():
        fail(f"{label} is not a regular file: {path}")
    size, sha = digest(path)
    return {
        "path": relative,
        "size": size,
        "sha256": sha,
        "mode": f"{stat.S_IMODE(path.stat().st_mode):04o}",
    }


def scan_files(root: Path, label: str) -> dict[str, dict]:
    root = canonical(root)
    if not root.is_dir() or root.is_symlink():
        fail(f"{label} is missing or unsafe: {root}")
    records: dict[str, dict] = {}
    for current, directories, files in os.walk(root, topdown=True, followlinks=False):
        current_path = Path(current)
        for name in sorted(directories):
            directory = current_path / name
            if directory.is_symlink():
                fail(f"{label} contains a symlink directory: {directory}")
            if not directory.is_dir():
                fail(f"{label} contains a non-directory: {directory}")
        for name in sorted(files):
            path = current_path / name
            relative = path.relative_to(root).as_posix()
            safe_join(root, relative, f"{label} path")
            if relative in records:
                fail(f"duplicate {label} path: {relative}")
            records[relative] = file_record(path, relative, label)
    return records


def runtime_inventory(root: Path, include_config: bool = True) -> dict[str, dict]:
    root = canonical(root)
    if not root.is_dir() or root.is_symlink():
        fail(f"runtime root is missing or unsafe: {root}")
    allowed = set(RUNTIME_NAMES) | set(RUNTIME_DIRS)
    for child in root.iterdir():
        if child.name not in allowed:
            fail(f"runtime root has undeclared entry: {child}")
        if child.is_symlink():
            fail(f"runtime root has a symlink: {child}")
    records: dict[str, dict] = {}
    for name in RUNTIME_NAMES:
        path = safe_join(root, name, "runtime path")
        records[name] = file_record(path, name, "runtime")
    for directory in RUNTIME_DIRS:
        if directory == "config" and not include_config:
            continue
        path = safe_join(root, directory, "runtime directory")
        nested = scan_files(path, f"runtime {directory}")
        for relative, record in nested.items():
            full = f"{directory}/{relative}"
            record = dict(record)
            record["path"] = full
            records[full] = record
    return dict(sorted(records.items()))


def copy_regular(source: Path, destination: Path, mode: int | None = None) -> None:
    if source.is_symlink() or not source.is_file():
        fail(f"source is not a regular file: {source}")
    if path_exists(destination) and destination.is_symlink():
        fail(f"destination is a symlink: {destination}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, destination)
    os.chmod(destination, mode if mode is not None else stat.S_IMODE(source.stat().st_mode))


def copy_stable(source: Path, destination: Path, expected: dict, label: str) -> None:
    before = file_record(source, expected["path"], label)
    copy_regular(source, destination, int(before["mode"], 8))
    check_entry(destination, expected)
    after = file_record(source, expected["path"], label)
    if before != after:
        fail(f"source changed while copying {label}: {source}")


def expected_runtime_records(manifest: dict, variant: str,
                             external: dict[str, dict] | None = None) -> dict[str, dict]:
    records: dict[str, dict] = {}
    for entry in selection(manifest, variant):
        records[f"config/{entry['path']}"] = {
            "path": f"config/{entry['path']}",
            "size": entry["size"],
            "sha256": entry["sha256"],
            "mode": "0644",
        }
    if external:
        records.update(external)
    return dict(sorted(records.items()))


def verify_runtime_records(root: Path, expected: dict[str, dict]) -> None:
    actual = runtime_inventory(root)
    if set(actual) != set(expected):
        fail(f"runtime file set mismatch: got {sorted(actual)}, expected {sorted(expected)}")
    for relative, entry in expected.items():
        path = safe_join(root, relative, "runtime verification path")
        check_entry(path, entry)
        if actual[relative]["mode"] != entry["mode"]:
            fail(f"runtime mode mismatch for {relative}")


def verify_config_records(root: Path, manifest: dict, variant: str) -> None:
    config = safe_join(root, "config", "config verification")
    actual = scan_files(config, "staged config")
    expected = {entry["path"] for entry in selection(manifest, variant)}
    if set(actual) != expected:
        fail("staged config set mismatch")
    for entry in selection(manifest, variant):
        check_entry(safe_join(config, entry["path"], "staged config path"), entry)
        if actual[entry["path"]]["mode"] != "0644":
            fail(f"staged config mode is not 0644: {entry['path']}")


def external_config_records(external_root: Path, manifest: dict, variant: str) -> None:
    config = safe_join(external_root, "config", "external config")
    actual = scan_files(config, "external config")
    expected = {entry["path"] for entry in selection(manifest, variant)}
    if set(actual) != expected:
        fail("external-root/config must contain exactly the declared selection; extras or omissions are forbidden")
    for entry in selection(manifest, variant):
        path = safe_join(config, entry["path"], "external config path")
        check_entry(path, entry)


def stage_forbidden_external_paths(manifest: dict) -> set[str]:
    forbidden: set[str] = set()
    capture = manifest.get("runtime_capture_candidate", {})
    extras = capture.get("extras", []) if isinstance(capture, dict) else []
    for entry in extras:
        if not isinstance(entry, dict):
            continue
        path = entry.get("path")
        policy = entry.get("integration_policy", "")
        if not isinstance(path, str) or not isinstance(policy, str):
            continue
        if path.startswith("registry/") and "private snapshot" in policy:
            forbidden.add(path)
    return forbidden


def external_registry_records(external_root: Path, manifest: dict) -> dict[str, dict]:
    records: dict[str, dict] = {}
    forbidden = stage_forbidden_external_paths(manifest)
    for name in RUNTIME_NAMES:
        path = safe_join(external_root, name, "external runtime path")
        records[name] = file_record(path, name, "external runtime")
    registry = safe_join(external_root, "registry", "external registry")
    for relative, record in scan_files(registry, "external registry").items():
        full = f"registry/{relative}"
        if full in forbidden:
            fail(f"external-root contains private snapshot-only registry file: {full}")
        record = dict(record)
        record["path"] = full
        records[full] = record
    return dict(sorted(records.items()))


def atomic_install(staging: Path, target: Path, replace: bool,
                   post_check) -> None:
    target = canonical(target)
    if path_exists(target):
        if not replace:
            fail(f"target exists; pass --replace for intentional replacement: {target}")
        if target.is_symlink() or not target.is_dir():
            fail(f"refusing unsafe target: {target}")
    target.parent.mkdir(parents=True, exist_ok=True)
    backup = None
    if path_exists(target):
        backup = target.parent / f".{target.name}.backup-{os.getpid()}-{uuid.uuid4().hex}"
        os.replace(target, backup)
    try:
        os.replace(staging, target)
    except BaseException:
        if backup is not None and not path_exists(target):
            os.replace(backup, target)
        raise
    try:
        post_check(target)
    except BaseException:
        failed = target.parent / f".{target.name}.failed-{os.getpid()}-{uuid.uuid4().hex}"
        os.replace(target, failed)
        if backup is not None:
            os.replace(backup, target)
        raise
    if backup is not None:
        shutil.rmtree(backup)


def stage(repo_root: Path, manifest: dict, variant: str, out_root: Path,
          external_root: Path | None, replace: bool, allow_blocked: bool) -> None:
    candidate_status(manifest, allow_blocked)
    verify_selection(repo_root, manifest, variant)
    out_root = canonical(out_root)
    target = out_root / "sensors"
    ensure_disjoint("stage target", target, "repository", repo_root)
    if external_root is not None:
        ensure_disjoint("stage target", target, "external root", external_root)
        external_root = canonical(external_root)
        external_config_records(external_root, manifest, variant)
        external_before = external_registry_records(external_root, manifest)
    else:
        external_before = None
    if path_exists(target) and not replace:
        fail(f"destination exists; pass --replace only for an intentional replacement: {target}")
    out_root.mkdir(parents=True, exist_ok=True)
    if out_root.is_symlink() or not out_root.is_dir():
        fail(f"refusing unsafe output root: {out_root}")
    container = Path(tempfile.mkdtemp(prefix=".sensors-stage-", dir=str(out_root)))
    staging = container / "sensors"
    try:
        config = staging / "config"
        config.mkdir(parents=True)
        for entry in selection(manifest, variant):
            source = safe_join(repo_root, entry["source"], "manifest source")
            destination = safe_join(config, entry["path"], "staged config")
            copy_stable(source, destination, entry, "Git config")
        if external_before is not None and external_root is not None:
            for relative, entry in external_before.items():
                source = safe_join(external_root, relative, "external runtime source")
                destination = safe_join(staging, relative, "staged runtime")
                copy_stable(source, destination, entry, "external runtime")
            external_after = external_registry_records(external_root, manifest)
            if external_before != external_after:
                fail("external runtime source changed during stage")
        expected = expected_runtime_records(manifest, variant, external_before)
        if external_before is None:
            verify_config_records(staging, manifest, variant)
            post_check = lambda installed: verify_config_records(installed, manifest, variant)
        else:
            verify_runtime_records(staging, expected)
            post_check = lambda installed: verify_runtime_records(installed, expected)
        atomic_install(staging, target, replace, post_check)
        print(f"staged sensor runtime variant {variant} at {target}")
        if external_before is None:
            print("registry inputs not staged: pass --external-root with a captured sensors root")
    finally:
        if path_exists(container):
            shutil.rmtree(container)


def validate_snapshot_manifest(snapshot_root: Path) -> tuple[dict, dict[str, dict]]:
    snapshot_root = canonical(snapshot_root)
    if snapshot_root.is_symlink() or not snapshot_root.is_dir():
        fail(f"snapshot root is missing or unsafe: {snapshot_root}")
    manifest_path = safe_join(snapshot_root, "snapshot.json", "snapshot manifest")
    payload = safe_join(snapshot_root, "payload", "snapshot payload")
    if not manifest_path.is_file() or manifest_path.is_symlink() or not payload.is_dir():
        fail(f"invalid snapshot layout: {snapshot_root}")
    manifest = load_manifest(manifest_path)
    required = {"schema", "source", "source_quiesced", "metadata_contract", "files"}
    if set(manifest) != required or manifest["schema"] != SNAPSHOT_SCHEMA:
        fail("snapshot schema or fields are invalid")
    if not isinstance(manifest["source"], str) or not manifest["source"]:
        fail("snapshot source description is missing")
    if manifest["source_quiesced"] is not True:
        fail("snapshot must assert a quiesced source")
    if not isinstance(manifest["metadata_contract"], str) or not manifest["metadata_contract"]:
        fail("snapshot metadata_contract is missing")
    if not isinstance(manifest["files"], list):
        fail("snapshot files must be an array")
    records: dict[str, dict] = {}
    for index, entry in enumerate(manifest["files"]):
        if not isinstance(entry, dict) or set(entry) != {"path", "size", "sha256", "mode"}:
            fail(f"snapshot files[{index}] has invalid fields")
        relative = relative_path(entry["path"], f"snapshot files[{index}].path")
        parts = relative.parts
        if parts[0] not in RUNTIME_NAMES and parts[0] not in RUNTIME_DIRS:
            fail(f"snapshot path is outside the sensor runtime: {entry['path']}")
        if parts[0] in RUNTIME_NAMES and len(parts) != 1:
            fail(f"snapshot runtime name has descendants: {entry['path']}")
        if parts[0] in RUNTIME_DIRS and len(parts) < 2:
            fail(f"snapshot runtime directory is not a file path: {entry['path']}")
        if entry["path"] in records:
            fail(f"duplicate snapshot path: {entry['path']}")
        validate_hash_entry(entry, f"snapshot files[{index}]")
        if not isinstance(entry["mode"], str) or not re.fullmatch(r"[0-7]{4}", entry["mode"]):
            fail(f"snapshot files[{index}].mode must be four octal digits")
        records[entry["path"]] = dict(entry)
    actual = scan_files(payload, "snapshot payload")
    if set(actual) != set(records):
        fail(f"snapshot payload file set mismatch: got {sorted(actual)}, expected {sorted(records)}")
    for relative, entry in records.items():
        source = safe_join(payload, relative, "snapshot payload path")
        check_entry(source, entry)
        if actual[relative]["mode"] != entry["mode"]:
            fail(f"snapshot payload mode mismatch: {relative}")
    return manifest, records


def snapshot(served_root: Path, destination: Path, quiesced: bool) -> None:
    if not quiesced:
        fail("snapshot requires --quiesced: source must be offline and immutable during capture")
    served_root = canonical(served_root)
    destination = canonical(destination)
    ensure_disjoint("served root", served_root, "snapshot destination", destination)
    if path_exists(destination):
        fail(f"snapshot destination already exists: {destination}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    container = Path(tempfile.mkdtemp(prefix=".sensors-snapshot-", dir=str(destination.parent)))
    try:
        pre = runtime_inventory(served_root)
        payload = container / "payload"
        payload.mkdir(parents=True)
        for relative, entry in pre.items():
            source = safe_join(served_root, relative, "snapshot source")
            target = safe_join(payload, relative, "snapshot payload")
            copy_stable(source, target, entry, "snapshot source")
        post = runtime_inventory(served_root)
        if pre != post:
            fail("source changed during snapshot; quiesce it and retry")
        manifest = {
            "schema": SNAPSHOT_SCHEMA,
            "source": "captured sensors root; bytes copied without normalization",
            "source_quiesced": True,
            "metadata_contract": "regular-file content, size, SHA256 and permission mode only; owner/group/ACL/xattrs/timestamps/hardlinks and directory metadata are not preserved",
            "files": list(pre.values()),
        }
        (container / "snapshot.json").write_text(
            json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        validate_snapshot_manifest(container)
        os.replace(container, destination)
        print(f"snapshotted {len(pre)} runtime files at {destination}")
    except BaseException:
        if path_exists(container):
            shutil.rmtree(container)
        raise


def restore(snapshot_root: Path, target: Path, replace: bool) -> None:
    snapshot_root = canonical(snapshot_root)
    target = canonical(target)
    ensure_disjoint("snapshot", snapshot_root, "restore target", target)
    _, records = validate_snapshot_manifest(snapshot_root)
    if path_exists(target) and not target.is_dir():
        fail(f"refusing unsafe rollback target: {target}")
    if path_exists(target) and target.is_symlink():
        fail(f"refusing symlink rollback target: {target}")
    if path_exists(target) and not replace:
        fail(f"target exists; pass --replace for intentional rollback: {target}")
    target.parent.mkdir(parents=True, exist_ok=True)
    container = Path(tempfile.mkdtemp(prefix=".sensors-restore-", dir=str(target.parent)))
    try:
        payload = safe_join(snapshot_root, "payload", "snapshot payload")
        for relative, entry in records.items():
            source = safe_join(payload, relative, "snapshot payload path")
            destination = safe_join(container, relative, "restore staging path")
            copy_regular(source, destination, int(entry["mode"], 8))
            check_entry(destination, entry)
        expected = dict(records)
        verify_runtime_records(container, expected)
        atomic_install(container, target, replace,
                       lambda installed: verify_runtime_records(installed, expected))
        print(f"restored {len(records)} runtime files at {target}")
    finally:
        if path_exists(container):
            shutil.rmtree(container)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", default=DEFAULT_MANIFEST, type=Path)
    sub = parser.add_subparsers(dest="command", required=True)

    verify = sub.add_parser("verify", help="verify Git-owned selection and helpers")
    verify.add_argument("--repo-root", default=Path("."), type=Path)
    verify.add_argument("--variant", choices=("45", "47"), default="45")
    verify.add_argument("--strict-json", action="store_true",
                        help="also require Python standard-JSON parsing of every selected file")

    external = sub.add_parser("verify-external", help="verify image, SLPI and QRTR captures")
    external.add_argument("--artifact-root", required=True, type=Path)

    gate = sub.add_parser("gate3", help="validate the private runtime capture without staging it")
    gate.add_argument("--capture-root", required=True, type=Path)
    gate.add_argument("--variant", choices=("45", "47"), default="47")
    gate.add_argument("--artifact-root", type=Path,
                      help="optional artifact root for the full 37-file SLPI/image verification")

    stage_parser = sub.add_parser("stage", help="stage config and optional captured registry")
    stage_parser.add_argument("--repo-root", default=Path("."), type=Path)
    stage_parser.add_argument("--variant", choices=("45", "47"), default="45")
    stage_parser.add_argument("--out-root", required=True, type=Path)
    stage_parser.add_argument("--external-root", type=Path)
    stage_parser.add_argument("--replace", action="store_true")
    stage_parser.add_argument("--allow-blocked", action="store_true",
                              help="stage an explicitly blocked opaque candidate for offline parser testing")

    snap = sub.add_parser("snapshot", help="make a byte-preserving runtime snapshot")
    snap.add_argument("--served-root", required=True, type=Path)
    snap.add_argument("--out", required=True, type=Path)
    snap.add_argument("--quiesced", action="store_true",
                      help="assert that the source is offline and immutable during capture")

    rollback = sub.add_parser("restore", help="restore a snapshot into an offline target")
    rollback.add_argument("--snapshot", required=True, type=Path)
    rollback.add_argument("--target", required=True, type=Path)
    rollback.add_argument("--replace", action="store_true")
    return parser


def main() -> int:
    args = build_parser().parse_args()
    manifest_path = canonical(args.manifest)
    manifest = load_manifest(manifest_path)
    validate_baseline_manifest(manifest)
    repo_root = canonical(args.repo_root) if hasattr(args, "repo_root") else None

    if args.command == "verify":
        verify_selection(repo_root, manifest, args.variant)
        verify_helpers(repo_root, manifest)
        if args.strict_json:
            verify_standard_json(repo_root, manifest, args.variant)
    elif args.command == "verify-external":
        verify_external(canonical(args.artifact_root), manifest)
    elif args.command == "gate3":
        gate3(canonical(args.capture_root), manifest, args.variant,
              canonical(args.artifact_root) if args.artifact_root else None)
    elif args.command == "stage":
        stage(repo_root, manifest, args.variant, canonical(args.out_root),
              canonical(args.external_root) if args.external_root else None,
              args.replace, args.allow_blocked)
    elif args.command == "snapshot":
        snapshot(canonical(args.served_root), canonical(args.out), args.quiesced)
    elif args.command == "restore":
        restore(canonical(args.snapshot), canonical(args.target), args.replace)
    else:
        fail(f"unknown command {args.command}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
