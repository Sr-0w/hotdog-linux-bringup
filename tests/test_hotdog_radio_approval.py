from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]
SOURCE = ROOT / "helpers" / "hotdog-radio"
BOOT = "01234567-89ab-cdef-0123-456789abcdef"
SHA_A = "a" * 64
SHA_B = "b" * 64
ID = "00112233445566778899aabbccddeeff00112233"


HARNESS = r'''#include "hotdog-radio-approval.h"
#include <stdio.h>
#include <string.h>
int main(int argc, char **argv) {
    struct hotdog_radio_approval approval;
    struct hotdog_pdc_subscription subscriptions[HOTDOG_PDC_MAX_SUBSCRIPTIONS] = { 0 };
    int result = hotdog_radio_approval_read(argv[1], &approval);
    (void)argc;
    if (result) { printf("read=%d\n", result); return 0; }
    subscriptions[0].populated = true;
    subscriptions[0].selected = approval.selected[0];
    result = hotdog_radio_approval_validate(&approval, argv[2], argv[3], argv[4],
                                             subscriptions, 3);
    printf("read=0 validate=%d\n", result);
    return 0;
}
'''


def manifest(*, boot: str = BOOT, extra: str = "", sub0: str = ID) -> str:
    return (
        "schema=1\n"
        f"boot-id={boot}\n"
        f"modem-sha256={SHA_A}\n"
        f"mcfg-archive-sha256={SHA_B}\n"
        f"sub0-selected={sub0}\n"
        "sub1-selected=-\nsub2-selected=-\n"
        f"{extra}"
    )


class HotdogRadioApprovalTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls._temporary = tempfile.TemporaryDirectory()
        source = Path(cls._temporary.name) / "approval-harness.c"
        cls.binary = Path(cls._temporary.name) / "approval-harness"
        source.write_text(HARNESS)
        subprocess.run(
            [
                "cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2",
                "-I", str(SOURCE), str(SOURCE / "hotdog-mbn.c"),
                str(SOURCE / "hotdog-pdc.c"), str(SOURCE / "hotdog-radio-approval.c"),
                str(source), "-o", str(cls.binary),
            ],
            check=True,
        )

    @classmethod
    def tearDownClass(cls) -> None:
        cls._temporary.cleanup()

    def run_manifest(self, content: str, boot: str = BOOT) -> str:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "approval"
            path.write_text(content)
            return subprocess.run(
                [str(self.binary), str(path), boot, SHA_A, SHA_B],
                check=True, capture_output=True, text=True,
            ).stdout.strip()

    def test_exact_manifest_validates(self) -> None:
        self.assertEqual(self.run_manifest(manifest()), "read=0 validate=0")

    def test_stale_boot_is_rejected(self) -> None:
        self.assertEqual(
            self.run_manifest(manifest(), "fedcba98-7654-3210-fedc-ba9876543210"),
            "read=0 validate=-116",
        )

    def test_unknown_duplicate_and_missing_keys_fail_closed(self) -> None:
        self.assertEqual(self.run_manifest(manifest(extra="unknown=x\n")), "read=-22")
        self.assertEqual(self.run_manifest(manifest(extra="schema=1\n")), "read=-22")
        self.assertEqual(self.run_manifest(manifest().replace("sub2-selected=-\n", "")), "read=-61")

    def test_populated_subscription_requires_an_exact_id(self) -> None:
        self.assertEqual(self.run_manifest(manifest(sub0="-")), "read=0 validate=-71")

    def test_group_writable_manifest_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "approval"
            path.write_text(manifest())
            path.chmod(0o664)
            result = subprocess.run(
                [str(self.binary), str(path), BOOT, SHA_A, SHA_B],
                check=True, capture_output=True, text=True,
            )
            self.assertEqual(result.stdout.strip(), "read=-1")


if __name__ == "__main__":
    unittest.main()
