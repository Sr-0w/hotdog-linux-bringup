from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]
SOURCE = ROOT / "helpers/hotdog-radio"


class HotdogUimTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls._temporary = tempfile.TemporaryDirectory()
        cls.binary = Path(cls._temporary.name) / "hotdog-uim-replay"
        subprocess.run(
            [
                "cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2",
                "-I", str(SOURCE), str(SOURCE / "hotdog-uim.c"),
                str(SOURCE / "hotdog-uim-replay.c"), "-o", str(cls.binary),
            ],
            check=True,
        )

    @classmethod
    def tearDownClass(cls) -> None:
        cls._temporary.cleanup()

    def replay(self, content: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run([str(self.binary)], input=content, text=True, capture_output=True)

    def test_two_physical_slots_become_two_subscriptions(self) -> None:
        result = self.replay(
            "SLOT 1 present\nAPP 1 usim pin\n"
            "SLOT 2 present\nAPP 2 usim ready\nSELECT\n"
        )
        self.assertEqual(result.returncode, 0)
        self.assertIn("result=0 gw=2", result.stdout)
        self.assertIn("gw0=slot1,app0,usim,pin-required", result.stdout)
        self.assertIn("gw1=slot2,app0,usim,ready", result.stdout)

    def test_empty_slot_is_preserved_but_not_provisioned(self) -> None:
        result = self.replay("SLOT 1 absent\nSLOT 2 present\nAPP 2 usim ready\nSELECT\n")
        self.assertIn("result=0 gw=1", result.stdout)
        self.assertIn("gw0=slot2", result.stdout)

    def test_no_atr_error_blocks_provisioning(self) -> None:
        result = self.replay("SLOT 1 error\nSLOT 2 present\nAPP 2 usim ready\nSELECT\n")
        self.assertIn("result=-5", result.stdout)

    def test_missing_card_does_not_fabricate_slot_one_session(self) -> None:
        result = self.replay("SLOT 1 absent\nSLOT 2 absent\nSELECT\n")
        self.assertIn("result=-19 gw=0", result.stdout)

    def test_security_operations_require_an_explicit_slot(self) -> None:
        result = self.replay("SECURITY_SLOT 0\nSECURITY_SLOT 2\n")
        self.assertEqual(result.stdout.splitlines(), ["security-slot=-22", "security-slot=2"])

    def test_failed_pin_attempt_must_not_hide_a_retry_decrement(self) -> None:
        result = self.replay("RETRIES 3 10 3 10 2 10 3 10 0\n")
        self.assertEqual(result.stdout.strip(), "retry-safe=0")

    def test_slot_identity_decodes_bcd_and_trims_terminal_filler(self) -> None:
        result = self.replay("IDENTITY 2 1 1 0 98230021436587F9\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "identity=0 slot:2 iccid:893200123456789")

    def test_empty_slot_cannot_carry_an_iccid(self) -> None:
        result = self.replay("IDENTITY 1 0 1 0 9823\n")
        self.assertIn("identity=-22 slot:1", result.stdout)

    def test_modemmanager_handoff_follows_readiness_publication(self) -> None:
        source = (SOURCE / "hotdog-radio-bootstrapd.c").read_text()
        readiness = source.index("result = publish_readiness(bootstrap);")
        handoff = source.index("result = start_modemmanager_handoff();")
        self.assertLess(readiness, handoff)
        self.assertIn('"/sbin/rc-service", "modemmanager", "start"', source)


class HotdogQmiUimBuildTests(unittest.TestCase):
    def test_qrtr_uim_bootstrap_builds(self) -> None:
        flags = subprocess.run(
            ["pkg-config", "--cflags", "--libs", "qmi-glib", "qrtr-glib", "gio-2.0", "glib-2.0"],
            capture_output=True, text=True,
        )
        if flags.returncode:
            self.skipTest("libqmi/qrtr development files are unavailable")
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / "hotdog-radio-bootstrapd"
            subprocess.run(
                [
                    "cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2",
                    "-I", str(SOURCE),
                    str(SOURCE / "hotdog-radio-bootstrapd.c"),
                    str(SOURCE / "hotdog-qmi-dms.c"),
                    str(SOURCE / "hotdog-qmi-nas.c"),
                    str(SOURCE / "hotdog-qmi-uim.c"),
                    str(SOURCE / "hotdog-uim.c"),
                    "-o", str(binary), *flags.stdout.split(),
                ],
                check=True,
            )
            help_output = subprocess.run([str(binary), "--help"], check=True, capture_output=True, text=True)
            self.assertIn("--node=ID", help_output.stdout)
            self.assertIn("--pdc-subscription=0-2", help_output.stdout)
            self.assertIn("--plan-pdc", help_output.stdout)
            self.assertIn("--apply-pdc=FILE", help_output.stdout)
            self.assertIn("--mcfg-root=DIR", help_output.stdout)
            self.assertIn("--probe-dms", help_output.stdout)
            self.assertIn("--probe-pdc-catalog", help_output.stdout)
            self.assertIn("--probe-nas", help_output.stdout)
            unsupported = subprocess.run(
                [str(binary), "--pdc-subscription=0"], capture_output=True, text=True,
            )
            self.assertEqual(unsupported.returncode, 2)
            self.assertIn("require the patched libqmi build", unsupported.stderr)
            missing_root = subprocess.run(
                [str(binary), "--plan-pdc"], capture_output=True, text=True,
            )
            self.assertEqual(missing_root.returncode, 2)
            self.assertIn("requires --mcfg-root", missing_root.stderr)
            wrong_root = subprocess.run(
                [str(binary), "--apply-pdc=/tmp/approval", "--mcfg-root=/tmp/mcfg"],
                capture_output=True, text=True,
            )
            self.assertEqual(wrong_root.returncode, 2)
            self.assertIn("canonical packaged MCFG root", wrong_root.stderr)
            unsupported_apply = subprocess.run(
                [str(binary), "--apply-pdc=/tmp/approval",
                 "--mcfg-root=/usr/share/hotdog-radio/mcfg/mcfg_sw"],
                capture_output=True, text=True,
            )
            self.assertEqual(unsupported_apply.returncode, 2)
            self.assertIn("patched libqmi build", unsupported_apply.stderr)


if __name__ == "__main__":
    unittest.main()
