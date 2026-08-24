from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]
SOURCE = ROOT / "helpers/hotdog-radio"


class HotdogRadioStateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls._temporary = tempfile.TemporaryDirectory()
        cls.binary = Path(cls._temporary.name) / "hotdog-radio-replay"
        subprocess.run(
            [
                "cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2",
                "-I", str(SOURCE),
                str(SOURCE / "hotdog-radio-state.c"),
                str(SOURCE / "hotdog-radio-replay.c"),
                "-o", str(cls.binary),
            ],
            check=True,
        )

    @classmethod
    def tearDownClass(cls) -> None:
        cls._temporary.cleanup()

    def replay(self, lines: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run([str(self.binary)], input=lines, text=True, capture_output=True, check=True)

    def test_online_is_gated_by_active_pdc(self) -> None:
        result = self.replay("START\nQRTR_UP\nUIM_READY 1 0\nPDC_STATUS 0 0\nDMS_ONLINE\n")
        self.assertIn("phase=pdc-selecting result=0 actions=select-pdc", result.stdout)
        self.assertIn("phase=pdc-selecting result=-71", result.stdout)

    def test_complete_locked_then_unlocked_boot(self) -> None:
        result = self.replay(
            "START\nQRTR_UP\nUIM_READY 1 0\nPDC_STATUS 1 0\n"
            "DMS_ONLINE\nUIM_UNLOCKED 1\nNAS_REGISTERED\n"
        )
        self.assertIn("phase=locked result=0 actions=publish-ready", result.stdout)
        self.assertIn("phase=registering result=0 actions=start-registration", result.stdout)
        self.assertTrue(result.stdout.rstrip().endswith("phase=ready result=0 actions=publish-ready"))

    def test_ssr_tears_down_every_runtime_domain(self) -> None:
        result = self.replay(
            "QRTR_UP\nUIM_READY 1 1\nPDC_STATUS 1 0\nDMS_ONLINE\nNAS_REGISTERED\n"
            "DATA_UP\nSMS_BEGIN\nCALL_BEGIN\nIMS_REGISTERED\nQRTR_DOWN\n"
        )
        last = result.stdout.splitlines()[-1]
        self.assertIn("phase=recovering", last)
        for action in ("teardown-data", "fail-sms", "drop-calls", "clear-ims"):
            self.assertIn(action, last)

    def test_requests_are_rejected_before_registration(self) -> None:
        result = self.replay("QRTR_UP\nUIM_READY 1 0\nSMS_BEGIN\n")
        self.assertTrue(result.stdout.rstrip().endswith("result=-112 actions=reject-request"))


if __name__ == "__main__":
    unittest.main()
