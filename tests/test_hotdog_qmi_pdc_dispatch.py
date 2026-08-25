from __future__ import annotations

import hashlib
import subprocess
import tempfile
import unittest
from pathlib import Path

from tests.test_hotdog_mcfg import profile


ROOT = Path(__file__).parents[1]
SOURCE = ROOT / "helpers" / "hotdog-radio"


HARNESS = r'''#include "hotdog-qmi-pdc-dispatch.h"
#include <stdio.h>
#include <string.h>
gboolean qmi_message_pdc_get_selected_config_input_set_subscription_id(
    QmiMessagePdcGetSelectedConfigInput *x, guint32 y, GError **e) { (void)x;(void)y;(void)e;return TRUE; }
gboolean qmi_message_pdc_set_selected_config_input_set_subscription_id(
    QmiMessagePdcSetSelectedConfigInput *x, guint32 y, GError **e) { (void)x;(void)y;(void)e;return TRUE; }
gboolean qmi_message_pdc_activate_config_input_set_subscription_id(
    QmiMessagePdcActivateConfigInput *x, guint32 y, GError **e) { (void)x;(void)y;(void)e;return TRUE; }
gboolean qmi_message_pdc_deactivate_config_input_set_subscription_id(
    QmiMessagePdcDeactivateConfigInput *x, guint32 y, GError **e) { (void)x;(void)y;(void)e;return TRUE; }
static int hex_id(const char *text, struct hotdog_pdc_id *id) {
    unsigned int value; size_t i;
    if (strlen(text) != 40) return -1;
    for (i=0;i<20;i++) { if (sscanf(text+i*2,"%2x",&value)!=1) return -1; id->value[i]=value; }
    id->length=20; return 0;
}
int main(int argc, char **argv) {
    struct hotdog_pdc_catalog catalog = { .count = 1 };
    struct hotdog_pdc_operation operation = { .type = HOTDOG_PDC_LOAD_CONFIG };
    struct hotdog_qmi_pdc_request request;
    QmiPdcConfigurationType type; GArray *id=NULL,*chunk=NULL; guint32 total=0;
    int result;
    (void)argc;
    if (hex_id(argv[3], &catalog.configs[0].id)) return 2;
    operation.id = catalog.configs[0].id;
    memcpy(catalog.configs[0].path, argv[2], strlen(argv[2])+1);
    result = hotdog_qmi_pdc_request_prepare(&request, &operation, &catalog, argv[1], 7);
    if (result) { printf("prepare=%d\n",result); return 0; }
    if (!qmi_message_pdc_load_config_input_get_config_chunk(request.input.load,
            &type,&id,&total,&chunk,NULL)) return 3;
    printf("type=%d id=%u total=%u chunk=%u state=%u\n", type,id->len,total,chunk->len,
           request.load_state.awaiting);
    hotdog_qmi_pdc_request_clear(&request);
    return 0;
}
'''


class HotdogQmiPdcDispatchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        flags = subprocess.run(
            ["pkg-config", "--cflags", "--libs", "qmi-glib", "glib-2.0"],
            check=True, capture_output=True, text=True,
        ).stdout.split()
        cls._temporary = tempfile.TemporaryDirectory()
        source = Path(cls._temporary.name) / "dispatch.c"
        cls.binary = Path(cls._temporary.name) / "dispatch"
        source.write_text(HARNESS)
        subprocess.run(
            [
                "cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2",
                "-I", str(SOURCE), str(SOURCE / "hotdog-mbn.c"),
                str(SOURCE / "hotdog-pdc.c"), str(SOURCE / "hotdog-pdc-load.c"),
                str(SOURCE / "hotdog-mcfg.c"), str(SOURCE / "hotdog-qmi-pdc.c"),
                str(SOURCE / "hotdog-qmi-pdc-load.c"),
                str(SOURCE / "hotdog-qmi-pdc-dispatch.c"), str(source),
                *flags, "-o", str(cls.binary),
            ],
            check=True,
        )

    @classmethod
    def tearDownClass(cls) -> None:
        cls._temporary.cleanup()

    def test_load_operation_reopens_and_builds_first_chunk(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            relative = "generic/eu/test/mcfg_sw.mbn"
            payload = profile(root / relative, "DISPATCH", 123456, 1)
            result = subprocess.run(
                [str(self.binary), str(root), relative, hashlib.sha1(payload).hexdigest()],
                check=True, capture_output=True, text=True,
            )
            self.assertEqual(
                result.stdout.strip(),
                f"type=1 id=20 total={len(payload)} chunk={len(payload)} state=1",
            )

    def test_changed_file_is_rejected_before_request(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            relative = "generic/eu/test/mcfg_sw.mbn"
            payload = profile(root / relative, "DISPATCH", 123456, 1)
            digest = hashlib.sha1(payload).hexdigest()
            (root / relative).write_bytes(payload + b"changed")
            result = subprocess.run(
                [str(self.binary), str(root), relative, digest],
                check=True, capture_output=True, text=True,
            )
            self.assertEqual(result.stdout.strip(), "prepare=-116")


if __name__ == "__main__":
    unittest.main()
