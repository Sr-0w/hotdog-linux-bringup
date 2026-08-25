from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]
SOURCE = ROOT / "helpers" / "hotdog-radio"


class HotdogDmsTests(unittest.TestCase):
    def test_online_input_and_mode_names(self) -> None:
        flags = subprocess.run(
            ["pkg-config", "--cflags", "--libs", "qmi-glib", "glib-2.0"],
            capture_output=True, text=True,
        )
        if flags.returncode:
            self.skipTest("libqmi development files are unavailable")
        harness = r'''#include "hotdog-qmi-dms.h"
#include <stdio.h>
int main(void) {
    QmiMessageDmsSetOperatingModeInput *input = NULL;
    QmiDmsOperatingMode mode = QMI_DMS_OPERATING_MODE_UNKNOWN;
    if (hotdog_qmi_dms_set_online_input(&input)) return 1;
    if (!qmi_message_dms_set_operating_mode_input_get_mode(input, &mode, NULL)) return 2;
    if (mode != QMI_DMS_OPERATING_MODE_ONLINE) return 3;
    qmi_message_dms_set_operating_mode_input_unref(input);
    printf("online=%s offline=%s low=%s\n",
           hotdog_qmi_dms_mode_name(QMI_DMS_OPERATING_MODE_ONLINE),
           hotdog_qmi_dms_mode_name(QMI_DMS_OPERATING_MODE_OFFLINE),
           hotdog_qmi_dms_mode_name(QMI_DMS_OPERATING_MODE_LOW_POWER));
    return 0;
}
'''
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "dms-harness.c"
            binary = Path(directory) / "dms-harness"
            source.write_text(harness)
            subprocess.run(
                [
                    "cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2",
                    "-I", str(SOURCE), str(SOURCE / "hotdog-qmi-dms.c"),
                    str(source), *flags.stdout.split(), "-o", str(binary),
                ],
                check=True,
            )
            result = subprocess.run([str(binary)], check=True, capture_output=True, text=True)
            self.assertEqual(result.stdout.strip(), "online=online offline=offline low=low-power")


if __name__ == "__main__":
    unittest.main()
