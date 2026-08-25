from __future__ import annotations

import hashlib
import subprocess
import tempfile
import unittest
from pathlib import Path

from tests.test_hotdog_mcfg import profile


ROOT = Path(__file__).parents[1]
SOURCE = ROOT / "helpers" / "hotdog-radio"
BOOT = "01234567-89ab-cdef-0123-456789abcdef"
ARCHIVE_SHA = "c" * 64


HARNESS = r'''#include "hotdog-radio-gate.h"
#include "hotdog-mcfg.h"
#include <stdio.h>
int main(int argc, char **argv) {
    struct hotdog_radio_gate_paths paths = { argv[1], argv[2], argv[3], argv[4], argv[5] };
    struct hotdog_pdc_catalog catalog;
    struct hotdog_mcfg_report report;
    struct hotdog_pdc_subscription subscriptions[3] = { 0 };
    struct hotdog_mcfg_runtime runtime;
    int result = hotdog_mcfg_catalog_load(argv[5], &catalog, &report);
    (void)argc;
    if (!result) { subscriptions[0].populated=true; subscriptions[0].selected=catalog.configs[0].id;
        result=hotdog_radio_gate_validate(&paths,&catalog,subscriptions,3,&runtime); }
    printf("result=%d\n",result); return 0;
}
'''


class HotdogRadioGateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        flags = subprocess.run(["pkg-config", "--cflags", "--libs", "glib-2.0"],
                               check=True, capture_output=True, text=True).stdout.split()
        cls._temporary = tempfile.TemporaryDirectory()
        source = Path(cls._temporary.name) / "gate.c"
        cls.binary = Path(cls._temporary.name) / "gate"
        source.write_text(HARNESS)
        subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2",
                        "-I", str(SOURCE), str(SOURCE / "hotdog-mbn.c"),
                        str(SOURCE / "hotdog-pdc.c"), str(SOURCE / "hotdog-mcfg.c"),
                        str(SOURCE / "hotdog-mcfg-runtime.c"),
                        str(SOURCE / "hotdog-radio-approval.c"),
                        str(SOURCE / "hotdog-radio-gate.c"), str(source), *flags,
                        "-o", str(cls.binary)], check=True)

    @classmethod
    def tearDownClass(cls) -> None:
        cls._temporary.cleanup()

    def fixture(self, directory: Path) -> list[str]:
        mcfg = directory / "mcfg_sw"
        relative = "generic/eu/test/mcfg_sw.mbn"
        payload = profile(mcfg / relative, "GATE", 123456, 1)
        (mcfg / relative.replace(".mbn", ".sig")).write_bytes(payload)
        (mcfg / "mbn_sw.txt").write_text(f"mcfg_sw/{relative}\n")
        modem = directory / "modem.mbn"
        modem.write_bytes(b"PUBLIC_MODEM")
        modem_sha = hashlib.sha256(modem.read_bytes()).hexdigest()
        boot = directory / "boot_id"
        boot.write_text(BOOT + "\n")
        runtime = directory / "runtime"
        runtime.write_text(
            "schema=1\nsource-sha256=" + "a" * 64 + "\n"
            "mpss-build=PUBLIC\nmodem-sha256=" + modem_sha + "\n"
            "mcfg-archive-sha256=" + ARCHIVE_SHA + "\n"
            "profile-count=1\nsignature-count=1\ncatalog-file-count=3\n"
        )
        selected = hashlib.sha1(payload).hexdigest()
        approval = directory / "approval"
        approval.write_text(
            f"schema=1\nboot-id={BOOT}\nmodem-sha256={modem_sha}\n"
            f"mcfg-archive-sha256={ARCHIVE_SHA}\nsub0-selected={selected}\n"
            "sub1-selected=-\nsub2-selected=-\n"
        )
        return [str(approval), str(runtime), str(boot), str(modem), str(mcfg)]

    def run_gate(self, paths: list[str]) -> str:
        return subprocess.run([str(self.binary), *paths], check=True,
                              capture_output=True, text=True).stdout.strip()

    def test_exact_runtime_and_approval_validate(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            self.assertEqual(self.run_gate(self.fixture(Path(directory))), "result=0")

    def test_changed_modem_is_stale(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            paths = self.fixture(Path(directory))
            Path(paths[3]).write_bytes(b"CHANGED_MODEM")
            self.assertEqual(self.run_gate(paths), "result=-116")

    def test_wrong_catalog_counts_fail_protocol_gate(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            paths = self.fixture(Path(directory))
            runtime = Path(paths[1])
            runtime.write_text(runtime.read_text().replace("catalog-file-count=3", "catalog-file-count=4"))
            self.assertEqual(self.run_gate(paths), "result=-71")

    def test_stale_boot_approval_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            paths = self.fixture(Path(directory))
            Path(paths[2]).write_text("fedcba98-7654-3210-fedc-ba9876543210\n")
            self.assertEqual(self.run_gate(paths), "result=-116")


if __name__ == "__main__":
    unittest.main()
