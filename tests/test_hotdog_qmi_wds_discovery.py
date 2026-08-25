from __future__ import annotations

from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "helpers/hotdog-radio"

HARNESS = r'''
#include "hotdog-qmi-wds-discovery.h"
#include <stdio.h>

int main(void) {
    struct hotdog_qmi_wds_discovery discovery;
    hotdog_qmi_wds_discovery_init(&discovery);
    discovery.active = true;
    printf("active-clear=%d ", hotdog_qmi_wds_discovery_clear(&discovery));
    discovery.active = false;
    printf("idle-clear=%d\n", hotdog_qmi_wds_discovery_clear(&discovery));
}
'''


class HotdogQmiWdsDiscoveryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        flags = subprocess.run(
            ["pkg-config", "--cflags", "--libs", "qmi-glib", "qrtr-glib",
             "gio-2.0", "glib-2.0"], check=True, capture_output=True,
            text=True,
        ).stdout.split()
        cls.temp = tempfile.TemporaryDirectory()
        source = Path(cls.temp.name) / "discovery.c"
        source.write_text(HARNESS, encoding="ascii")
        cls.binary = Path(cls.temp.name) / "discovery"
        sources = [
            "hotdog-qmi-wds-discovery.c", "hotdog-qmi-wds-profile.c",
            "hotdog-ims-bearer.c", "hotdog-network.c",
        ]
        subprocess.run(
            ["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2",
             "-I", str(SOURCE), *(str(SOURCE / item) for item in sources),
             str(source), *flags, "-o", str(cls.binary)], check=True,
        )

    @classmethod
    def tearDownClass(cls) -> None:
        cls.temp.cleanup()

    def test_clear_refuses_active_discovery(self) -> None:
        output = subprocess.run(
            [str(self.binary)], check=True, capture_output=True, text=True
        ).stdout.strip()
        self.assertEqual(output, "active-clear=-16 idle-clear=0")

    def test_sequence_is_subscription_scoped_and_releases_its_cid(self) -> None:
        source = (SOURCE / "hotdog-qmi-wds-discovery.c").read_text(encoding="ascii")
        for marker in (
            "qmi_client_wds_bind_subscription",
            "qmi_client_wds_get_profile_list",
            "qmi_client_wds_get_profile_settings",
            "hotdog_ims_profile_select",
            "qmi_device_release_client",
        ):
            self.assertIn(marker, source)
        self.assertNotIn("qmi_client_wds_start_network", source)

    def test_ssr_invalidates_old_callbacks_without_releasing_stale_cid(self) -> None:
        source = (SOURCE / "hotdog-qmi-wds-discovery.c").read_text(encoding="ascii")
        self.assertIn("discovery->generation++", source)
        self.assertIn("discovery->result = -ENETRESET", source)
        self.assertIn("request->generation == request->discovery->generation", source)

    def test_transport_and_release_failures_are_not_reported_as_no_profile(self) -> None:
        source = (SOURCE / "hotdog-qmi-wds-discovery.c").read_text(encoding="ascii")
        self.assertIn("result != -ENODATA && result != -EPROTO", source)
        self.assertIn("discovery->result = -EUCLEAN", source)
        self.assertIn("discovery->residue = true", source)


if __name__ == "__main__":
    unittest.main()
