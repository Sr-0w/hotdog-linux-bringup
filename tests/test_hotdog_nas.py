from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]
SOURCE = ROOT / "helpers" / "hotdog-radio"


class HotdogNasTests(unittest.TestCase):
    def test_adapter_compiles_and_names_states(self) -> None:
        flags = subprocess.run(
            ["pkg-config", "--cflags", "--libs", "qmi-glib", "glib-2.0"],
            capture_output=True, text=True,
        )
        if flags.returncode:
            self.skipTest("libqmi development files are unavailable")
        harness = r'''#include "hotdog-qmi-nas.h"
#include <stdio.h>
int main(void) {
    struct hotdog_network network; struct hotdog_network_teardown teardown;
    struct hotdog_nas_snapshot snapshot={.registration=QMI_NAS_REGISTRATION_STATE_REGISTERED,
      .cs_attach=QMI_NAS_ATTACH_STATE_ATTACHED,.ps_attach=QMI_NAS_ATTACH_STATE_ATTACHED,
      .network=QMI_NAS_NETWORK_TYPE_3GPP,.roaming_valid=true,
      .roaming=QMI_NAS_ROAMING_INDICATOR_STATUS_OFF,.plmn_valid=true,.mcc=206,.mnc=1,
      .interfaces={QMI_NAS_RADIO_INTERFACE_CDMA_1X,QMI_NAS_RADIO_INTERFACE_LTE},
      .interface_count=2};
    hotdog_network_init(&network); hotdog_network_set_subscription(&network,0,true);
    if(hotdog_qmi_nas_apply_snapshot(&network,0,&snapshot,&teardown)) return 1;
    printf("registration=%s cs=%s network=%s\n",
           hotdog_qmi_nas_registration_name(QMI_NAS_REGISTRATION_STATE_NOT_REGISTERED),
           hotdog_qmi_nas_attach_name(QMI_NAS_ATTACH_STATE_DETACHED),
           hotdog_qmi_nas_network_name(QMI_NAS_NETWORK_TYPE_UNKNOWN));
    printf("mapped=%s/%s/%u-%u/ps%u teardown=%zu\n",
      hotdog_nas_registration_name(network.subscriptions[0].registration),
      hotdog_nas_rat_name(network.subscriptions[0].rat),network.subscriptions[0].mcc,
      network.subscriptions[0].mnc,network.subscriptions[0].ps_attached,teardown.count);
    return 0;
}
'''
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "nas-harness.c"
            binary = Path(directory) / "nas-harness"
            source.write_text(harness)
            subprocess.run(
                [
                    "cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2",
                    "-I", str(SOURCE), str(SOURCE / "hotdog-qmi-nas.c"),
                    str(SOURCE / "hotdog-network.c"),
                    str(source), *flags.stdout.split(), "-o", str(binary),
                ],
                check=True,
            )
            result = subprocess.run([str(binary)], check=True, capture_output=True, text=True)
            self.assertIn("registration=not-registered", result.stdout)
            self.assertIn("cs=detached", result.stdout)
            self.assertIn("network=unknown", result.stdout)
            self.assertIn("mapped=home/lte/206-1/ps1 teardown=0", result.stdout)

    def test_registered_snapshot_requires_roaming_and_plmn_evidence(self) -> None:
        source = (SOURCE / "hotdog-qmi-nas.c").read_text()
        self.assertIn("if (!snapshot->roaming_valid)", source)
        self.assertIn("!snapshot->plmn_valid", source)
        self.assertIn("qmi_indication_nas_serving_system_output_get_serving_system", source)


if __name__ == "__main__":
    unittest.main()
