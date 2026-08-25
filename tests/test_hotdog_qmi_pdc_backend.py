from __future__ import annotations

import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]
SOURCE = ROOT / "helpers" / "hotdog-radio"


class HotdogQmiPdcBackendTests(unittest.TestCase):
    def test_backend_compiles_with_strict_warnings(self) -> None:
        flags = subprocess.run(
            ["pkg-config", "--cflags", "qmi-glib", "gio-2.0", "glib-2.0"],
            check=True, capture_output=True, text=True,
        ).stdout.split()
        subprocess.run(
            [
                "cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2",
                "-fsyntax-only", "-I", str(SOURCE),
                str(SOURCE / "hotdog-qmi-pdc-backend.c"), *flags,
            ],
            check=True,
        )

    def test_switch_is_explicitly_owned_by_outer_reconnect(self) -> None:
        source = (SOURCE / "hotdog-qmi-pdc-backend.c").read_text()
        self.assertIn("HOTDOG_QMI_PDC_REQUEST_SWITCH", source)
        self.assertIn("return -EINPROGRESS;", source)

    def test_verify_requires_active_match_and_no_pending_id(self) -> None:
        source = (SOURCE / "hotdog-qmi-pdc-backend.c").read_text()
        self.assertIn("hotdog_pdc_id_equal(&active", source)
        self.assertIn("pending.length", source)


if __name__ == "__main__":
    unittest.main()
