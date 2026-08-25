from __future__ import annotations

from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "helpers/hotdog-radio"

HARNESS = r'''
#include "hotdog-qmi-rmnet.h"
#include <stdio.h>

int main(void) {
    struct hotdog_qmi_rmnet_plan plan;
    int result = hotdog_qmi_rmnet_plan_build(
        "ipa", 0, "rmnet_ipa0", "ims", "MAPv4\n", "MAPv4\n", &plan);
    printf("result=%d endpoint=%u interface=%u flags=%u base=%s prefix=%s valid=%d\n",
           result, plan.endpoint_type, plan.endpoint_interface, plan.flags,
           plan.base_ifname, plan.prefix,
           hotdog_qmi_rmnet_link_validate(&plan, "ims0", 11));
    printf("bad-driver=%d bad-offload=%d bad-mux=%d\n",
           hotdog_qmi_rmnet_plan_build("unknown", 0, "rmnet_ipa0", "ims",
                                       NULL, NULL, &plan),
           hotdog_qmi_rmnet_plan_build("ipa", 0, "rmnet_ipa0", "ims",
                                       "MAPv9", "MAPv4", &plan),
           hotdog_qmi_rmnet_link_validate(&plan, "ims0", 0));
}
'''


class HotdogQmiRmnetTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        flags = subprocess.run(
            ["pkg-config", "--cflags", "--libs", "qmi-glib", "glib-2.0"],
            check=True, capture_output=True, text=True,
        ).stdout.split()
        cls.temp = tempfile.TemporaryDirectory()
        source = Path(cls.temp.name) / "rmnet.c"
        source.write_text(HARNESS, encoding="ascii")
        cls.binary = Path(cls.temp.name) / "rmnet"
        subprocess.run(
            ["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2",
             "-I", str(SOURCE), str(SOURCE / "hotdog-qmi-rmnet.c"),
             str(source), *flags, "-o", str(cls.binary)], check=True,
        )

    @classmethod
    def tearDownClass(cls) -> None:
        cls.temp.cleanup()

    def test_ipa_endpoint_and_mapv4_flags_match_hotdog(self) -> None:
        output = subprocess.run(
            [str(self.binary)], check=True, capture_output=True, text=True
        ).stdout
        self.assertIn(
            "result=0 endpoint=4 interface=1 flags=6 base=rmnet_ipa0 prefix=ims valid=0",
            output,
        )

    def test_unknown_topology_and_invalid_mux_fail_closed(self) -> None:
        output = subprocess.run(
            [str(self.binary)], check=True, capture_output=True, text=True
        ).stdout
        self.assertIn("bad-driver=-95 bad-offload=-71 bad-mux=-22", output)

    def test_adapter_uses_dynamic_link_validation_contract(self) -> None:
        source = (SOURCE / "hotdog-qmi-rmnet.c").read_text(encoding="ascii")
        self.assertIn("QMI_DEVICE_MUX_ID_MIN", source)
        self.assertIn("QMI_DEVICE_MUX_ID_MAX", source)
        self.assertNotIn("rmnet_data", source)


if __name__ == "__main__":
    unittest.main()
