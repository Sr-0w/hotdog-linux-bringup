from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]
SOURCE = ROOT / "helpers" / "hotdog-radio"


HARNESS = r'''#include "hotdog-qmi-wms.h"
#include <stdio.h>
int main(void) {
    unsigned char pdu[4]={1,2,3,4}; GArray *raw=NULL; QmiWmsMessageFormat format;
    gboolean ims=FALSE; QmiMessageWmsRawSendInput *input=NULL;
    struct hotdog_sms message={.pdu_bytes=4,.transport=HOTDOG_TRANSPORT_IMS,
        .direction=HOTDOG_SMS_MO,.state=HOTDOG_SMS_QUEUED};
    if(hotdog_qmi_wms_raw_send_input(&message,pdu,sizeof(pdu),&input)) return 1;
    if(!qmi_message_wms_raw_send_input_get_raw_message_data(input,&format,&raw,NULL)) return 2;
    if(!qmi_message_wms_raw_send_input_get_sms_on_ims(input,&ims,NULL)) return 3;
    printf("format=%u bytes=%u ims=%u first=%u\n",format,raw->len,ims,
           g_array_index(raw,guint8,0));
    qmi_message_wms_raw_send_input_unref(input); return 0;
}
'''


class HotdogQmiWmsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        flags = subprocess.run(["pkg-config", "--cflags", "--libs", "qmi-glib", "glib-2.0"],
                               check=True, capture_output=True, text=True).stdout.split()
        cls._temporary = tempfile.TemporaryDirectory()
        source = Path(cls._temporary.name) / "wms.c"
        cls.binary = Path(cls._temporary.name) / "wms"
        source.write_text(HARNESS)
        subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2",
                        "-I", str(SOURCE), str(SOURCE / "hotdog-qmi-wms.c"),
                        str(source), *flags, "-o", str(cls.binary)], check=True)

    @classmethod
    def tearDownClass(cls) -> None:
        cls._temporary.cleanup()

    def test_ims_tpdu_is_preserved_without_decoding(self) -> None:
        output = subprocess.run([str(self.binary)], check=True,
                                capture_output=True, text=True).stdout.strip()
        self.assertEqual(output, "format=6 bytes=4 ims=1 first=1")

    def test_transport_never_logs_pdu_or_credentials(self) -> None:
        source = (SOURCE / "hotdog-qmi-wms.c").read_text()
        self.assertNotIn("printf", source)
        self.assertNotIn("g_print", source)


if __name__ == "__main__":
    unittest.main()
