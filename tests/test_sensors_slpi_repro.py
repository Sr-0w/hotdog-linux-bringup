#!/usr/bin/env python3
"""Offline negative and round-trip tests for sensors-slpi-repro.py."""

from __future__ import annotations

import hashlib
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/sensors-slpi-repro.py"
MANIFEST = ROOT / "manifests/sensors-slpi-v1.json"


def run_tool(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, "-B", str(SCRIPT), "--manifest", str(MANIFEST), *args],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )


def write_snapshot(root: Path, entries: list[dict]) -> None:
    (root / "payload").mkdir(parents=True)
    (root / "snapshot.json").write_text(
        json.dumps({
            "schema": "hotdog-sensors-runtime-snapshot-v1",
            "source": "test fixture",
            "source_quiesced": True,
            "metadata_contract": "regular-file content, size, SHA256 and permission mode only",
            "files": entries,
        }),
        encoding="utf-8",
    )


def record(path: str, data: bytes) -> dict:
    sha = hashlib.sha256(data).hexdigest()
    return {"path": path, "size": len(data), "sha256": sha, "mode": "0644"}


def update_hash_entry(entry: dict, path: Path) -> None:
    data = path.read_bytes()
    entry["size"] = len(data)
    entry["sha256"] = hashlib.sha256(data).hexdigest()


def write_local_manifest(capture_root: Path, sensors_root: Path) -> Path:
    rows = ["path\ttype\tmode\tsize\tuid\tgid\tsha256_or_target"]
    records: list[tuple[str, str]] = []
    for current, directories, files in os.walk(sensors_root, topdown=True, followlinks=False):
        current_path = Path(current)
        for name in sorted(directories):
            path = current_path / name
            records.append((path.relative_to(sensors_root).as_posix(), "d"))
        for name in sorted(files):
            path = current_path / name
            records.append((path.relative_to(sensors_root).as_posix(), "f"))
    for relative, kind in sorted(records):
        path = sensors_root / relative
        st = path.stat()
        mode = f"{st.st_mode & 0o7777:03o}"
        size = st.st_size
        sha = hashlib.sha256(path.read_bytes()).hexdigest() if kind == "f" else ""
        rows.append(f"sensors/{relative}\t{kind}\t{mode}\t{size}\t1000\t1000\t{sha}")
    local_manifest = capture_root / "sensors-active.local-manifest.tsv"
    local_manifest.write_text("\n".join(rows) + "\n", encoding="utf-8")
    return local_manifest


def load_tool_module():
    spec = importlib.util.spec_from_file_location("sensors_slpi_repro", SCRIPT)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def make_gate3_fixture(root: Path) -> tuple[object, dict, Path]:
    module = load_tool_module()
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    capture_root = root / "capture"
    sensors_root = capture_root / "extracted/sensors"
    (sensors_root / "config").mkdir(parents=True)
    (sensors_root / "registry").mkdir()

    selected = list(manifest["config_selection"]["baseline_45"])
    selected.extend(manifest["config_selection"]["alsps_variant_47_additions"])
    for entry in selected:
        shutil.copyfile(ROOT / entry["source"], sensors_root / "config" / entry["path"])
    power = sensors_root / "config/msmnile_power_0.json"
    shutil.copyfile(power, sensors_root / "config/msmnile_power_0.json.pre-island-off-20260820")

    (sensors_root / "registry/stable").write_bytes(b"AA")
    (sensors_root / "registry/power.island.pre-island-off-20260820").write_bytes(b"private-registry-backup")
    (sensors_root / "sns_reg.conf").write_bytes(b"conf\n")
    (sensors_root / "sns_reg_version").write_bytes(b"00121\n")
    archive = capture_root / "sensors-active.tar"
    archive.write_bytes(b"private test archive\n")
    local_manifest = write_local_manifest(capture_root, sensors_root)

    capture = manifest["runtime_capture_candidate"]
    update_hash_entry(capture["archive"], archive)
    update_hash_entry(capture["local_manifest"], local_manifest)
    update_hash_entry(capture["runtime"]["sns_reg_conf"], sensors_root / "sns_reg.conf")
    update_hash_entry(capture["runtime"]["sns_reg_version"], sensors_root / "sns_reg_version")
    config_files = list((sensors_root / "config").iterdir())
    registry_files = list((sensors_root / "registry").iterdir())
    capture["runtime"]["config_files"] = len(config_files)
    capture["runtime"]["config_bytes"] = sum(path.stat().st_size for path in config_files)
    capture["runtime"]["registry_files"] = len(registry_files)
    capture["runtime"]["registry_bytes"] = sum(path.stat().st_size for path in registry_files)
    return module, manifest, capture_root


