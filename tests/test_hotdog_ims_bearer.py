from __future__ import annotations

import errno
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "helpers/hotdog-radio"

HARNESS = r'''
#include "hotdog-ims-bearer.h"
#include <errno.h>
#include <stdio.h>
#include <string.h>

static struct hotdog_ims_profile profile(unsigned int sub, unsigned int index,
        uint64_t mask, enum hotdog_profile_pdp_type pdp, const char *apn,
        bool pcscf) {
    struct hotdog_ims_profile value = {
        .subscription = sub, .index = index, .is_3gpp = true, .enabled = true,
        .pcscf_via_pco = pcscf, .apn_type_mask = mask, .pdp_type = pdp,
    };
    strcpy(value.apn, apn);
    return value;
}

int main(int argc, char **argv) {
    struct hotdog_ims_profile profiles[4] = {0};
    struct hotdog_ims_profile_selection selected = {0};
    struct hotdog_network network;
    unsigned int bearer = 0;
    int result;

    if (argc != 2) return 2;
    if (!strcmp(argv[1], "select")) {
        profiles[0] = profile(0, 3, HOTDOG_APN_TYPE_IMS | HOTDOG_APN_TYPE_UT,
                              HOTDOG_PROFILE_PDP_IPV4V6, "ims-combined", true);
        profiles[1] = profile(0, 7, HOTDOG_APN_TYPE_IMS,
                              HOTDOG_PROFILE_PDP_IPV4V6, "ims", true);
        result = hotdog_ims_profile_select(profiles, 2, 0, HOTDOG_BEARER_IMS,
                                           NULL, &selected);
        printf("result=%d index=%u family=%s apn=%s purpose=%s\n", result,
               selected.index, hotdog_ip_family_name(selected.family), selected.apn,
               hotdog_bearer_purpose_name(selected.purpose));
        return 0;
    }
    if (!strcmp(argv[1], "expected")) {
        profiles[0] = profile(0, 3, HOTDOG_APN_TYPE_IMS | HOTDOG_APN_TYPE_UT,
                              HOTDOG_PROFILE_PDP_IPV6, "carrier-ims", true);
        profiles[1] = profile(0, 7, HOTDOG_APN_TYPE_IMS,
                              HOTDOG_PROFILE_PDP_IPV4V6, "other-ims", true);
        result = hotdog_ims_profile_select(profiles, 2, 0, HOTDOG_BEARER_IMS,
                                           "carrier-ims", &selected);
        printf("result=%d index=%u family=%s apn=%s\n", result, selected.index,
               hotdog_ip_family_name(selected.family), selected.apn);
        return 0;
    }
    if (!strcmp(argv[1], "ambiguous")) {
        profiles[0] = profile(0, 3, HOTDOG_APN_TYPE_IMS,
                              HOTDOG_PROFILE_PDP_IPV4V6, "ims-a", true);
        profiles[1] = profile(0, 7, HOTDOG_APN_TYPE_IMS,
                              HOTDOG_PROFILE_PDP_IPV4V6, "ims-b", true);
        result = hotdog_ims_profile_select(profiles, 2, 0, HOTDOG_BEARER_IMS,
                                           NULL, &selected);
        printf("result=%d\n", result);
        return 0;
    }
    if (!strcmp(argv[1], "pcscf")) {
        profiles[0] = profile(0, 3, HOTDOG_APN_TYPE_IMS,
                              HOTDOG_PROFILE_PDP_IPV4V6, "ims", false);
        result = hotdog_ims_profile_select(profiles, 1, 0, HOTDOG_BEARER_IMS,
                                           NULL, &selected);
        printf("result=%d\n", result);
        return 0;
    }
    if (!strcmp(argv[1], "network")) {
        hotdog_network_init(&network);
        hotdog_network_set_subscription(&network, 0, true);
        hotdog_network_set_subscription(&network, 1, true);
        hotdog_network_nas_update(&network, 0, HOTDOG_NAS_HOME, 206, 1,
                                  HOTDOG_RAT_LTE, true, true);
        hotdog_network_nas_update(&network, 1, HOTDOG_NAS_HOME, 206, 1,
                                  HOTDOG_RAT_LTE, true, true);
        result = hotdog_network_bearer_start_purpose(&network, 1, 7, 5,
                    HOTDOG_IP_V4V6, HOTDOG_AUTH_NONE, HOTDOG_BEARER_IMS,
                    "ims", &bearer);
        printf("ims=%d bearer=%u purpose=%s ", result, bearer,
               hotdog_bearer_purpose_name(network.bearers[0].purpose));
        result = hotdog_network_set_default_data(&network, 1, false);
        printf("dds=%d state=%s\n", result,
               hotdog_bearer_state_name(network.bearers[0].state));
        return 0;
    }
    return 2;
}
'''


class HotdogImsBearerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.temp = tempfile.TemporaryDirectory()
        directory = Path(cls.temp.name)
        harness = directory / "ims-bearer.c"
        harness.write_text(HARNESS, encoding="ascii")
        cls.binary = directory / "ims-bearer"
        subprocess.run(
            [
                "cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2",
                "-I", str(SOURCE), str(SOURCE / "hotdog-network.c"),
                str(SOURCE / "hotdog-ims-bearer.c"), str(harness),
                "-o", str(cls.binary),
            ],
            check=True,
        )

    @classmethod
    def tearDownClass(cls) -> None:
        cls.temp.cleanup()

    def run_mode(self, mode: str) -> str:
        result = subprocess.run(
            [str(self.binary), mode], check=True, capture_output=True, text=True
        )
        return result.stdout.strip()

    def test_exact_ims_mask_beats_composite_profile(self) -> None:
        self.assertEqual(
            self.run_mode("select"),
            "result=0 index=7 family=ipv4v6 apn=ims purpose=ims",
        )

    def test_expected_apn_can_select_carrier_composite_profile(self) -> None:
        self.assertEqual(
            self.run_mode("expected"),
            "result=0 index=3 family=ipv6 apn=carrier-ims",
        )

    def test_ambiguous_or_missing_pcscf_profile_fails_closed(self) -> None:
        self.assertEqual(self.run_mode("ambiguous"), f"result={-getattr(errno, 'ENOTUNIQ', 76)}")
        self.assertEqual(self.run_mode("pcscf"), f"result={-errno.ENOENT}")

    def test_ims_bearer_is_not_tied_to_default_data_subscription(self) -> None:
        self.assertEqual(
            self.run_mode("network"),
            "ims=0 bearer=1 purpose=ims dds=0 state=starting",
        )


if __name__ == "__main__":
    unittest.main()
