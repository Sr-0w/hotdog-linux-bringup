from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]
SOURCE = ROOT / "helpers" / "hotdog-radio"


HARNESS = r'''#include "hotdog-qmi-imsa.h"
#include <stdio.h>
int main(void) { QmiMessageImsaBindInput *b=NULL; QmiMessageImsaRegisterIndicationsInput *r=NULL;
 guint32 sub=99; gboolean reg=FALSE,svc=FALSE;
 struct hotdog_ims_state state={0}; int malformed;
 if(hotdog_qmi_imsa_bind_input(2,&b)||hotdog_qmi_imsa_register_input(&r)) return 1;
 qmi_message_imsa_bind_input_get_binding(b,&sub,NULL);
 qmi_message_imsa_register_indications_input_get_ims_registration_status_changed(r,&reg,NULL);
 qmi_message_imsa_register_indications_input_get_ims_services_status_changed(r,&svc,NULL);
 if(hotdog_qmi_imsa_update_registration(QMI_IMSA_IMS_REGISTERED,true,
    QMI_IMSA_REGISTERED_WWAN,0,&state)) return 2;
 if(hotdog_qmi_imsa_update_services(true,QMI_IMSA_SERVICE_AVAILABLE,false,0,
    true,QMI_IMSA_SERVICE_LIMITED,true,QMI_IMSA_REGISTERED_WLAN,
    true,QMI_IMSA_SERVICE_UNAVAILABLE,false,0,&state)) return 3;
 printf("sub=%u registration=%u services=%u state=%u/%u caps=%u limited=%u rats=%u/%u/%u\n",
    sub,reg,svc,state.registration,state.rat,state.capabilities,
    state.limited_capabilities,state.voice_rat,state.video_rat,state.sms_rat);
 if(hotdog_qmi_imsa_update_services(false,0,false,0,false,0,false,0,
    true,QMI_IMSA_SERVICE_AVAILABLE,true,QMI_IMSA_REGISTERED_WLAN,&state)) return 4;
 malformed=hotdog_qmi_imsa_update_services(true,(QmiImsaServiceStatus)99,false,0,
    false,0,false,0,false,0,false,0,&state);
 printf("partial=%u/%u/%u malformed=%d\n",state.capabilities,
    state.limited_capabilities,state.sms_rat,malformed);
 qmi_message_imsa_bind_input_unref(b); qmi_message_imsa_register_indications_input_unref(r); }
'''


class HotdogQmiImsaTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        flags = subprocess.run(["pkg-config", "--cflags", "--libs", "qmi-glib", "glib-2.0"],
                               check=True, capture_output=True, text=True).stdout.split()
        cls._temporary = tempfile.TemporaryDirectory()
        source = Path(cls._temporary.name) / "imsa.c"
        cls.binary = Path(cls._temporary.name) / "imsa"
        source.write_text(HARNESS)
        subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2",
                        "-I", str(SOURCE), str(SOURCE / "hotdog-qmi-imsa.c"),
                        str(source), *flags, "-o", str(cls.binary)], check=True)

    @classmethod
    def tearDownClass(cls) -> None:
        cls._temporary.cleanup()

    def test_subscription_bind_and_indication_registration(self) -> None:
        output = subprocess.run([str(self.binary)], check=True,
                                capture_output=True, text=True).stdout.strip()
        self.assertEqual(
            output,
            "sub=2 registration=1 services=1 state=2/1 caps=1 limited=2 rats=1/2/0\n"
            "partial=5/2/2 malformed=-71",
        )

    def test_only_proven_base_capabilities_are_mapped(self) -> None:
        source = (SOURCE / "hotdog-qmi-imsa.c").read_text()
        self.assertIn("HOTDOG_IMS_CAP_VOICE", source)
        self.assertIn("HOTDOG_IMS_CAP_VIDEO", source)
        self.assertIn("HOTDOG_IMS_CAP_SMS", source)
        self.assertNotIn("HOTDOG_IMS_CAP_UT", source)
        self.assertNotIn("HOTDOG_IMS_CAP_RCS", source)

    def test_indications_preserve_partial_service_updates(self) -> None:
        source = (SOURCE / "hotdog-qmi-imsa.c").read_text()
        self.assertIn("decode_registration_indication", source)
        self.assertIn("decode_services_indication", source)
        self.assertIn("candidate = *state", source)
        self.assertIn("limited_capabilities", source)


if __name__ == "__main__":
    unittest.main()
