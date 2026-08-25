from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]
SOURCE = ROOT / "helpers" / "hotdog-radio"


HARNESS = r'''#include "hotdog-qmi-wds.h"
#include <stdio.h>
#include <string.h>
int main(void) {
    struct hotdog_bearer b = { .profile=7,.mux_id=3,.family=HOTDOG_IP_V4V6,
        .auth=HOTDOG_AUTH_PAP_CHAP,.state=HOTDOG_BEARER_STARTING };
    struct hotdog_wds_credentials c = { "user", "pass" };
    struct hotdog_qmi_wds_plan p;
    QmiMessageWdsGetCurrentSettingsInput *settings = NULL;
    QmiWdsRequestedSettings requested = QMI_WDS_REQUESTED_SETTINGS_NONE;
    size_t i; strcpy(b.apn,"internet");
    if (hotdog_qmi_wds_plan_build(&b,&c,QMI_DATA_ENDPOINT_TYPE_EMBEDDED,4,
                                  QMI_WDS_CLIENT_TYPE_TETHERED,&p)) return 1;
    printf("legs=%zu\n",p.count);
    for(i=0;i<p.count;i++) { QmiWdsIpFamily f; guint8 mux,profile; guint32 iface;
        QmiDataEndpointType ep; const gchar *apn,*user,*pass; QmiWdsAuthentication auth;
        qmi_message_wds_bind_mux_data_port_input_get_endpoint_info(p.legs[i].bind,&ep,&iface,NULL);
        qmi_message_wds_bind_mux_data_port_input_get_mux_id(p.legs[i].bind,&mux,NULL);
        qmi_message_wds_start_network_input_get_ip_family_preference(p.legs[i].start,&f,NULL);
        qmi_message_wds_start_network_input_get_profile_index_3gpp(p.legs[i].start,&profile,NULL);
        qmi_message_wds_start_network_input_get_apn(p.legs[i].start,&apn,NULL);
        qmi_message_wds_start_network_input_get_username(p.legs[i].start,&user,NULL);
        qmi_message_wds_start_network_input_get_password(p.legs[i].start,&pass,NULL);
        qmi_message_wds_start_network_input_get_authentication_preference(p.legs[i].start,&auth,NULL);
        printf("leg%zu=family:%u ep:%u iface:%u mux:%u profile:%u apn:%s auth:%u creds:%s/%s\n",
               i,f,ep,iface,mux,profile,apn,auth,user,pass);
    }
    if (hotdog_qmi_wds_current_settings_input(&settings)) return 5;
    if (!qmi_message_wds_get_current_settings_input_get_requested_settings(
            settings, &requested, NULL)) return 6;
    printf("settings=%x\n", requested);
    qmi_message_wds_get_current_settings_input_unref(settings);
    hotdog_qmi_wds_plan_clear(&p); return 0;
}
'''


class HotdogQmiWdsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        flags = subprocess.run(["pkg-config", "--cflags", "--libs", "qmi-glib", "glib-2.0"],
                               check=True, capture_output=True, text=True).stdout.split()
        cls._temporary = tempfile.TemporaryDirectory()
        source = Path(cls._temporary.name) / "wds.c"
        cls.binary = Path(cls._temporary.name) / "wds"
        source.write_text(HARNESS)
        subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2",
                        "-I", str(SOURCE), str(SOURCE / "hotdog-network.c"),
                        str(SOURCE / "hotdog-qmi-wds.c"), str(source), *flags,
                        "-o", str(cls.binary)], check=True)

    @classmethod
    def tearDownClass(cls) -> None:
        cls._temporary.cleanup()

    def test_dual_stack_creates_two_bound_clients(self) -> None:
        output = subprocess.run([str(self.binary)], check=True,
                                capture_output=True, text=True).stdout
        self.assertIn("legs=2", output)
        self.assertIn("leg0=family:4 ep:4 iface:4 mux:3 profile:7", output)
        self.assertIn("leg1=family:6 ep:4 iface:4 mux:3 profile:7", output)
        self.assertEqual(output.count("apn:internet auth:3 creds:user/pass"), 2)

    def test_credentials_are_never_logged_by_source(self) -> None:
        source = (SOURCE / "hotdog-qmi-wds.c").read_text()
        self.assertNotIn("printf", source)
        self.assertNotIn("g_print", source)

    def test_stop_request_keeps_exact_packet_handle(self) -> None:
        flags = subprocess.run(
            ["pkg-config", "--cflags", "--libs", "qmi-glib", "glib-2.0"],
            check=True, capture_output=True, text=True,
        ).stdout.split()
        source = r'''#include "hotdog-qmi-wds.h"
#include <stdio.h>
int main(void) { QmiMessageWdsStopNetworkInput *i=NULL; guint32 h=0;
 if(hotdog_qmi_wds_stop_input(0x12345678,&i)) return 1;
 if(!qmi_message_wds_stop_network_input_get_packet_data_handle(i,&h,NULL)) return 2;
 printf("handle=%08x\n",h); qmi_message_wds_stop_network_input_unref(i); }
'''
        with tempfile.TemporaryDirectory() as directory:
            cfile = Path(directory) / "stop.c"
            binary = Path(directory) / "stop"
            cfile.write_text(source)
            subprocess.run(
                ["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2",
                 "-I", str(SOURCE), str(SOURCE / "hotdog-network.c"),
                 str(SOURCE / "hotdog-qmi-wds.c"), str(cfile), *flags,
                 "-o", str(binary)], check=True,
            )
            output = subprocess.run([str(binary)], check=True,
                                    capture_output=True, text=True).stdout.strip()
            self.assertEqual(output, "handle=12345678")

    def test_current_settings_request_includes_ims_routing_evidence(self) -> None:
        output = subprocess.run([str(self.binary)], check=True,
                                capture_output=True, text=True).stdout
        self.assertIn("settings=ff10", output)

    def test_handset_client_type_may_be_omitted(self) -> None:
        source = (SOURCE / "hotdog-qmi-wds.c").read_text()
        self.assertIn("client_type != QMI_WDS_CLIENT_TYPE_UNDEFINED", source)


if __name__ == "__main__":
    unittest.main()
