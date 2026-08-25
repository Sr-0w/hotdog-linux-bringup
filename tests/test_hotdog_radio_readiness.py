from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]
SOURCE = ROOT / "helpers" / "hotdog-radio"


HARNESS = r'''#include "hotdog-radio-readiness.h"
#include <stdio.h>
#include <string.h>
static void id(struct hotdog_pdc_id *id) { size_t i; id->length=20; for(i=0;i<20;i++) id->value[i]=i; }
int main(int argc, char **argv) {
    struct hotdog_radio_readiness r = { .phase=HOTDOG_READINESS_LOCKED, .dms_online=true };
    int result; (void)argc;
    strcpy(r.boot_id,"01234567-89ab-cdef-0123-456789abcdef");
    memset(r.modem_sha256,'a',64); r.modem_sha256[64]=0;
    memset(r.mcfg_sha256,'b',64); r.mcfg_sha256[64]=0;
    r.subscriptions[0].populated=true; r.subscriptions[0].physical_slot=1;
    r.subscriptions[0].app_state=HOTDOG_UIM_APP_PIN_REQUIRED;
    r.subscriptions[0].retries.pin1=3; r.subscriptions[0].retries.puk1=10;
    id(&r.subscriptions[0].selected); r.subscriptions[0].active=r.subscriptions[0].selected;
    if (!strcmp(argv[2],"pending")) id(&r.subscriptions[0].pending);
    if (!strcmp(argv[2],"offline")) r.dms_online=false;
    if (!strcmp(argv[2],"wrong-phase")) r.phase=HOTDOG_READINESS_READY;
    result=hotdog_radio_readiness_write(argv[1],&r); printf("result=%d\n",result); return 0;
}
'''


class HotdogRadioReadinessTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls._temporary = tempfile.TemporaryDirectory()
        source = Path(cls._temporary.name) / "readiness.c"
        cls.binary = Path(cls._temporary.name) / "readiness"
        source.write_text(HARNESS)
        subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2",
                        "-I", str(SOURCE), str(SOURCE / "hotdog-mbn.c"),
                        str(SOURCE / "hotdog-pdc.c"), str(SOURCE / "hotdog-uim.c"),
                        str(SOURCE / "hotdog-radio-readiness.c"), str(source),
                        "-o", str(cls.binary)], check=True)

    @classmethod
    def tearDownClass(cls) -> None:
        cls._temporary.cleanup()

    def run_case(self, case: str) -> tuple[str, str]:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "readiness"
            result = subprocess.run([str(self.binary), str(path), case], check=True,
                                    capture_output=True, text=True).stdout.strip()
            return result, path.read_text() if path.exists() else ""

    def test_locked_record_is_written_atomically(self) -> None:
        result, content = self.run_case("valid")
        self.assertEqual(result, "result=0")
        self.assertIn("schema=2\n", content)
        self.assertIn("phase=locked\n", content)
        self.assertIn("sub0-pin1-retries=3\n", content)
        self.assertIn("sub0-pending=-\n", content)
        self.assertNotIn("iccid", content.lower())

    def test_pending_offline_and_wrong_phase_are_rejected(self) -> None:
        for case in ("pending", "offline", "wrong-phase"):
            result, content = self.run_case(case)
            self.assertNotEqual(result, "result=0")
            self.assertEqual(content, "")


if __name__ == "__main__":
    unittest.main()
