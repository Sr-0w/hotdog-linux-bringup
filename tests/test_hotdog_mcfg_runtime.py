from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]
SOURCE = ROOT / "helpers" / "hotdog-radio"
MANIFEST = (
    "schema=1\nsource-sha256=" + "a" * 64 + "\n"
    "mpss-build=PUBLIC_MPSS_BUILD\nmodem-sha256=" + "b" * 64 + "\n"
    "mcfg-archive-sha256=" + "c" * 64 + "\n"
    "profile-count=69\nsignature-count=69\ncatalog-file-count=143\n"
)


class HotdogMcfgRuntimeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls._temporary = tempfile.TemporaryDirectory()
        source = Path(cls._temporary.name) / "runtime.c"
        cls.binary = Path(cls._temporary.name) / "runtime"
        source.write_text(r'''#include "hotdog-mcfg-runtime.h"
#include <stdio.h>
int main(int argc, char **argv) {
    struct hotdog_mcfg_runtime runtime;
    int result = hotdog_mcfg_runtime_read(argv[1], &runtime);
    (void)argc;
    printf("result=%d profiles=%zu signatures=%zu files=%zu build=%s\n", result,
           runtime.profile_count, runtime.signature_count, runtime.catalog_file_count,
           runtime.mpss_build);
    return 0;
}
''')
        subprocess.run(
            ["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2",
             "-I", str(SOURCE), str(SOURCE / "hotdog-mcfg-runtime.c"),
             str(source), "-o", str(cls.binary)], check=True,
        )

    @classmethod
    def tearDownClass(cls) -> None:
        cls._temporary.cleanup()

    def run_manifest(self, content: str, mode: int = 0o644) -> str:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "MANIFEST"
            path.write_text(content)
            path.chmod(mode)
            return subprocess.run([str(self.binary), str(path)], check=True,
                                  capture_output=True, text=True).stdout.strip()

    def test_exact_runtime_manifest(self) -> None:
        self.assertEqual(self.run_manifest(MANIFEST),
                         "result=0 profiles=69 signatures=69 files=143 build=PUBLIC_MPSS_BUILD")

    def test_unknown_duplicate_missing_and_bad_counts_fail(self) -> None:
        self.assertTrue(self.run_manifest(MANIFEST + "unknown=x\n").startswith("result=-22"))
        self.assertTrue(self.run_manifest(MANIFEST + "schema=1\n").startswith("result=-22"))
        self.assertTrue(self.run_manifest(MANIFEST.replace("profile-count=69\n", "")).startswith("result=-61"))
        self.assertTrue(self.run_manifest(MANIFEST.replace("profile-count=69", "profile-count=0")).startswith("result=-22"))

    def test_group_writable_manifest_is_rejected(self) -> None:
        self.assertTrue(self.run_manifest(MANIFEST, 0o664).startswith("result=-1"))

    def test_symlink_manifest_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "target"
            link = Path(directory) / "MANIFEST"
            target.write_text(MANIFEST)
            link.symlink_to(target)
            output = subprocess.run([str(self.binary), str(link)], check=True,
                                    capture_output=True, text=True).stdout
            self.assertTrue(output.startswith("result=-40"))


if __name__ == "__main__":
    unittest.main()
