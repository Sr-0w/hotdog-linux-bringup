from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]
SOURCE = ROOT / "helpers/hotdog-radio"


class HotdogPdcTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls._temporary = tempfile.TemporaryDirectory()
        cls.binary = Path(cls._temporary.name) / "hotdog-pdc-replay"
        subprocess.run(
            [
                "cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2",
                "-I", str(SOURCE), str(SOURCE / "hotdog-mbn.c"),
                str(SOURCE / "hotdog-pdc.c"), str(SOURCE / "hotdog-pdc-replay.c"),
                "-o", str(cls.binary),
            ],
            check=True,
        )

    @classmethod
    def tearDownClass(cls) -> None:
        cls._temporary.cleanup()

    def replay(self, content: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run([str(self.binary)], input=content, text=True, capture_output=True)

    def test_selection_precedence_and_version_tie_break(self) -> None:
        result = self.replay(
            "CONFIG wildcard 99 WILDCARD\n"
            "CONFIG plmn 99 PLMN 206 1\n"
            "CONFIG iin-old 1 IIN 123456\n"
            "CONFIG iin-new 9 IIN 123456\n"
            "CONFIG exact 1 LONG 123456789\n"
            "SUB 0 1234567890000000000 206 1 previous\nPLAN\n"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("op1=set-selected,sub0,expected0,id=exact", result.stdout)

        tie = self.replay(
            "CONFIG old 1 IIN 123456\nCONFIG new 9 IIN 123456\n"
            "SUB 0 1234560000000000000 0 0 previous\nPLAN\n"
        )
        self.assertIn("op1=set-selected,sub0,expected0,id=new", tie.stdout)

    def test_two_subscriptions_share_one_bounded_activation(self) -> None:
        result = self.replay(
            "CONFIG carrier-a 1 IIN 111111\n"
            "CONFIG carrier-b 1 IIN 222222\n"
            "SUB 0 1111110000000000000 0 0 old-a\n"
            "SUB 1 2222220000000000000 0 0 old-b\n"
            "PLAN\nACTIVE 0 carrier-a\nACTIVE 1 carrier-b\nVERIFY\nROLLBACK\n"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("plan-result=0 operations=8", result.stdout)
        self.assertIn("op4=activate,sub1,expected2,id=-", result.stdout)
        self.assertIn("verified=1", result.stdout)
        self.assertIn("rollback-result=0 operations=6", result.stdout)
        self.assertIn("op0=deactivate,sub0,expected1,id=carrier-a", result.stdout)
        self.assertIn("op1=restore-selected,sub0,expected0,id=old-a", result.stdout)
        self.assertIn("op2=deactivate,sub1,expected1,id=carrier-b", result.stdout)
        self.assertIn("op4=activate,sub1,expected2,id=-", result.stdout)

    def test_already_active_profile_is_a_noop(self) -> None:
        result = self.replay(
            "CONFIG carrier 1 IIN 123456\n"
            "SUB 0 1234560000000000000 0 0 carrier\nPLAN\nVERIFY\n"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("plan-result=0 operations=0", result.stdout)
        self.assertIn("verified=1", result.stdout)

    def test_unloaded_profile_is_loaded_and_deleted_on_empty_state_rollback(self) -> None:
        result = self.replay(
            "CONFIG_UNLOADED carrier 1 IIN 123456\n"
            "SUB 0 1234560000000000000 0 0 -\nPLAN\nROLLBACK\n"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("plan-result=0 operations=6", result.stdout)
        self.assertIn("op1=load-config,sub0,expected0,id=carrier", result.stdout)
        self.assertIn("op2=set-selected,sub0,expected0,id=carrier", result.stdout)
        self.assertIn("rollback-result=0 operations=2", result.stdout)
        self.assertIn("op0=deactivate,sub0,expected1,id=carrier", result.stdout)
        self.assertIn("op1=delete-config,sub0,expected0,id=carrier", result.stdout)

    def test_shared_unloaded_profile_is_loaded_and_deleted_once(self) -> None:
        result = self.replay(
            "CONFIG_UNLOADED shared 1 WILDCARD\n"
            "SUB 0 1111110000000000000 0 0 old-a\n"
            "SUB 1 2222220000000000000 0 0 old-b\n"
            "PLAN\nROLLBACK\n"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.count("=load-config,"), 1)
        self.assertEqual(result.stdout.count("=delete-config,"), 1)

    def test_loaded_catalog_avoids_duplicate_load(self) -> None:
        result = self.replay(
            "CONFIG carrier 1 IIN 123456\n"
            "SUB 0 1234560000000000000 0 0 -\nPLAN\n"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("=load-config,", result.stdout)

    def test_cleanup_deletes_only_unmatched_inactive_residents(self) -> None:
        result = self.replay(
            "CONFIG current 1 WILDCARD\n"
            "SUB 0 1111110000000000000 0 0 -\n"
            "RESIDENT current\nRESIDENT stale-a\nRESIDENT stale-b\nCLEANUP\nPLAN\n"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("cleanup-unmatched=2", result.stdout)
        self.assertIn("cleanup-result=0 operations=2", result.stdout)
        self.assertIn("id=stale-a", result.stdout)
        self.assertIn("id=stale-b", result.stdout)
        self.assertNotIn("=delete-config,sub0,expected0,id=current", result.stdout)
        self.assertNotIn("=load-config,", result.stdout)

    def test_cleanup_refuses_unknown_active_or_pending_resident(self) -> None:
        active = self.replay(
            "CONFIG current 1 WILDCARD\nSUB 0 1111110000000000000 0 0 stale\n"
            "RESIDENT stale\nCLEANUP\n"
        )
        self.assertIn("cleanup-result=-16 operations=0", active.stdout)
        pending = self.replay(
            "CONFIG current 1 WILDCARD\nSUB 0 1111110000000000000 0 0 -\n"
            "PENDING 0 stale\nRESIDENT stale\nCLEANUP\n"
        )
        self.assertIn("cleanup-result=-16 operations=0", pending.stdout)

    def test_cleanup_rejects_duplicate_resident_ids(self) -> None:
        result = self.replay(
            "CONFIG current 1 WILDCARD\nSUB 0 1111110000000000000 0 0 -\n"
            "RESIDENT stale\nRESIDENT stale\nCLEANUP\n"
        )
        self.assertIn("cleanup-result=-17 operations=0", result.stdout)

    def test_unmatched_card_fails_before_mutation(self) -> None:
        result = self.replay(
            "CONFIG carrier 1 IIN 123456\n"
            "SUB 0 6543210000000000000 0 0 old\nPLAN\n"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "plan-result=-2 operations=0")

    def test_malformed_ids_and_subscription_bounds_fail_closed(self) -> None:
        too_long = self.replay("CONFIG this-id-is-more-than-twenty-bytes 1 WILDCARD\n")
        self.assertEqual(too_long.returncode, 2)
        self.assertIn("line 1", too_long.stderr)

        bad_subscription = self.replay("SUB 3 1234560000000000000 0 0 old\n")
        self.assertEqual(bad_subscription.returncode, 2)


class HotdogQmiPdcBuildTests(unittest.TestCase):
    def test_subscription_scoped_adapter_compiles(self) -> None:
        flags = subprocess.run(
            ["pkg-config", "--cflags", "qmi-glib", "glib-2.0"],
            capture_output=True, text=True,
        )
        if flags.returncode:
            self.skipTest("libqmi development files are unavailable")
        compatibility = """\
#include <libqmi-glib.h>
gboolean qmi_message_pdc_get_selected_config_input_set_subscription_id(
    QmiMessagePdcGetSelectedConfigInput *, guint32, GError **);
gboolean qmi_message_pdc_set_selected_config_input_set_subscription_id(
    QmiMessagePdcSetSelectedConfigInput *, guint32, GError **);
gboolean qmi_message_pdc_activate_config_input_set_subscription_id(
    QmiMessagePdcActivateConfigInput *, guint32, GError **);
gboolean qmi_message_pdc_deactivate_config_input_set_subscription_id(
    QmiMessagePdcDeactivateConfigInput *, guint32, GError **);
"""
        with tempfile.TemporaryDirectory() as directory:
            header = Path(directory) / "hotdog-patched-pdc-api.h"
            header.write_text(compatibility)
            subprocess.run(
                [
                    "cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2",
                    "-fsyntax-only", "-include", str(header), "-I", str(SOURCE),
                    str(SOURCE / "hotdog-qmi-pdc.c"), *flags.stdout.split(),
                ],
                check=True,
            )

    def test_libqmi_patch_defines_every_subscription_field(self) -> None:
        patch = (ROOT / "aports/temp/libqmi/0001-pdc-add-subscription-id.patch").read_text()
        for operation in (
            "get_selected_config",
            "set_selected_config",
            "activate_config",
            "deactivate_config",
        ):
            self.assertIn(f"qmi_message_pdc_{operation}_input_set_subscription_id", patch)

    def test_adapter_requires_confirmation_for_every_mutation(self) -> None:
        source = (SOURCE / "hotdog-qmi-pdc.c").read_text()
        for decoder in (
            "hotdog_qmi_pdc_decode_set_selected",
            "hotdog_qmi_pdc_decode_activate",
            "hotdog_qmi_pdc_decode_deactivate",
            "hotdog_qmi_pdc_decode_delete",
        ):
            self.assertIn(decoder, source)
        self.assertGreaterEqual(source.count("return -ESTALE;"), 3)
        self.assertGreaterEqual(source.count("return -EREMOTEIO;"), 3)

    def test_uim_pdc_bootstrap_syntax_with_patched_api(self) -> None:
        flags = subprocess.run(
            ["pkg-config", "--cflags", "qmi-glib", "qrtr-glib", "gio-2.0", "glib-2.0"],
            capture_output=True, text=True,
        )
        if flags.returncode:
            self.skipTest("libqmi/qrtr development files are unavailable")
        compatibility = """\
#include <libqmi-glib.h>
gboolean qmi_message_pdc_get_selected_config_input_set_subscription_id(
    QmiMessagePdcGetSelectedConfigInput *, guint32, GError **);
gboolean qmi_message_pdc_set_selected_config_input_set_subscription_id(
    QmiMessagePdcSetSelectedConfigInput *, guint32, GError **);
gboolean qmi_message_pdc_activate_config_input_set_subscription_id(
    QmiMessagePdcActivateConfigInput *, guint32, GError **);
gboolean qmi_message_pdc_deactivate_config_input_set_subscription_id(
    QmiMessagePdcDeactivateConfigInput *, guint32, GError **);
"""
        with tempfile.TemporaryDirectory() as directory:
            header = Path(directory) / "hotdog-patched-pdc-api.h"
            header.write_text(compatibility)
            subprocess.run(
                [
                    "cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2",
                    "-fsyntax-only", "-DHOTDOG_QMI_PDC_SUBSCRIPTIONS", "-include",
                    str(header), "-I", str(SOURCE),
                    str(SOURCE / "hotdog-radio-bootstrapd.c"),
                    str(SOURCE / "hotdog-qmi-uim.c"), str(SOURCE / "hotdog-uim.c"),
                    str(SOURCE / "hotdog-qmi-pdc.c"), str(SOURCE / "hotdog-pdc.c"),
                    str(SOURCE / "hotdog-mbn.c"), *flags.stdout.split(),
                ],
                check=True,
            )


if __name__ == "__main__":
    unittest.main()
