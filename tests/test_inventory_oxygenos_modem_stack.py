from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "scripts" / "inventory-oxygenos-modem-stack.py"
SPEC = importlib.util.spec_from_file_location("inventory_oxygenos_modem_stack", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(MODULE)


class InventoryOxygenosModemStackTests(unittest.TestCase):
    def test_symbol_families_cover_the_stack(self) -> None:
        result = MODULE.classify_symbols([
            "qcril_uim_request_get_sim_status",
            "qcril_qmi_pdc_select_configs",
            "qcril_qmi_nas_set_radio_capability",
            "qcril_data_process_wds_ind",
            "qcril_qmi_wms_send_sms",
            "qcril_qmi_voice_request_dial",
            "qcril_qmi_imsa_get_ims_sub_configs",
            "qcril_data_process_modem_restart",
        ])
        self.assertEqual(set(result), {"uim", "pdc-mbn", "radio-nas", "data", "sms", "voice", "ims", "ssr"})

    def test_init_parser_keeps_services_and_property_actions(self) -> None:
        parsed = MODULE.parse_init_services(
            """
service vendor.qcrild /vendor/bin/hw/qcrild -c 2
    class main
    user radio
    disabled

on property:vendor.ims.QMI_DAEMON_STATUS=1
    start vendor.imsdatadaemon
""",
            "etc/init/test.rc",
        )
        self.assertEqual(parsed[0]["name"], "vendor.qcrild")
        self.assertEqual(parsed[0]["command"], ["/vendor/bin/hw/qcrild", "-c", "2"])
        self.assertIn("disabled", parsed[0]["options"])
        self.assertEqual(parsed[1]["action"], "start vendor.imsdatadaemon")

    def test_inventory_never_emits_the_host_root(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            component = root / "bin/hw/qcrild"
            component.parent.mkdir(parents=True)
            component.write_bytes(b"synthetic-radio-binary")
            document = MODULE.inventory(root)
            self.assertEqual(document["components"][0]["path"], "bin/hw/qcrild")
            self.assertNotIn(directory, str(document))


if __name__ == "__main__":
    unittest.main()
