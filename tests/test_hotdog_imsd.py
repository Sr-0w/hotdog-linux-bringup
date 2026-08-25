from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]
SOURCE = ROOT / "helpers" / "hotdog-radio"


class HotdogImsdTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        flags = subprocess.run(
            ["pkg-config", "--cflags", "--libs", "qmi-glib", "qrtr-glib",
             "gio-2.0", "glib-2.0"], check=True, capture_output=True,
            text=True,
        ).stdout.split()
        cls._temporary = tempfile.TemporaryDirectory()
        cls.binary = Path(cls._temporary.name) / "hotdog-imsd"
        sources = [
            "hotdog-imsd.c", "hotdog-ims-state.c", "hotdog-qmi-imsa.c",
            "hotdog-radio-readiness.c", "hotdog-mcfg-runtime.c",
            "hotdog-telephony.c", "hotdog-pdc.c", "hotdog-uim.c",
            "hotdog-mbn.c",
        ]
        subprocess.run(
            ["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2",
             "-I", str(SOURCE), *(str(SOURCE / name) for name in sources),
             *flags, "-o", str(cls.binary)], check=True,
        )

    @classmethod
    def tearDownClass(cls) -> None:
        cls._temporary.cleanup()

    def test_daemon_compiles_and_exposes_only_runtime_identity_options(self) -> None:
        output = subprocess.run([str(self.binary), "--help"], check=True,
                                capture_output=True, text=True).stdout
        self.assertIn("--generation=GENERATION", output)
        self.assertIn("--readiness=FILE", output)
        self.assertIn("--state=FILE", output)
        self.assertNotIn("iccid", output.lower())
        self.assertNotIn("imsi", output.lower())

    def test_missing_readiness_fails_before_qrtr_or_state_creation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "ims-state"
            result = subprocess.run(
                [str(self.binary), "--readiness", str(Path(directory) / "missing"),
                 "--state", str(state)], capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 1)
            self.assertIn("startup readiness rejected", result.stderr)
            self.assertFalse(state.exists())

    def test_one_imsa_client_is_bound_per_populated_subscription(self) -> None:
        source = (SOURCE / "hotdog-imsd.c").read_text()
        self.assertIn("QMI_SERVICE_IMSA", source)
        self.assertIn("hotdog_qmi_imsa_bind_input(subscription->index", source)
        self.assertIn('"ims-registration-status-changed"', source)
        self.assertIn('"ims-services-status-changed"', source)
        self.assertIn("registration_indicated", source)
        self.assertIn("services_indicated", source)

    def test_ssr_and_readiness_loss_remove_published_state(self) -> None:
        source = (SOURCE / "hotdog-imsd.c").read_text()
        self.assertIn("QRTR node removed", source)
        self.assertIn("readiness became invalid", source)
        self.assertIn("unlink(imsd->state_path)", source)


if __name__ == "__main__":
    unittest.main()
