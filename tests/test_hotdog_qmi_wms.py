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
    unsigned char report[21]={0,2,77,2,0x91,0x21}; enum hotdog_wms_mt_kind kind;
    guint8 reference=0,status=0;
    gboolean ims=FALSE; QmiMessageWmsRawSendInput *input=NULL;
    struct hotdog_sms message={.pdu_bytes=4,.transport=HOTDOG_TRANSPORT_IMS,
        .direction=HOTDOG_SMS_MO,.state=HOTDOG_SMS_QUEUED};
    if(hotdog_qmi_wms_raw_send_input(&message,pdu,sizeof(pdu),&input)) return 1;
    if(!qmi_message_wms_raw_send_input_get_raw_message_data(input,&format,&raw,NULL)) return 2;
    if(!qmi_message_wms_raw_send_input_get_sms_on_ims(input,&ims,NULL)) return 3;
    if(hotdog_wms_classify_3gpp(report,sizeof(report),&kind,&reference,&status)) return 4;
    printf("format=%u bytes=%u ims=%u first=%u report=%u/%u/%u\n",format,raw->len,ims,
           g_array_index(raw,guint8,0),kind,reference,status);
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
        self.assertEqual(output, "format=6 bytes=4 ims=1 first=1 report=1/77/0")

    def test_3gpp_classifier_rejects_reserved_and_truncated_reports(self) -> None:
        flags = subprocess.run(["pkg-config", "--cflags", "--libs", "qmi-glib", "glib-2.0"],
                               check=True, capture_output=True, text=True).stdout.split()
        source = r'''#include "hotdog-qmi-wms.h"
#include <stdio.h>
int main(void) { unsigned char deliver[]={0,0},reserved[]={0,3},short_report[]={0,2,1};
 enum hotdog_wms_mt_kind k; guint8 r,s;
 printf("deliver=%d reserved=%d short=%d\n",
  hotdog_wms_classify_3gpp(deliver,sizeof(deliver),&k,&r,&s),
  hotdog_wms_classify_3gpp(reserved,sizeof(reserved),&k,&r,&s),
  hotdog_wms_classify_3gpp(short_report,sizeof(short_report),&k,&r,&s)); }
'''
        with tempfile.TemporaryDirectory() as directory:
            cfile = Path(directory) / "classify.c"
            binary = Path(directory) / "classify"
            cfile.write_text(source)
            subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2",
                            "-I", str(SOURCE), str(SOURCE / "hotdog-qmi-wms.c"),
                            str(cfile), *flags, "-o", str(binary)], check=True)
            output = subprocess.run([str(binary)], check=True, capture_output=True,
                                    text=True).stdout.strip()
            self.assertEqual(output, "deliver=0 reserved=-95 short=-71")

    def test_transport_never_logs_pdu_or_credentials(self) -> None:
        source = (SOURCE / "hotdog-qmi-wms.c").read_text()
        self.assertNotIn("printf", source)
        self.assertNotIn("g_print", source)

    def test_ack_preserves_transaction_protocol_and_domain(self) -> None:
        flags = subprocess.run(["pkg-config", "--cflags", "--libs", "qmi-glib", "glib-2.0"],
                               check=True, capture_output=True, text=True).stdout.split()
        source = r'''#include "hotdog-qmi-wms.h"
#include <stdio.h>
int main(void) { struct hotdog_wms_incoming m={.transaction_id=42,.transport=HOTDOG_TRANSPORT_IMS,.ack_required=true};
 QmiMessageWmsSendAckInput *i=NULL; guint32 tx=0; QmiWmsMessageProtocol p; gboolean ok=FALSE,ims=FALSE;
 if(hotdog_qmi_wms_ack_input(&m,true,0,0,&i)) return 1;
 qmi_message_wms_send_ack_input_get_information(i,&tx,&p,&ok,NULL);
 qmi_message_wms_send_ack_input_get_sms_on_ims(i,&ims,NULL);
 printf("tx=%u protocol=%u success=%u ims=%u\n",tx,p,ok,ims);
 qmi_message_wms_send_ack_input_unref(i); }
'''
        with tempfile.TemporaryDirectory() as directory:
            cfile = Path(directory) / "ack.c"
            binary = Path(directory) / "ack"
            cfile.write_text(source)
            subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2",
                            "-I", str(SOURCE), str(SOURCE / "hotdog-qmi-wms.c"),
                            str(cfile), *flags, "-o", str(binary)], check=True)
            output = subprocess.run([str(binary)], check=True,
                                    capture_output=True, text=True).stdout.strip()
            self.assertEqual(output, "tx=42 protocol=1 success=1 ims=1")


if __name__ == "__main__":
    unittest.main()
