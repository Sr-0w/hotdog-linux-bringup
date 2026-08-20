#!/usr/bin/env python3
"""Offline negative and round-trip tests for sensors-slpi-repro.py."""

from __future__ import annotations

import hashlib
import importlib.util
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


def load_tool_module():
    spec = importlib.util.spec_from_file_location("sensors_slpi_repro", SCRIPT)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


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


if __name__ == "__main__":
    unittest.main()
