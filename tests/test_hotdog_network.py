from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]
SOURCE = ROOT / "helpers/hotdog-radio"


class HotdogNetworkTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls._temporary = tempfile.TemporaryDirectory()
        cls.binary = Path(cls._temporary.name) / "hotdog-network-replay"
        subprocess.run(
            [
                "cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2",
                "-I", str(SOURCE), str(SOURCE / "hotdog-network.c"),
                str(SOURCE / "hotdog-network-replay.c"), "-o", str(cls.binary),
            ],
            check=True,
        )

    @classmethod
    def tearDownClass(cls) -> None:
        cls._temporary.cleanup()

    def replay(self, content: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run([str(self.binary)], input=content, text=True, capture_output=True)

    def test_registration_and_dds_gate_data(self) -> None:
        result = self.replay(
            "SUB 0 1\nSUB 1 1\nDDS 1 0\n"
            "NAS 0 home 206 1 lte 1 1\n"
            "START 0 1 1 ipv4 none internet\n"
            "START 1 1 2 ipv4 none internet\n"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("start-result=-13 bearer=0", result.stdout)
        self.assertIn("start-result=-100 bearer=0", result.stdout)

    def test_dual_stack_runtime_settings(self) -> None:
        result = self.replay(
            "SUB 0 1\nNAS 0 roaming 206 1 lte 1 1\nDDS 0 0\n"
            "START 0 7 1 ipv4v6 papchap internet\n"
            "LEG_UP 1 ipv4 100\nLEG_UP 1 ipv6 200\n"
            "UP 1 1428 10.0.0.2 2001:db8::2 1.1.1.1 2606:4700:4700::1111\n"
            "STATUS\n"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("start-result=0 bearer=1", result.stdout)
        self.assertIn("up-result=0", result.stdout)
        self.assertIn("sub0=roaming,lte,206-1,ps1,cs1", result.stdout)
        self.assertIn("bearer1=connected,sub0,mux1,ipv4v6,gen0,h4=100,h6=200,error0,mtu1428", result.stdout)

    def test_dual_stack_rejects_missing_family_address(self) -> None:
        result = self.replay(
            "SUB 0 1\nNAS 0 home 206 1 lte 1 1\nDDS 0 0\n"
            "START 0 1 1 ipv4v6 none internet\n"
            "LEG_UP 1 ipv4 100\nLEG_UP 1 ipv6 200\n"
            "UP 1 1500 10.0.0.2 - 1.1.1.1 8.8.8.8\n"
        )
        self.assertIn("up-result=-22", result.stdout)

    def test_runtime_rejects_malformed_network_addresses(self) -> None:
        result = self.replay(
            "SUB 0 1\nNAS 0 home 206 1 lte 1 1\nDDS 0 0\n"
            "START 0 1 1 ipv4 none internet\nLEG_UP 1 ipv4 100\n"
            "UP 1 1500 not-an-address - 1.1.1.1 8.8.8.8\n"
        )
        self.assertIn("up-result=-22", result.stdout)

    def test_dds_switch_is_bounded_or_explicitly_forced(self) -> None:
        result = self.replay(
            "SUB 0 1\nSUB 1 1\nNAS 0 home 206 1 lte 1 1\n"
            "DDS 0 0\nSTART 0 1 1 ipv4 none internet\n"
            "DDS 1 0\nDDS 1 1\nSTATUS\n"
        )
        self.assertIn("dds-result=-16", result.stdout)
        self.assertIn("dds-result=0", result.stdout)
        self.assertIn("status generation=0 dds=1", result.stdout)
        self.assertIn("bearer1=failed", result.stdout)

    def test_mux_is_unique_and_ssr_invalidates_runtime(self) -> None:
        result = self.replay(
            "SUB 0 1\nNAS 0 home 206 1 lte 1 1\nDDS 0 0\n"
            "START 0 1 5 ipv4 none internet\n"
            "START 0 2 5 ipv6 none ims\n"
            "LEG_UP 1 ipv4 100\n"
            "UP 1 1500 10.0.0.2 - 1.1.1.1 8.8.8.8\nSSR\nSTATUS\n"
        )
        self.assertIn("start-result=-98 bearer=0", result.stdout)
        self.assertIn("ssr-generation=1", result.stdout)
        self.assertIn("sub0=none,unknown,0-0,ps0,cs0", result.stdout)
        self.assertIn("bearer1=failed,sub0,mux5,ipv4,gen0,h4=0,h6=0,error102,mtu0,v4=-,v6=-", result.stdout)

    def test_dual_leg_teardown_requires_exact_handles(self) -> None:
        result = self.replay(
            "SUB 0 1\nNAS 0 home 206 1 lte 1 1\nDDS 0 0\n"
            "START 0 1 1 ipv4v6 none internet\n"
            "LEG_UP 1 ipv4 100\nLEG_UP 1 ipv6 200\n"
            "UP 1 1500 10.0.0.2 2001:db8::2 1.1.1.1 2606:4700:4700::1111\n"
            "STOP_BEGIN 1\nLEG_DOWN 1 ipv4 101\nLEG_DOWN 1 ipv4 100\n"
            "STATUS\nLEG_DOWN 1 ipv6 200\nSTATUS\n"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("stop-begin-result=0 legs=2,ipv4:100,ipv6:200", result.stdout)
        self.assertIn("leg-down-result=-116", result.stdout)
        self.assertIn("bearer1=stopping,sub0,mux1,ipv4v6,gen0,h4=0,h6=200", result.stdout)
        self.assertEqual(result.stdout.count("bearer1="), 1)

    def test_partial_start_failure_stops_started_leg_before_failed_state(self) -> None:
        result = self.replay(
            "SUB 0 1\nNAS 0 home 206 1 lte 1 1\nDDS 0 0\n"
            "START 0 1 1 ipv4v6 none internet\nLEG_UP 1 ipv4 100\n"
            "FAIL 1 5\nSTATUS\nLEG_DOWN 1 ipv4 100\nSTATUS\n"
        )
        self.assertIn("fail-result=0 legs=1", result.stdout)
        self.assertIn("bearer1=stopping,sub0,mux1,ipv4v6,gen0,h4=100,h6=0,error5", result.stdout)
        self.assertIn("bearer1=failed,sub0,mux1,ipv4v6,gen0,h4=0,h6=0,error5", result.stdout)

    def test_malformed_input_fails_closed(self) -> None:
        result = self.replay("START 0 1 ipv4 none internet\n")
        self.assertEqual(result.returncode, 2)
        self.assertIn("line 1", result.stderr)


if __name__ == "__main__":
    unittest.main()
