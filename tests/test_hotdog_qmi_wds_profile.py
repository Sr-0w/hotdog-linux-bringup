from __future__ import annotations

from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "helpers/hotdog-radio"

HARNESS = r'''
#include "hotdog-qmi-wds-profile.h"
#include <stdio.h>

int main(void) {
    QmiMessageWdsGetProfileListInput *list = NULL;
    QmiMessageWdsGetProfileSettingsInput *settings = NULL;
    QmiWdsProfileType type = QMI_WDS_PROFILE_TYPE_3GPP2;
    guint8 index = 0;
    if (hotdog_qmi_wds_profile_list_input(&list)) return 1;
    if (!qmi_message_wds_get_profile_list_input_get_profile_type(list, &type, NULL)) return 2;
    if (hotdog_qmi_wds_profile_settings_input(7, &settings)) return 3;
    if (!qmi_message_wds_get_profile_settings_input_get_profile_id(
            settings, &type, &index, NULL)) return 4;
    printf("type=%u index=%u\n", type, index);
    qmi_message_wds_get_profile_list_input_unref(list);
    qmi_message_wds_get_profile_settings_input_unref(settings);
    return 0;
}
'''


class HotdogQmiWdsProfileTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.temp = tempfile.TemporaryDirectory()
        directory = Path(cls.temp.name)
        harness = directory / "profile.c"
        harness.write_text(HARNESS, encoding="ascii")
        flags = subprocess.run(
            ["pkg-config", "--cflags", "--libs", "qmi-glib", "glib-2.0"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.split()
        cls.binary = directory / "profile"
        subprocess.run(
            [
                "cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2",
                "-I", str(SOURCE), str(SOURCE / "hotdog-qmi-wds-profile.c"),
                str(SOURCE / "hotdog-ims-bearer.c"),
                str(SOURCE / "hotdog-network.c"), str(harness), *flags,
                "-o", str(cls.binary),
            ],
            check=True,
        )

    @classmethod
    def tearDownClass(cls) -> None:
        cls.temp.cleanup()

    def test_profile_requests_are_3gpp_and_bounded(self) -> None:
        result = subprocess.run(
            [str(self.binary)], check=True, capture_output=True, text=True
        )
        self.assertEqual(result.stdout.strip(), "type=0 index=7")

    def test_decoder_requires_apn_mask_pdp_and_pcscf_evidence(self) -> None:
        source = (SOURCE / "hotdog-qmi-wds-profile.c").read_text(encoding="ascii")
        self.assertIn("get_apn_name", source)
        self.assertIn("get_pdp_type", source)
        self.assertIn("get_apn_type_mask", source)
        self.assertIn("get_pcscf_address_using_pco", source)
        self.assertNotIn("get_username", source)
        self.assertNotIn("get_password", source)

    def test_target_transport_requires_subscription_aware_libqmi(self) -> None:
        header = (SOURCE / "hotdog-qmi-wds-profile.h").read_text(encoding="ascii")
        source = (SOURCE / "hotdog-qmi-wds-profile.c").read_text(encoding="ascii")
        self.assertIn("QMI_CHECK_VERSION(1, 37, 0)", header)
        self.assertIn("qmi_message_wds_bind_subscription_input_set_subscription_id", source)
        self.assertIn("QMI_SUBSCRIPTION_TYPE_TERITIARY", source)

    def test_profile_decoders_fail_closed_on_unusable_inventory(self) -> None:
        source = (SOURCE / "hotdog-qmi-wds-profile.c").read_text(encoding="ascii")
        self.assertIn("items->len > capacity", source)
        self.assertIn("!item->profile_index", source)
        self.assertIn("profiles[previous].index == item->profile_index", source)
        self.assertIn("return -ENOTUNIQ", source)
        self.assertIn("strnlen(apn, sizeof(profile->apn))", source)
        self.assertIn("return -EPROTO", source)


if __name__ == "__main__":
    unittest.main()
