from __future__ import annotations

import hashlib
import subprocess
import tempfile
import unittest
from pathlib import Path

from tests.test_hotdog_mcfg import profile


ROOT = Path(__file__).parents[1]
SOURCE = ROOT / "helpers" / "hotdog-radio"


HARNESS = r'''#include "hotdog-mcfg.h"
#include <stdio.h>
#include <string.h>
static int hex_id(const char *text, struct hotdog_pdc_id *id) {
    unsigned int value;
    size_t index;
    if (strlen(text) != HOTDOG_PDC_ID_SIZE * 2) return -1;
    for (index = 0; index < HOTDOG_PDC_ID_SIZE; index++) {
        if (sscanf(text + index * 2, "%2x", &value) != 1) return -1;
        id->value[index] = value;
    }
    id->length = HOTDOG_PDC_ID_SIZE;
    return 0;
}
int main(int argc, char **argv) {
    struct hotdog_pdc_config config = { 0 };
    struct hotdog_mcfg_profile opened;
    int result;
    (void)argc;
    if (strlen(argv[2]) >= sizeof(config.path) || hex_id(argv[3], &config.id)) return 2;
    memcpy(config.path, argv[2], strlen(argv[2]) + 1);
    result = hotdog_mcfg_profile_open(argv[1], &config, &opened);
    printf("result=%d size=%u\n", result, result ? 0 : opened.size);
    hotdog_mcfg_profile_clear(&opened);
    return 0;
}
'''


class HotdogMcfgSecureOpenTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        flags = subprocess.run(
            ["pkg-config", "--cflags", "--libs", "glib-2.0"],
            check=True, capture_output=True, text=True,
        ).stdout.split()
        cls._temporary = tempfile.TemporaryDirectory()
        source = Path(cls._temporary.name) / "secure-open.c"
        cls.binary = Path(cls._temporary.name) / "secure-open"
        source.write_text(HARNESS)
        subprocess.run(
            [
                "cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2",
                "-I", str(SOURCE), str(SOURCE / "hotdog-mbn.c"),
                str(SOURCE / "hotdog-pdc.c"), str(SOURCE / "hotdog-mcfg.c"),
                str(source), *flags, "-o", str(cls.binary),
            ],
            check=True,
        )

    @classmethod
    def tearDownClass(cls) -> None:
        cls._temporary.cleanup()

    def run_open(self, root: Path, relative: str, digest: str) -> str:
        return subprocess.run(
            [str(self.binary), str(root), relative, digest],
            check=True, capture_output=True, text=True,
        ).stdout.strip()

    def test_exact_profile_reopens_by_sha1(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "generic/eu/test/mcfg_sw.mbn"
            payload = profile(path, "SECURE", 123456, 1)
            self.assertEqual(
                self.run_open(root, "generic/eu/test/mcfg_sw.mbn", hashlib.sha1(payload).hexdigest()),
                f"result=0 size={len(payload)}",
            )

    def test_changed_profile_is_stale(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "generic/eu/test/mcfg_sw.mbn"
            payload = profile(path, "SECURE", 123456, 1)
            digest = hashlib.sha1(payload).hexdigest()
            path.write_bytes(payload + b"changed")
            self.assertEqual(
                self.run_open(root, "generic/eu/test/mcfg_sw.mbn", digest),
                "result=-116 size=0",
            )

    def test_intermediate_symlink_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "root"
            outside = Path(directory) / "outside"
            root.mkdir()
            payload = profile(outside / "test/mcfg_sw.mbn", "SECURE", 123456, 1)
            (root / "generic").symlink_to(outside, target_is_directory=True)
            output = self.run_open(
                root, "generic/test/mcfg_sw.mbn", hashlib.sha1(payload).hexdigest(),
            )
            self.assertRegex(output, r"result=-(20|40) size=0")

    def test_private_catalog_counts_when_available(self) -> None:
        archive = ROOT / "aports/device/testing/firmware-oneplus-hotdog-modem-oos10/mcfg-oos10.0.13.tar.gz"
        if not archive.is_file():
            self.skipTest("private OOS10 MCFG archive is not staged")
        source = r'''#include "hotdog-mcfg.h"
#include <stdio.h>
int main(int argc, char **argv) { size_t p,s,f; int r=hotdog_mcfg_tree_counts(argv[1],&p,&s,&f); (void)argc; printf("r=%d p=%zu s=%zu f=%zu\n",r,p,s,f); }
'''
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(["tar", "-xzf", str(archive), "-C", str(root)], check=True)
            cfile = root / "counts.c"
            binary = root / "counts"
            cfile.write_text(source)
            flags = subprocess.run(["pkg-config", "--cflags", "--libs", "glib-2.0"],
                                   check=True, capture_output=True, text=True).stdout.split()
            subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2",
                            "-I", str(SOURCE), str(SOURCE / "hotdog-mbn.c"),
                            str(SOURCE / "hotdog-pdc.c"), str(SOURCE / "hotdog-mcfg.c"),
                            str(cfile), *flags, "-o", str(binary)], check=True)
            output = subprocess.run([str(binary), str(root / "mcfg_sw")], check=True,
                                    capture_output=True, text=True).stdout.strip()
            self.assertEqual(output, "r=0 p=69 s=69 f=143")


if __name__ == "__main__":
    unittest.main()
