from __future__ import annotations

import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]
SOURCE = ROOT / "helpers" / "hotdog-radio"


class HotdogPdcControllerTests(unittest.TestCase):
    def test_controller_and_rebind_compile_strictly(self) -> None:
        flags = subprocess.run(
            ["pkg-config", "--cflags", "qmi-glib", "gio-2.0", "glib-2.0"],
            check=True, capture_output=True, text=True,
        ).stdout.split()
        subprocess.run(
            [
                "cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2",
                "-fsyntax-only", "-I", str(SOURCE),
                str(SOURCE / "hotdog-pdc-controller.c"),
                str(SOURCE / "hotdog-qmi-pdc-backend.c"), *flags,
            ],
            check=True,
        )

    def test_transport_loss_is_split_between_activation_and_other_requests(self) -> None:
        backend = (SOURCE / "hotdog-qmi-pdc-backend.c").read_text()
        self.assertIn("HOTDOG_QMI_PDC_REQUEST_ACTIVATE", backend)
        self.assertIn("backend_finish(backend, 0, 0);", backend)
        self.assertIn("backend_finish(backend, -ENETRESET, 0);", backend)

    def test_switch_requires_outer_completion_before_verify(self) -> None:
        source = (SOURCE / "hotdog-pdc-controller.c").read_text()
        self.assertIn("controller->waiting_switch = true", source)
        self.assertIn("hotdog_pdc_controller_switch_complete", source)
        self.assertIn("hotdog_qmi_pdc_request_clear", source)


if __name__ == "__main__":
    unittest.main()
