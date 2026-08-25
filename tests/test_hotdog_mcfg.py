from __future__ import annotations

import hashlib
import struct
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]
SOURCE = ROOT / "helpers" / "hotdog-radio"


def tlv(kind: int, value: bytes) -> bytes:
    return bytes([kind]) + struct.pack("<H", len(value)) + value


def profile(path: Path, carrier: str, iin: int, version: int) -> bytes:
    metadata = (
        struct.pack("<II", 10, 0xA1)
        + b"MCFG_TRL"
        + tlv(0x03, carrier.encode())
        + tlv(0x04, bytes([0, 1]) + struct.pack("<I", iin))
        + tlv(0x05, struct.pack("<I", version))
        + tlv(0x01, struct.pack("<I", version))
    )
    payload = (
        b"PUBLIC_CONFIG_" + carrier.encode()
        + struct.pack("<I", len(metadata) + 4)
        + metadata
        + struct.pack("<I", len(metadata) + 8)
    )
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(payload)
    return payload


class HotdogMcfgTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        flags = subprocess.run(
            ["pkg-config", "--cflags", "--libs", "glib-2.0"],
            check=True, capture_output=True, text=True,
        ).stdout.split()
        cls._temporary = tempfile.TemporaryDirectory()
        cls.binary = Path(cls._temporary.name) / "hotdog-mcfg-inspect"
        subprocess.run(
            [
                "cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2",
                "-I", str(SOURCE), str(SOURCE / "hotdog-mbn.c"),
                str(SOURCE / "hotdog-pdc.c"), str(SOURCE / "hotdog-mcfg.c"),
                str(SOURCE / "hotdog-mcfg-inspect.c"), *flags,
                "-o", str(cls.binary),
            ],
            check=True,
        )

    @classmethod
    def tearDownClass(cls) -> None:
        cls._temporary.cleanup()

    def test_catalog_ids_are_sha1_and_selection_uses_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "mcfg_sw"
            first = profile(root / "generic/eu/alpha/mcfg_sw.mbn", "ALPHA", 123456, 1)
            second = profile(root / "generic/eu/beta/mcfg_sw.mbn", "BETA", 654321, 2)
            (root / "mbn_sw.txt").write_text(
                "mcfg_sw/generic/eu/alpha/mcfg_sw.mbn\n"
                "mcfg_sw/generic/eu/beta/mcfg_sw.mbn\n"
            )
            result = subprocess.run(
                [str(self.binary), str(root), "6543210000000000000", "0", "0"],
                check=True, capture_output=True, text=True,
            )
            self.assertIn("catalog-count=2 listed=2 listed-missing=0", result.stdout)
            self.assertIn(hashlib.sha1(first).hexdigest(), result.stdout)
            self.assertIn(hashlib.sha1(second).hexdigest(), result.stdout)
            self.assertIn("selection-result=0 path:generic/eu/beta/mcfg_sw.mbn", result.stdout)

    def test_stale_list_entry_is_reported_without_hiding_real_profiles(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "mcfg_sw"
            profile(root / "generic/common/default/mcfg_sw.mbn", "DEFAULT", 111111, 1)
            (root / "mbn_sw.txt").write_text(
                "mcfg_sw/generic/common/stale/mcfg_sw.mbn\n"
            )
            result = subprocess.run(
                [str(self.binary), str(root)], check=True, capture_output=True, text=True,
            )
            self.assertIn("catalog-count=1 listed=1 listed-missing=1", result.stdout)

    def test_symlink_is_rejected_before_catalog_use(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "mcfg_sw"
            root.mkdir()
            (root / "mbn_sw.txt").write_text("mcfg_sw/link/mcfg_sw.mbn\n")
            (root / "link").symlink_to(Path(directory), target_is_directory=True)
            result = subprocess.run([str(self.binary), str(root)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn("catalog-error=-40", result.stderr)

    def test_list_path_traversal_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "mcfg_sw"
            root.mkdir()
            (root / "mbn_sw.txt").write_text("mcfg_sw/../outside/mcfg_sw.mbn\n")
            result = subprocess.run([str(self.binary), str(root)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn("catalog-error=-22", result.stderr)

    def test_private_oos10_catalog_when_available(self) -> None:
        private_root = ROOT / "aports/device/testing/firmware-oneplus-hotdog-modem-oos10"
        archive = private_root / "mcfg-oos10.0.13.tar.gz"
        if not archive.is_file():
            self.skipTest("private OOS10 MCFG archive is not staged")
        with tempfile.TemporaryDirectory() as directory:
            subprocess.run(["tar", "-xzf", str(archive), "-C", directory], check=True)
            result = subprocess.run(
                [str(self.binary), str(Path(directory) / "mcfg_sw")],
                check=True, capture_output=True, text=True,
            )
            self.assertIn("catalog-count=69 listed=69 listed-missing=1", result.stdout)
            self.assertIn("carrier:Proximus_Belgium", result.stdout)


if __name__ == "__main__":
    unittest.main()
