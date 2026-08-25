from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]
SOURCE = ROOT / "helpers" / "hotdog-radio"


class HotdogQmiPdcListTests(unittest.TestCase):
    def test_software_list_input_fields(self) -> None:
        flags = subprocess.run(
            ["pkg-config", "--cflags", "--libs", "qmi-glib", "glib-2.0"],
            capture_output=True, text=True,
        )
        if flags.returncode:
            self.skipTest("libqmi development files are unavailable")
        harness = r'''#include "hotdog-qmi-pdc-list.h"
#include <stdio.h>
int main(void) {
    QmiMessagePdcListConfigsInput *input = NULL;
    struct hotdog_pdc_catalog catalog = { .count = 2 };
    struct hotdog_pdc_id loaded[2] = { 0 };
    QmiPdcConfigurationType type;
    guint32 token;
    if (hotdog_qmi_pdc_list_input(77, &input)) return 1;
    if (!qmi_message_pdc_list_configs_input_get_token(input, &token, NULL) || token != 77) return 2;
    if (!qmi_message_pdc_list_configs_input_get_config_type(input, &type, NULL) ||
        type != QMI_PDC_CONFIGURATION_TYPE_SOFTWARE) return 3;
    qmi_message_pdc_list_configs_input_unref(input);
    catalog.configs[0].id.length = catalog.configs[1].id.length = 1;
    catalog.configs[0].id.value[0] = 1;
    catalog.configs[1].id.value[0] = 2;
    loaded[0] = catalog.configs[1].id;
    loaded[1].length = 1;
    loaded[1].value[0] = 3;
    if (hotdog_pdc_mark_loaded(&catalog, loaded, 2) != 1) return 4;
    if (catalog.configs[0].loaded || !catalog.configs[1].loaded) return 5;
    puts("pdc-list-input=software token=77");
    return 0;
}
'''
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "pdc-list-harness.c"
            binary = Path(directory) / "pdc-list-harness"
            source.write_text(harness)
            subprocess.run(
                [
                    "cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2",
                    "-I", str(SOURCE), str(SOURCE / "hotdog-pdc.c"),
                    str(SOURCE / "hotdog-mbn.c"), str(SOURCE / "hotdog-qmi-pdc-list.c"),
                    str(source), *flags.stdout.split(), "-o", str(binary),
                ],
                check=True,
            )
            result = subprocess.run([str(binary)], check=True, capture_output=True, text=True)
            self.assertEqual(result.stdout.strip(), "pdc-list-input=software token=77")


if __name__ == "__main__":
    unittest.main()
