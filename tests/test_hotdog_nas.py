from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]
SOURCE = ROOT / "helpers" / "hotdog-radio"


class HotdogNasTests(unittest.TestCase):
    def test_adapter_compiles_and_names_states(self) -> None:
        flags = subprocess.run(
            ["pkg-config", "--cflags", "--libs", "qmi-glib", "glib-2.0"],
            capture_output=True, text=True,
        )
        if flags.returncode:
            self.skipTest("libqmi development files are unavailable")
        harness = r'''#include "hotdog-qmi-nas.h"
#include <stdio.h>
int main(void) {
    printf("registration=%s cs=%s network=%s\n",
           hotdog_qmi_nas_registration_name(QMI_NAS_REGISTRATION_STATE_NOT_REGISTERED),
           hotdog_qmi_nas_attach_name(QMI_NAS_ATTACH_STATE_DETACHED),
           hotdog_qmi_nas_network_name(QMI_NAS_NETWORK_TYPE_UNKNOWN));
    return 0;
}
'''
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "nas-harness.c"
            binary = Path(directory) / "nas-harness"
            source.write_text(harness)
            subprocess.run(
                [
                    "cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2",
                    "-I", str(SOURCE), str(SOURCE / "hotdog-qmi-nas.c"),
                    str(source), *flags.stdout.split(), "-o", str(binary),
                ],
                check=True,
            )
            result = subprocess.run([str(binary)], check=True, capture_output=True, text=True)
            self.assertIn("registration=not-registered", result.stdout)
            self.assertIn("cs=detached", result.stdout)
            self.assertIn("network=unknown", result.stdout)


if __name__ == "__main__":
    unittest.main()
