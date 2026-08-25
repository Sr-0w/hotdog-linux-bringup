from __future__ import annotations

from pathlib import Path
import os
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "helpers/hotdog-radio"

HARNESS = r'''
#include "hotdog-radio-reattest.h"
#include <stdio.h>
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    printf("result=%d\n", hotdog_radio_reattest_consume(argv[1]));
}
'''


class HotdogRadioReattestTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.temp = tempfile.TemporaryDirectory()
        source = Path(cls.temp.name) / "reattest.c"
        source.write_text(HARNESS, encoding="ascii")
        cls.binary = Path(cls.temp.name) / "reattest"
        subprocess.run(
            ["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2",
             "-I", str(SOURCE), str(SOURCE / "hotdog-radio-reattest.c"),
             str(source), "-o", str(cls.binary)], check=True,
        )

    @classmethod
    def tearDownClass(cls) -> None:
        cls.temp.cleanup()

    def consume(self, path: Path) -> int:
        output = subprocess.run(
            [str(self.binary), str(path)], check=True,
            capture_output=True, text=True,
        ).stdout.strip()
        return int(output.split("=", 1)[1])

    def test_valid_request_is_consumed_once(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "request"
            path.write_text("pin-unlocked\n", encoding="ascii")
            os.chmod(path, 0o600)
            self.assertEqual(self.consume(path), 1)
            self.assertFalse(path.exists())
            self.assertEqual(self.consume(path), 0)

    def test_symlink_writable_and_malformed_requests_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "target"
            target.write_text("pin-unlocked\n", encoding="ascii")
            link = root / "link"
            link.symlink_to(target)
            self.assertLess(self.consume(link), 0)
            os.chmod(target, 0o666)
            self.assertLess(self.consume(target), 0)
            os.chmod(target, 0o600)
            target.write_text("wrong\n", encoding="ascii")
            self.assertLess(self.consume(target), 0)
            self.assertTrue(target.exists())


if __name__ == "__main__":
    unittest.main()
