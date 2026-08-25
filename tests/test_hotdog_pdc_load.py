from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]
SOURCE = ROOT / "helpers" / "hotdog-radio"
ID = "00112233445566778899aabbccddeeff00112233"


class HotdogPdcLoadTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls._temporary = tempfile.TemporaryDirectory()
        cls.binary = Path(cls._temporary.name) / "hotdog-pdc-load-replay"
        subprocess.run(
            [
                "cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2",
                "-I", str(SOURCE), str(SOURCE / "hotdog-pdc-load.c"),
                str(SOURCE / "hotdog-pdc-load-replay.c"), "-o", str(cls.binary),
            ],
            check=True,
        )

    @classmethod
    def tearDownClass(cls) -> None:
        cls._temporary.cleanup()

    def replay(self, content: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run([str(self.binary)], input=content, text=True, capture_output=True)

    def test_chunks_are_bounded_and_exactly_acknowledged(self) -> None:
        result = self.replay(
            f"INIT 2050 {ID}\n"
            "NEXT 1\nACK 1 0 0 1026\n"
            "NEXT 2\nACK 2 0 0 2\n"
            "NEXT 3\nACK 3 0 0 0\nSTATE\nNEXT 4\n"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("next=0 token:1 offset:0 size:1024", result.stdout)
        self.assertIn("next=0 token:2 offset:1024 size:1024", result.stdout)
        self.assertIn("next=0 token:3 offset:2048 size:2", result.stdout)
        self.assertIn("state=offset:2050 total:2050 awaiting:0 complete:1 cleanup:0", result.stdout)
        self.assertIn("next=-114 token:4", result.stdout)

    def test_stale_token_does_not_advance_state(self) -> None:
        result = self.replay(
            f"INIT 1025 {ID}\nNEXT 7\nACK 6 0 0 1\nSTATE\nACK 7 0 0 1\nSTATE\n"
        )
        self.assertIn("ack=-116 token:6", result.stdout)
        self.assertIn("state=offset:0 total:1025 awaiting:1 complete:0 cleanup:0", result.stdout)
        self.assertIn("state=offset:1024 total:1025 awaiting:0 complete:0 cleanup:0", result.stdout)

    def test_bad_progress_requires_cleanup(self) -> None:
        result = self.replay(f"INIT 2048 {ID}\nNEXT 1\nACK 1 0 0 999\nSTATE\n")
        self.assertIn("ack=-71", result.stdout)
        self.assertIn("cleanup:1", result.stdout)

    def test_remote_error_and_frame_reset_require_cleanup(self) -> None:
        remote = self.replay(f"INIT 10 {ID}\nNEXT 1\nACK 1 94 0 0\nSTATE\n")
        self.assertIn("ack=-121", remote.stdout)
        self.assertIn("cleanup:1", remote.stdout)
        reset = self.replay(f"INIT 10 {ID}\nNEXT 1\nACK 1 0 1 0\nSTATE\n")
        self.assertIn("ack=-32", reset.stdout)
        self.assertIn("cleanup:1", reset.stdout)

    def test_abort_after_send_requires_cleanup(self) -> None:
        result = self.replay(f"INIT 10 {ID}\nNEXT 1\nABORT\nSTATE\n")
        self.assertIn("state=offset:0 total:10 awaiting:0 complete:0 cleanup:1", result.stdout)


class HotdogQmiPdcLoadBuildTests(unittest.TestCase):
    def test_load_and_delete_adapter_fields(self) -> None:
        flags = subprocess.run(
            ["pkg-config", "--cflags", "--libs", "qmi-glib", "glib-2.0"],
            capture_output=True, text=True,
        )
        if flags.returncode:
            self.skipTest("libqmi development files are unavailable")
        harness = r'''#include "hotdog-qmi-pdc-load.h"
#include <stdio.h>
int main(void) {
    struct hotdog_pdc_id id = { .length = HOTDOG_PDC_ID_SIZE };
    unsigned char chunk[3] = { 1, 2, 3 };
    QmiMessagePdcLoadConfigInput *load = NULL;
    QmiMessagePdcDeleteConfigInput *del = NULL;
    QmiPdcConfigurationType type;
    GArray *got_id = NULL, *got_chunk = NULL;
    guint32 total = 0, token = 0;
    unsigned int i;
    for (i = 0; i < HOTDOG_PDC_ID_SIZE; i++) id.value[i] = i;
    if (hotdog_qmi_pdc_load_input(9, &id, 7, chunk, sizeof(chunk), &load)) return 1;
    if (!qmi_message_pdc_load_config_input_get_token(load, &token, NULL) || token != 9) return 2;
    if (!qmi_message_pdc_load_config_input_get_config_chunk(load, &type, &got_id,
                                                             &total, &got_chunk, NULL)) return 3;
    if (type != QMI_PDC_CONFIGURATION_TYPE_SOFTWARE || total != 7 ||
        got_id->len != HOTDOG_PDC_ID_SIZE || got_chunk->len != sizeof(chunk)) return 4;
    qmi_message_pdc_load_config_input_unref(load);
    if (hotdog_qmi_pdc_delete_input(10, &id, &del)) return 5;
    if (!qmi_message_pdc_delete_config_input_get_token(del, &token, NULL) || token != 10) return 6;
    if (!qmi_message_pdc_delete_config_input_get_id(del, &got_id, NULL) ||
        got_id->len != HOTDOG_PDC_ID_SIZE) return 7;
    if (!qmi_message_pdc_delete_config_input_get_config_type(del, &type, NULL) ||
        type != QMI_PDC_CONFIGURATION_TYPE_SOFTWARE) return 8;
    qmi_message_pdc_delete_config_input_unref(del);
    puts("qmi-load-fields=ok qmi-delete-fields=ok");
    return 0;
}
'''
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "qmi-load-harness.c"
            binary = Path(directory) / "qmi-load-harness"
            source.write_text(harness)
            subprocess.run(
                [
                    "cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2",
                    "-I", str(SOURCE), str(SOURCE / "hotdog-pdc-load.c"),
                    str(SOURCE / "hotdog-qmi-pdc-load.c"), str(source),
                    *flags.stdout.split(), "-o", str(binary),
                ],
                check=True,
            )
            result = subprocess.run([str(binary)], check=True, capture_output=True, text=True)
            self.assertEqual(result.stdout.strip(), "qmi-load-fields=ok qmi-delete-fields=ok")


if __name__ == "__main__":
    unittest.main()
