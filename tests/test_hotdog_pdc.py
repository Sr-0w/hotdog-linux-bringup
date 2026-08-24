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


if __name__ == "__main__":
    unittest.main()
