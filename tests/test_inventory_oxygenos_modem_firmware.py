from __future__ import annotations

import importlib.util
import io
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).parents[1] / "scripts" / "inventory-oxygenos-modem-firmware.py"
SPEC = importlib.util.spec_from_file_location("inventory_oxygenos_modem_firmware", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(MODULE)


LISTING = """
Path = /private/modem.img
Type = FAT
Path = image/modem_pr/mcfg/configs/mcfg_sw/generic/eu/a/mcfg_sw.mbn
Path = image/modem_pr/mcfg/configs/mcfg_sw/generic/eu/a/mcfg_sw.sig
Path = image/modem_pr/mcfg/configs/mcfg_sw/generic/eu/A/mcfg_sw.mbn
Path = image/modem.mdt
"""


class InventoryOxygenosModemFirmwareTests(unittest.TestCase):
    def test_listing_counts_casefold_duplicates(self) -> None:
        paths = MODULE.parse_7z_paths(LISTING)
        result = MODULE.classify_mcfg_paths(paths)
        self.assertEqual(result["profiles_listed"], 2)
        self.assertEqual(result["profiles_unique_casefold"], 1)
        self.assertEqual(result["profile_duplicate_groups"], 1)
        self.assertEqual(result["signatures_listed"], 1)
        self.assertEqual(result["regions"], ["eu"])

    def test_inventory_never_emits_the_host_input_path(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            inner_bytes = io.BytesIO()
            with zipfile.ZipFile(inner_bytes, "w") as inner:
                inner.writestr(MODULE.MODEM_MEMBER, b"PUBLIC_MODEM_IMAGE")
                inner.writestr("firmware-update/aop.img", b"PUBLIC_AOP")
            bundle = root / "private-source-name.zip"
            with zipfile.ZipFile(bundle, "w") as outer:
                outer.writestr("OnePlus/OOS12/fw_EU.zip", inner_bytes.getvalue())
            completed = mock.Mock(stdout=LISTING, returncode=2)
            with mock.patch.object(MODULE.subprocess, "run", return_value=completed):
                result = MODULE.inventory_bundle(bundle)
            self.assertEqual(len(result["firmware_packages"]), 1)
            self.assertEqual(result["firmware_packages"][0]["mcfg"]["profiles_listed"], 2)
            self.assertNotIn(directory, str(result))


if __name__ == "__main__":
    unittest.main()
