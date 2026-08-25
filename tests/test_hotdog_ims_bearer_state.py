from __future__ import annotations

from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "helpers/hotdog-radio"

HARNESS = r'''
#include "hotdog-ims-bearer-state.h"
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv) {
    struct hotdog_ims_bearer_runtime_state state = {0}, readback = {0};
    struct hotdog_ims_bearer_subscription_state *sub = &state.subscriptions[0];
    if (argc != 3) return 2;
    if (!strcmp(argv[1], "read"))
        return hotdog_ims_bearer_runtime_read(argv[2], &readback) ? 4 : 0;
    if (strcmp(argv[1], "write")) return 2;
    strcpy(state.boot_id, "01234567-89ab-cdef-0123-456789abcdef");
    state.generation = 7;
    sub->populated = true; sub->status = HOTDOG_IMS_BEARER_UP;
    sub->profile_selected = true; sub->profile = 7; sub->family = HOTDOG_IP_V4V6;
    sub->mux_id = 11; strcpy(sub->ifname, "ims0"); sub->pcscf_domain_count = 1;
    if (hotdog_ims_bearer_runtime_write(argv[2], &state)) return 3;
    if (hotdog_ims_bearer_runtime_read(argv[2], &readback)) return 4;
    printf("generation=%u status=%s profile=%u family=%s mux=%u ifname=%s pcscf=%zu/%zu\n",
           readback.generation,
           hotdog_ims_bearer_runtime_status_name(readback.subscriptions[0].status),
           readback.subscriptions[0].profile,
           hotdog_ip_family_name(readback.subscriptions[0].family),
           readback.subscriptions[0].mux_id, readback.subscriptions[0].ifname,
           readback.subscriptions[0].pcscf_address_count,
           readback.subscriptions[0].pcscf_domain_count);
}
'''


class HotdogImsBearerStateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        flags = subprocess.run(
            ["pkg-config", "--cflags", "--libs", "glib-2.0"], check=True,
            capture_output=True, text=True,
        ).stdout.split()
        cls.temp = tempfile.TemporaryDirectory()
        source = Path(cls.temp.name) / "state.c"
        source.write_text(HARNESS, encoding="ascii")
        cls.binary = Path(cls.temp.name) / "state"
        subprocess.run(
            ["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2",
             "-I", str(SOURCE), str(SOURCE / "hotdog-ims-bearer-state.c"),
             str(SOURCE / "hotdog-network.c"), str(source), *flags,
             "-o", str(cls.binary)], check=True,
        )

    @classmethod
    def tearDownClass(cls) -> None:
        cls.temp.cleanup()

    def test_secure_roundtrip_preserves_boot_bound_up_state(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "ims-bearer-state"
            output = subprocess.run(
                [str(self.binary), "write", str(path)], check=True,
                capture_output=True, text=True,
            ).stdout.strip()
            self.assertEqual(
                output,
                "generation=7 status=up profile=7 family=ipv4v6 mux=11 "
                "ifname=ims0 pcscf=0/1",
            )
            self.assertEqual(path.stat().st_mode & 0o777, 0o644)

    def test_unknown_or_duplicate_keys_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "ims-bearer-state"
            subprocess.run(
                [str(self.binary), "write", str(path)], check=True,
                capture_output=True, text=True,
            )
            original = path.read_text(encoding="utf-8")
            path.write_text(original + "unknown=value\n", encoding="utf-8")
            result = subprocess.run(
                [str(self.binary), "read", str(path)], capture_output=True, text=True
            )
            self.assertNotEqual(result.returncode, 0)

    def test_blocked_state_requires_explicit_residue(self) -> None:
        source = (SOURCE / "hotdog-ims-bearer-state.c").read_text(encoding="ascii")
        self.assertIn("!sub->error || !sub->residue || !sub->mux_id", source)
        self.assertIn("O_NOFOLLOW", source)
        self.assertIn("S_IWGRP | S_IWOTH", source)


if __name__ == "__main__":
    unittest.main()