def run_gate3(module: object, manifest: dict, capture_root: Path) -> str:
    output = io.StringIO()
    with contextlib.redirect_stdout(output):
        module.gate3(capture_root, manifest, "47", None)
    return output.getvalue()


def refresh_fixture_local_manifest(manifest: dict, capture_root: Path) -> None:
    local_manifest = capture_root / "sensors-active.local-manifest.tsv"
    update_hash_entry(manifest["runtime_capture_candidate"]["local_manifest"], local_manifest)


class SensorsReproSafetyTests(unittest.TestCase):
    def test_blocked_candidate_requires_explicit_override(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "blocked"
            refused = run_tool("stage", "--repo-root", str(ROOT), "--variant", "45",
                               "--out-root", str(output))
            self.assertNotEqual(refused.returncode, 0)
            self.assertFalse((output / "sensors").exists())

            staged = run_tool("stage", "--repo-root", str(ROOT), "--variant", "45",
                              "--allow-blocked", "--out-root", str(output))
            self.assertEqual(staged.returncode, 0, staged.stderr)
            self.assertEqual(len(list((output / "sensors/config").glob("*.json"))), 45)

            strict = run_tool("verify", "--repo-root", str(ROOT), "--variant", "45",
                              "--strict-json")
            self.assertNotEqual(strict.returncode, 0)
            self.assertIn("sns_cm.json", strict.stderr)
            self.assertIn("msmnile_mmc5603nj.json", strict.stderr)

    def test_snapshot_requires_quiesced_source(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            result = run_tool("snapshot", "--served-root", directory,
                              "--out", str(Path(directory).parent / "snapshot"))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("--quiesced", result.stderr)

    def test_restore_rejects_traversal_before_writing(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for bad_path in ("../escape", "/absolute"):
                snapshot = root / bad_path.replace("/", "_")
                write_snapshot(snapshot, [record(bad_path, b"bad")])
                target = root / f"target-{bad_path.replace('/', '_')}"
                result = run_tool("restore", "--snapshot", str(snapshot),
                                  "--target", str(target))
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(target.exists())
            self.assertFalse((root / "escape").exists())

    def test_restore_prevalidates_before_replace(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            snapshot = root / "snapshot"
            write_snapshot(snapshot, [record("config/missing", b"missing")])
            target = root / "target"
            target.mkdir()
            (target / "keep").write_bytes(b"original")
            result = run_tool("restore", "--snapshot", str(snapshot),
                              "--target", str(target), "--replace")
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual((target / "keep").read_bytes(), b"original")

    def test_restore_rejects_snapshot_target_overlap(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            snapshot = root / "snapshot"
            write_snapshot(snapshot, [])
            target = snapshot / "target"
            result = run_tool("restore", "--snapshot", str(snapshot),
                              "--target", str(target))
            self.assertNotEqual(result.returncode, 0)

    def test_stage_rejects_repository_overlap(self) -> None:
        result = run_tool("stage", "--repo-root", str(ROOT), "--variant", "45",
                          "--allow-blocked", "--out-root", str(ROOT))
        self.assertNotEqual(result.returncode, 0)

    def test_external_config_symlink_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            external = root / "external"
            (external / "config").mkdir(parents=True)
            (external / "registry").mkdir()
            (external / "sns_reg.conf").write_bytes(b"conf")
            (external / "sns_reg_version").write_bytes(b"version")
            os.symlink(ROOT / "firmware/sensors/config/default_sensors.json",
                       external / "config/default_sensors.json")
            result = run_tool("stage", "--repo-root", str(ROOT), "--variant", "45",
                              "--allow-blocked", "--external-root", str(external),
                              "--out-root", str(root / "symlink"))
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((root / "symlink/sensors").exists())

    def test_snapshot_detects_source_generation_change(self) -> None:
        module = load_tool_module()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            served = root / "served"
            (served / "config").mkdir(parents=True)
            (served / "registry").mkdir()
            (served / "sns_reg.conf").write_bytes(b"conf")
            (served / "sns_reg_version").write_bytes(b"version")
            (served / "config/a").write_bytes(b"a")
            pre = module.runtime_inventory(served)
            post = {path: dict(entry) for path, entry in pre.items()}
            post["sns_reg.conf"]["sha256"] = "0" * 64
            with patch.object(module, "runtime_inventory", side_effect=[pre, post]):
                with self.assertRaises(SystemExit):
                    module.snapshot(served, root / "snapshot", True)
            self.assertFalse((root / "snapshot").exists())

    def test_external_config_collision_and_extra_are_rejected(self) -> None:
        manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
        entries = manifest["config_selection"]["baseline_45"]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            external = root / "external"
            (external / "config").mkdir(parents=True)
            (external / "registry").mkdir()
            (external / "sns_reg.conf").write_bytes(b"conf")
            (external / "sns_reg_version").write_bytes(b"version")
            for entry in entries:
                source = ROOT / entry["source"]
                destination = external / "config" / entry["path"]
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source, destination)

            collision = external / "config/default_sensors.json"
            collision.write_bytes(collision.read_bytes() + b"x")
            result = run_tool("stage", "--repo-root", str(ROOT), "--variant", "45",
                              "--allow-blocked", "--external-root", str(external),
                              "--out-root", str(root / "collision"))
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((root / "collision/sensors").exists())

            shutil.copyfile(ROOT / entries[0]["source"], collision)
            (external / "config/extra.json").write_bytes(b"extra")
            result = run_tool("stage", "--repo-root", str(ROOT), "--variant", "45",
                              "--allow-blocked", "--external-root", str(external),
                              "--out-root", str(root / "extra"))
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((root / "extra/sensors").exists())

            (external / "config/extra.json").unlink()
            (external / "registry/r").parent.mkdir(parents=True, exist_ok=True)
            (external / "registry/r").write_bytes(b"registry")
            result = run_tool("stage", "--repo-root", str(ROOT), "--variant", "45",
                              "--allow-blocked", "--external-root", str(external),
                              "--out-root", str(root / "valid"))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(len(list((root / "valid/sensors/config").glob("*.json"))), 45)
            self.assertEqual((root / "valid/sensors/registry/r").read_bytes(), b"registry")

    def test_stage_rejects_private_registry_backup_promotion(self) -> None:
        manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
        entries = manifest["config_selection"]["baseline_45"]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            external = root / "external"
            (external / "config").mkdir(parents=True)
            (external / "registry").mkdir()
            (external / "sns_reg.conf").write_bytes(b"conf")
            (external / "sns_reg_version").write_bytes(b"version")
            for entry in entries:
                shutil.copyfile(ROOT / entry["source"], external / "config" / entry["path"])
            (external / "registry/power.island.pre-island-off-20260820").write_bytes(b"private")
            result = run_tool("stage", "--repo-root", str(ROOT), "--variant", "45",
                              "--allow-blocked", "--external-root", str(external),
                              "--out-root", str(root / "promote"))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("private snapshot-only registry", result.stderr)
            self.assertFalse((root / "promote/sensors").exists())

    def test_stage_variant_47_accepts_clean_external_registry(self) -> None:
        manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
        entries = list(manifest["config_selection"]["baseline_45"])
        entries.extend(manifest["config_selection"]["alsps_variant_47_additions"])
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            external = root / "external"
            (external / "config").mkdir(parents=True)
            (external / "registry").mkdir()
            (external / "sns_reg.conf").write_bytes(b"conf")
            (external / "sns_reg_version").write_bytes(b"version")
            for entry in entries:
                shutil.copyfile(ROOT / entry["source"], external / "config" / entry["path"])
            (external / "registry/r").write_bytes(b"registry")
            result = run_tool("stage", "--repo-root", str(ROOT), "--variant", "47",
                              "--allow-blocked", "--external-root", str(external),
                              "--out-root", str(root / "clean"))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(len(list((root / "clean/sensors/config").glob("*.json"))), 47)
            self.assertEqual((root / "clean/sensors/registry/r").read_bytes(), b"registry")

    def test_gate3_accepts_complete_private_fixture(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            module, manifest, capture = make_gate3_fixture(Path(directory))
            summary = json.loads(run_gate3(module, manifest, capture))
            self.assertEqual(summary["status"], "OFFLINE_GATE_3_PASS_PRIVATE_CAPTURE")
            self.assertEqual(summary["config"]["files"], 48)
            self.assertEqual(summary["registry"]["files"], 2)
            self.assertEqual(summary["local_manifest_entries"], 54)
            self.assertFalse(summary["hardware_ready"])

    def test_gate3_rejects_registry_same_size_mutation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            module, manifest, capture = make_gate3_fixture(Path(directory))
            registry = capture / "extracted/sensors/registry/stable"
            self.assertEqual(registry.stat().st_size, 2)
            registry.write_bytes(b"BB")
            with self.assertRaises(SystemExit):
                run_gate3(module, manifest, capture)

    def test_gate3_rejects_mode_type_and_path_mismatches(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            module, manifest, capture = make_gate3_fixture(Path(directory) / "mode")
            os.chmod(capture / "extracted/sensors/registry/stable", 0o600)
            with self.assertRaises(SystemExit):
                run_gate3(module, manifest, capture)

        with tempfile.TemporaryDirectory() as directory:
            module, manifest, capture = make_gate3_fixture(Path(directory) / "type")
            path = capture / "extracted/sensors/registry/stable"
            path.unlink()
            path.mkdir()
            with self.assertRaises(SystemExit):
                run_gate3(module, manifest, capture)

        with tempfile.TemporaryDirectory() as directory:
            module, manifest, capture = make_gate3_fixture(Path(directory) / "path")
            local_manifest = capture / "sensors-active.local-manifest.tsv"
            text = local_manifest.read_text(encoding="utf-8")
            text = text.replace("sensors/registry/stable\t", "sensors/registry/../escape\t", 1)
            local_manifest.write_text(text, encoding="utf-8")
            refresh_fixture_local_manifest(manifest, capture)
            with self.assertRaises(SystemExit):
                run_gate3(module, manifest, capture)

    def test_gate3_rejects_extra_missing_symlink_and_traversal(self) -> None:
        cases = ("extra", "missing", "symlink", "traversal")
        for case in cases:
            with self.subTest(case=case):
                with tempfile.TemporaryDirectory() as directory:
                    module, manifest, capture = make_gate3_fixture(Path(directory))
                    sensors = capture / "extracted/sensors"
                    if case == "extra":
                        (sensors / "registry/extra").write_bytes(b"extra")
                    elif case == "missing":
                        (sensors / "registry/stable").unlink()
                    elif case == "symlink":
                        os.symlink(sensors / "registry/stable", sensors / "registry/link")
                    else:
                        local_manifest = capture / "sensors-active.local-manifest.tsv"
                        text = local_manifest.read_text(encoding="utf-8")
                        text = text.replace("sensors/registry/stable\t", "../escape\t", 1)
                        local_manifest.write_text(text, encoding="utf-8")
                        refresh_fixture_local_manifest(manifest, capture)
                    with self.assertRaises(SystemExit):
                        run_gate3(module, manifest, capture)

    def test_versioned_tree_has_no_private_workstation_path(self) -> None:
        needle = "/home/" + "srobin"
        result = subprocess.run(
            ["git", "grep", "-n", needle, "--", "."],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_snapshot_round_trip_preserves_declared_contract(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            served = root / "served"
            (served / "config").mkdir(parents=True)
            (served / "registry/sub").mkdir(parents=True)
            (served / "sns_reg.conf").write_bytes(b"conf\0")
            (served / "sns_reg_version").write_bytes(b"00121\n")
            (served / "config/a").write_bytes(b"json\r\n")
            (served / "registry/sub/r").write_bytes(b"registry")
            snapshot = root / "snapshot"
            result = run_tool("snapshot", "--served-root", str(served),
                              "--out", str(snapshot), "--quiesced")
            self.assertEqual(result.returncode, 0, result.stderr)
            restored = root / "restored"
            result = run_tool("restore", "--snapshot", str(snapshot),
                              "--target", str(restored))
            self.assertEqual(result.returncode, 0, result.stderr)
            for relative in ("sns_reg.conf", "sns_reg_version", "config/a", "registry/sub/r"):
                self.assertEqual((served / relative).read_bytes(), (restored / relative).read_bytes())
            (restored / "stale").write_bytes(b"stale")
            result = run_tool("restore", "--snapshot", str(snapshot),
                              "--target", str(restored), "--replace")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse((restored / "stale").exists())
            self.assertFalse(any(restored.parent.glob(f".{restored.name}.backup-*")))

    def test_private_runtime_capture_gate3_if_available(self) -> None:
        capture_value = os.environ.get("HOTDOG_SENSOR_CAPTURE_ROOT")
        if not capture_value:
            self.skipTest("set HOTDOG_SENSOR_CAPTURE_ROOT to validate the private Hardware Lab capture")
        capture = Path(capture_value)
        if not capture.is_dir():
            self.skipTest("Hardware Lab private capture is not present")
        result = run_tool("gate3", "--capture-root", str(capture), "--variant", "47")
        self.assertEqual(result.returncode, 0, result.stderr)
        summary = json.loads(result.stdout)
        self.assertEqual(summary["status"], "OFFLINE_GATE_3_PASS_PRIVATE_CAPTURE")
        self.assertFalse(summary["hardware_ready"])
        self.assertEqual(summary["config"]["files"], 48)
        self.assertEqual(summary["registry"]["files"], 133)
        self.assertEqual(summary["config"]["selected_exact"], 47)


if __name__ == "__main__":
    unittest.main()
