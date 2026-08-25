from __future__ import annotations

from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "helpers/hotdog-radio"

HARNESS = r'''
#include "hotdog-qmi-ims-session.h"
#include <stdio.h>

int main(void) {
    struct hotdog_qmi_ims_session session;
    struct hotdog_ims_executor_operation operation;
    hotdog_qmi_ims_session_init(&session);
    printf("idle-clear=%d ", hotdog_qmi_ims_session_clear(&session));
    hotdog_qmi_ims_session_init(&session);
    hotdog_ims_executor_begin(&session.executor, HOTDOG_IP_V4V6, &operation);
    printf("active-clear=%d phase=%s\n", hotdog_qmi_ims_session_clear(&session),
           hotdog_ims_executor_phase_name(session.executor.phase));
}
'''


class HotdogQmiImsSessionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        flags = subprocess.run(
            ["pkg-config", "--cflags", "--libs", "qmi-glib", "qrtr-glib",
             "gio-2.0", "glib-2.0"], check=True, capture_output=True,
            text=True,
        ).stdout.split()
        cls.temp = tempfile.TemporaryDirectory()
        source = Path(cls.temp.name) / "session.c"
        source.write_text(HARNESS, encoding="ascii")
        cls.binary = Path(cls.temp.name) / "session"
        sources = [
            "hotdog-qmi-ims-session.c", "hotdog-ims-executor.c",
            "hotdog-qmi-rmnet.c", "hotdog-qmi-wds.c",
            "hotdog-qmi-wds-profile.c", "hotdog-ims-bearer.c",
            "hotdog-network.c",
        ]
        subprocess.run(
            ["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2",
             "-I", str(SOURCE), *(str(SOURCE / item) for item in sources),
             str(source), *flags, "-o", str(cls.binary)], check=True,
        )

    @classmethod
    def tearDownClass(cls) -> None:
        cls.temp.cleanup()

    def test_clear_refuses_to_abandon_active_ownership(self) -> None:
        output = subprocess.run(
            [str(self.binary)], check=True, capture_output=True, text=True
        ).stdout.strip()
        self.assertEqual(output, "idle-clear=0 active-clear=-16 phase=adding-link")

    def test_target_path_performs_real_dynamic_rmnet_and_wds_operations(self) -> None:
        source = (SOURCE / "hotdog-qmi-ims-session.c").read_text(encoding="ascii")
        required = [
            "QMI_DEVICE_MUX_ID_AUTOMATIC",
            "qmi_device_add_link_with_flags",
            "qmi_device_allocate_client",
            "qmi_client_wds_bind_subscription",
            "qmi_client_wds_bind_mux_data_port",
            "qmi_client_wds_start_network",
            "qmi_client_wds_get_current_settings",
            "qmi_client_wds_stop_network",
            "qmi_device_release_client",
            "qmi_device_delete_link",
        ]
        for marker in required:
            self.assertIn(marker, source)
        callback = source[
            source.index("static void bind_subscription_ready"):
            source.index("static void start_ready")
        ]
        self.assertIn("qmi_client_wds_bind_mux_data_port(", callback)

    def test_ssr_invalidates_old_callbacks_and_cleans_late_links(self) -> None:
        source = (SOURCE / "hotdog-qmi-ims-session.c").read_text(encoding="ascii")
        self.assertIn("request->generation == request->session->generation", source)
        self.assertIn("qmi_device_delete_link(device, ifname, mux_id", source)
        self.assertIn("g_cancellable_cancel(session->cancellable)", source)

    def test_handset_session_never_requests_tethered_or_credentials(self) -> None:
        source = (SOURCE / "hotdog-qmi-ims-session.c").read_text(encoding="ascii")
        self.assertIn("QMI_WDS_CLIENT_TYPE_UNDEFINED", source)
        self.assertNotIn("QMI_WDS_CLIENT_TYPE_TETHERED", source)
        self.assertNotIn("username", source.lower())
        self.assertNotIn("password", source.lower())


if __name__ == "__main__":
    unittest.main()
