from __future__ import annotations

from pathlib import Path
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "helpers/hotdog-reboot-mode.py"


class HotdogRebootModeTests(unittest.TestCase):
    def test_dry_run_exposes_only_supported_modes(self) -> None:
        for mode, cookie in (("bootloader", "0x77665500"),
                             ("recovery", "0x77665502")):
            result = subprocess.run(
                ["python3", str(HELPER), "--dry-run", mode], check=True,
                capture_output=True, text=True,
            )
            self.assertIn(f"mode={mode}", result.stdout)
            self.assertIn(cookie, result.stdout)
            self.assertIn("non emis", result.stdout)
        rejected = subprocess.run(
            ["python3", str(HELPER), "--dry-run", "unknown"],
            capture_output=True, text=True,
        )
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("mode non supporte", rejected.stderr)

    def test_helper_uses_raw_aarch64_restart2_syscall(self) -> None:
        source = HELPER.read_text(encoding="utf-8")
        self.assertIn("SYS_REBOOT = 142", source)
        self.assertIn("libc.syscall", source)
        self.assertIn("LINUX_REBOOT_CMD_RESTART2", source)
        self.assertNotIn("libc.reboot", source)
        self.assertNotIn('ctypes.CDLL("libc.so.6"', source)


if __name__ == "__main__":
    unittest.main()
