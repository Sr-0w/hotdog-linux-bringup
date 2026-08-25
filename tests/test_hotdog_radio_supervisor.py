from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]
SOURCE = ROOT / "helpers" / "hotdog-radio"


class HotdogRadioSupervisorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls._temporary = tempfile.TemporaryDirectory()
        cls.binary = Path(cls._temporary.name) / "supervisor-replay"
        subprocess.run(
            ["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2",
             "-I", str(SOURCE), str(SOURCE / "hotdog-radio-supervisor.c"),
             str(SOURCE / "hotdog-radio-supervisor-replay.c"),
             "-o", str(cls.binary)],
            check=True,
        )

    @classmethod
    def tearDownClass(cls) -> None:
        cls._temporary.cleanup()

    def replay(self, events: str) -> list[str]:
        result = subprocess.run([str(self.binary)], input=events, text=True,
                                capture_output=True, check=True)
        return result.stdout.splitlines()

    def test_normal_handoff_requires_qrtr_and_readiness(self) -> None:
        lines = self.replay("QRTR_UP\nREADY\nMM_STARTED\n")
        self.assertIn("phase=wait-readiness result=0 generation=0 actions=read-readiness", lines[0])
        self.assertIn("actions=start-modemmanager", lines[1])
        self.assertTrue(lines[2].endswith("actions=none"))
        self.assertIn("phase=active", lines[2])

    def test_ssr_revokes_and_requires_reattest_before_restart(self) -> None:
        lines = self.replay(
            "QRTR_UP\nREADY\nMM_STARTED\nQRTR_DOWN\nMM_STOPPED\n"
            "QRTR_UP\nREADY\n"
        )
        self.assertIn("stop-modemmanager,revoke-readiness", lines[3])
        self.assertIn("phase=wait-qrtr", lines[4])
        self.assertTrue(lines[5].endswith("actions=reattest"))
        self.assertTrue(lines[6].endswith("actions=start-modemmanager"))

    def test_ssr_during_start_stops_late_child(self) -> None:
        lines = self.replay("QRTR_UP\nREADY\nQRTR_DOWN\nMM_STARTED\nMM_STOPPED\n")
        self.assertTrue(lines[2].endswith("actions=revoke-readiness"))
        self.assertIn("phase=stopping-modemmanager", lines[3])
        self.assertTrue(lines[3].endswith("actions=stop-modemmanager"))
        self.assertIn("phase=wait-qrtr", lines[4])

    def test_invalid_readiness_stops_active_modemmanager(self) -> None:
        lines = self.replay("QRTR_UP\nREADY\nMM_STARTED\nINVALID\nMM_STOPPED\n")
        self.assertIn("stop-modemmanager,revoke-readiness", lines[3])
        self.assertTrue(lines[4].endswith("actions=read-readiness"))

    def test_stop_failure_blocks_future_handoff(self) -> None:
        lines = self.replay(
            "QRTR_UP\nREADY\nMM_STARTED\nREMOVED\nMM_STOP_FAILED\nRETRY\n"
        )
        self.assertIn("phase=blocked", lines[4])
        self.assertIn("result=-108", lines[5])

    def test_repeated_start_failure_is_bounded(self) -> None:
        lines = self.replay(
            "QRTR_UP\nREADY\nMM_START_FAILED\nREADY\nMM_START_FAILED\n"
            "READY\nMM_START_FAILED\nREADY\nMM_START_FAILED\n"
        )
        self.assertIn("phase=blocked", lines[-1])
        self.assertTrue(lines[-1].endswith("actions=revoke-readiness"))

    def test_fatal_during_start_stops_late_child_then_blocks(self) -> None:
        lines = self.replay("QRTR_UP\nREADY\nFATAL\nMM_STARTED\nMM_STOPPED\n")
        self.assertIn("phase=starting-modemmanager", lines[2])
        self.assertTrue(lines[2].endswith("actions=revoke-readiness"))
        self.assertIn("phase=stopping-modemmanager", lines[3])
        self.assertTrue(lines[3].endswith("actions=stop-modemmanager"))
        self.assertIn("phase=blocked", lines[4])


if __name__ == "__main__":
    unittest.main()
