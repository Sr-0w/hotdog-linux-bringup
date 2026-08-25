from __future__ import annotations

from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "helpers/hotdog-radio"


class HotdogWdsProfileProbeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        flags = subprocess.run(
            ["pkg-config", "--cflags", "--libs", "qmi-glib", "qrtr-glib",
             "gio-2.0", "glib-2.0"], check=True, capture_output=True,
            text=True,
        ).stdout.split()
        cls.temp = tempfile.TemporaryDirectory()
        cls.binary = Path(cls.temp.name) / "hotdog-wds-profile-probe"
        sources = [
            "hotdog-wds-profile-probe.c", "hotdog-qmi-wds-discovery.c",
            "hotdog-qmi-wds-profile.c",
            "hotdog-ims-bearer.c", "hotdog-network.c",
        ]
        subprocess.run(
            ["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2",
             "-I", str(SOURCE), *(str(SOURCE / item) for item in sources),
             *flags, "-o", str(cls.binary)], check=True,
        )

    @classmethod
    def tearDownClass(cls) -> None:
        cls.temp.cleanup()

    def test_probe_builds_and_rejects_invalid_subscription_counts(self) -> None:
        help_output = subprocess.run(
            [str(self.binary), "--help"], check=True, capture_output=True,
            text=True,
        ).stdout
        self.assertIn("--subscriptions=COUNT", help_output)
        for count in ("0", "4"):
            result = subprocess.run(
                [str(self.binary), "--subscriptions", count],
                capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 2)
            self.assertIn("invalid WDS profile probe configuration", result.stderr)

    def test_probe_is_read_only_and_subscription_scoped(self) -> None:
        source = (SOURCE / "hotdog-wds-profile-probe.c").read_text(encoding="ascii")
        self.assertIn("hotdog_qmi_wds_discovery_start", source)
        self.assertNotIn("start_network", source.lower())
        self.assertNotIn("stop_network", source.lower())
        self.assertNotIn("QMI_SERVICE_UIM", source)
        self.assertNotIn("add_link", source)

    def test_probe_logs_no_profile_credentials(self) -> None:
        source = (SOURCE / "hotdog-wds-profile-probe.c").read_text(encoding="ascii")
        self.assertNotIn("username", source.lower())
        self.assertNotIn("password", source.lower())
        self.assertNotIn("iccid", source.lower())
        self.assertNotIn("imsi", source.lower())


if __name__ == "__main__":
    unittest.main()
