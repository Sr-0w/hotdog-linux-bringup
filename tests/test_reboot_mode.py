from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "helpers/reboot-mode.c"


class RebootModeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls._temporary = tempfile.TemporaryDirectory()
        cls.binary = Path(cls._temporary.name) / "reboot-mode"
        subprocess.run(
            ["cc", "-Wall", "-Wextra", "-Werror", "-O2",
             str(SOURCE), "-o", str(cls.binary)], check=True,
        )

    @classmethod
    def tearDownClass(cls) -> None:
        cls._temporary.cleanup()

    def test_help_names_the_modes_that_matter(self) -> None:
        out = subprocess.run([str(self.binary), "--help"], check=True,
                             capture_output=True, text=True).stdout
        self.assertIn("bootloader", out)
        self.assertIn("recovery", out)

    def test_a_missing_or_empty_mode_is_refused(self) -> None:
        for args in ([], ["", ], ["a", "b"]):
            result = subprocess.run([str(self.binary), *args],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn("Usage", result.stderr)

    def test_it_uses_the_call_that_carries_the_mode(self) -> None:
        source = SOURCE.read_text()
        # La fonction reboot() de la libc ne prend qu'un argument : seule
        # l'entree par l'appel systeme transporte la chaine jusqu'au noyau.
        self.assertIn("SYS_reboot", source)
        self.assertIn("LINUX_REBOOT_CMD_RESTART2", source)
        self.assertNotIn("\treboot(", source)

    def test_it_syncs_before_asking_for_a_restart(self) -> None:
        source = SOURCE.read_text()
        self.assertLess(source.index("sync()"), source.index("SYS_reboot"))

    def test_it_carries_no_device_prefix(self) -> None:
        # Rien ici n'est propre au Hotdog : tout port Qualcomm sous busybox a
        # le meme manque, et le nom doit le refleter.
        self.assertNotIn("hotdog", SOURCE.name)


if __name__ == "__main__":
    unittest.main()
