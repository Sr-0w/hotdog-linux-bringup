from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]
SOURCE = ROOT / "helpers" / "hotdog-radio"


class HotdogRadioSupervisordTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        flags = subprocess.run(
            ["pkg-config", "--cflags", "--libs", "qrtr-glib", "gio-2.0", "glib-2.0"],
            check=True, capture_output=True, text=True,
        ).stdout.split()
        cls._temporary = tempfile.TemporaryDirectory()
        cls.binary = Path(cls._temporary.name) / "hotdog-radio-supervisord"
        subprocess.run(
            [
                "cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2",
                "-I", str(SOURCE),
                str(SOURCE / "hotdog-radio-supervisord.c"),
                str(SOURCE / "hotdog-radio-supervisor.c"),
                str(SOURCE / "hotdog-radio-readiness.c"),
                str(SOURCE / "hotdog-radio-reattest.c"),
                str(SOURCE / "hotdog-mcfg-runtime.c"),
                str(SOURCE / "hotdog-pdc.c"),
                str(SOURCE / "hotdog-uim.c"),
                str(SOURCE / "hotdog-mbn.c"),
                *flags, "-o", str(cls.binary),
            ],
            check=True,
        )

    @classmethod
    def tearDownClass(cls) -> None:
        cls._temporary.cleanup()

    def test_daemon_compiles_and_exposes_bounded_configuration(self) -> None:
        output = subprocess.run([str(self.binary), "--help"], check=True,
                                capture_output=True, text=True).stdout
        self.assertIn("--approval=FILE", output)
        self.assertIn("--failure-limit=COUNT", output)
        self.assertIn("--runtime-manifest=FILE", output)
        self.assertIn("--reattest-request=FILE", output)

    def test_process_control_uses_fixed_argv_without_a_shell(self) -> None:
        source = (SOURCE / "hotdog-radio-supervisord.c").read_text()
        self.assertIn("g_subprocess_new", source)
        self.assertIn('"modemmanager", start ? "start" : "stop"', source)
        self.assertIn('"--defer-handoff"', source)
        self.assertNotIn("system(", source)
        self.assertNotIn("g_spawn_command_line", source)
        self.assertNotIn('"/bin/sh"', source)

    def test_post_pin_request_stops_modemmanager_before_reattest(self) -> None:
        source = (SOURCE / "hotdog-radio-supervisord.c").read_text()
        self.assertIn("hotdog_radio_reattest_consume", source)
        self.assertIn("HOTDOG_SUPERVISOR_READINESS_REMOVED", source)
        self.assertIn("lifecycle->attestation_attempted = false", source)

    def test_bootstrap_deferred_handoff_is_apply_only(self) -> None:
        source = (SOURCE / "hotdog-radio-bootstrapd.c").read_text()
        self.assertIn('"--defer-handoff requires --apply-pdc', source)
        self.assertIn('modemmanager-handoff=deferred', source)


if __name__ == "__main__":
    unittest.main()
