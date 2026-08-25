from __future__ import annotations

from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "helpers/hotdog-radio"

HARNESS = r'''
#include "hotdog-ims-executor.h"
#include <errno.h>
#include <stdio.h>
#include <string.h>

static void show(const char *step, struct hotdog_ims_executor *e,
                 struct hotdog_ims_executor_operation *o) {
    printf("%s phase=%s action=%s leg=%u handle=%u error=%u residue=%u%u%u\n",
           step, hotdog_ims_executor_phase_name(e->phase),
           hotdog_ims_executor_action_name(o->action), o->leg, o->packet_handle,
           e->error, e->packet_handles[0] != 0, e->clients_owned, e->link_owned);
}

static void up(struct hotdog_ims_executor *e,
               struct hotdog_ims_executor_operation *o) {
    hotdog_ims_executor_begin(e, HOTDOG_IP_V4V6, o);
    hotdog_ims_executor_link_added(e, "ims0", 11, o);
    hotdog_ims_executor_client_allocated(e, 0, o);
    hotdog_ims_executor_client_allocated(e, 1, o);
    hotdog_ims_executor_leg_bound(e, 0, o);
    hotdog_ims_executor_leg_bound(e, 1, o);
    hotdog_ims_executor_leg_started(e, 0, 100, o);
    hotdog_ims_executor_leg_started(e, 1, 200, o);
    hotdog_ims_executor_settings_read(e, 0, o);
    hotdog_ims_executor_settings_read(e, 1, o);
    hotdog_ims_executor_configured(e, o);
}

int main(int argc, char **argv) {
    struct hotdog_ims_executor e;
    struct hotdog_ims_executor_operation o;
    if (argc != 2) return 2;
    hotdog_ims_executor_init(&e);
    if (!strcmp(argv[1], "success")) {
        hotdog_ims_executor_begin(&e, HOTDOG_IP_V4V6, &o); show("begin",&e,&o);
        hotdog_ims_executor_link_added(&e,"ims0",11,&o); show("link",&e,&o);
        hotdog_ims_executor_client_allocated(&e,0,&o); show("client0",&e,&o);
        hotdog_ims_executor_client_allocated(&e,1,&o); show("client1",&e,&o);
        hotdog_ims_executor_leg_bound(&e,0,&o); show("bind0",&e,&o);
        hotdog_ims_executor_leg_bound(&e,1,&o); show("bind1",&e,&o);
        hotdog_ims_executor_leg_started(&e,0,100,&o); show("start0",&e,&o);
        hotdog_ims_executor_leg_started(&e,1,200,&o); show("start1",&e,&o);
        hotdog_ims_executor_settings_read(&e,0,&o); show("settings0",&e,&o);
        hotdog_ims_executor_settings_read(&e,1,&o); show("settings1",&e,&o);
        hotdog_ims_executor_configured(&e,&o); show("configured",&e,&o);
        return 0;
    }
    if (!strcmp(argv[1], "rollback")) {
        hotdog_ims_executor_begin(&e,HOTDOG_IP_V4V6,&o);
        hotdog_ims_executor_link_added(&e,"ims0",11,&o);
        hotdog_ims_executor_client_allocated(&e,0,&o);
        hotdog_ims_executor_client_allocated(&e,1,&o);
        hotdog_ims_executor_leg_bound(&e,0,&o);
        hotdog_ims_executor_leg_bound(&e,1,&o);
        hotdog_ims_executor_leg_started(&e,0,100,&o);
        hotdog_ims_executor_fail(&e,EIO,&o); show("fail",&e,&o);
        hotdog_ims_executor_leg_stopped(&e,0,100,&o); show("stopped",&e,&o);
        hotdog_ims_executor_clients_released(&e,&o); show("released",&e,&o);
        hotdog_ims_executor_link_deleted(&e,&o); show("deleted",&e,&o);
        return 0;
    }
    if (!strcmp(argv[1], "allocfail")) {
        hotdog_ims_executor_begin(&e,HOTDOG_IP_V4V6,&o);
        hotdog_ims_executor_link_added(&e,"ims0",11,&o);
        hotdog_ims_executor_client_allocated(&e,0,&o);
        hotdog_ims_executor_fail(&e,ENOMEM,&o); show("fail",&e,&o);
        hotdog_ims_executor_clients_released(&e,&o); show("released",&e,&o);
        hotdog_ims_executor_link_deleted(&e,&o); show("deleted",&e,&o);
        return 0;
    }
    if (!strcmp(argv[1], "blocked")) {
        up(&e,&o); hotdog_ims_executor_stop(&e,&o); show("stop",&e,&o);
        hotdog_ims_executor_cleanup_failed(&e,EIO); show("blocked",&e,&o);
        return 0;
    }
    if (!strcmp(argv[1], "ssr")) {
        up(&e,&o); hotdog_ims_executor_ssr(&e,&o); show("ssr",&e,&o);
        hotdog_ims_executor_link_deleted(&e,&o); show("deleted",&e,&o);
        return 0;
    }
    return 2;
}
'''


class HotdogImsExecutorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.temp = tempfile.TemporaryDirectory()
        source = Path(cls.temp.name) / "executor.c"
        source.write_text(HARNESS, encoding="ascii")
        cls.binary = Path(cls.temp.name) / "executor"
        subprocess.run(
            ["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2",
             "-I", str(SOURCE), str(SOURCE / "hotdog-ims-executor.c"),
             str(source), "-o", str(cls.binary)], check=True,
        )

    @classmethod
    def tearDownClass(cls) -> None:
        cls.temp.cleanup()

    def run_mode(self, mode: str) -> str:
        return subprocess.run(
            [str(self.binary), mode], check=True, capture_output=True, text=True
        ).stdout

    def test_success_path_orders_every_remote_operation(self) -> None:
        output = self.run_mode("success")
        actions = [line.split("action=")[1].split()[0] for line in output.splitlines()]
        self.assertEqual(actions, [
            "add-link", "allocate-clients", "allocate-clients", "bind-leg", "bind-leg",
            "start-leg", "start-leg", "read-settings", "read-settings",
            "configure-link", "publish-up",
        ])

    def test_partial_start_rolls_back_handle_client_then_link(self) -> None:
        output = self.run_mode("rollback")
        self.assertIn("fail phase=stopping action=stop-leg leg=0 handle=100", output)
        self.assertIn("stopped phase=releasing-clients action=release-clients", output)
        self.assertIn("released phase=deleting-link action=delete-link", output)
        self.assertIn("deleted phase=failed action=publish-down", output)

    def test_cleanup_failure_preserves_residue_and_blocks(self) -> None:
        output = self.run_mode("blocked")
        self.assertIn("blocked phase=blocked", output)
        self.assertIn("residue=111", output)

    def test_partial_client_allocation_is_owned_for_rollback(self) -> None:
        output = self.run_mode("allocfail")
        self.assertIn("fail phase=releasing-clients action=release-clients", output)
        self.assertIn("released phase=deleting-link action=delete-link", output)
        self.assertIn("deleted phase=failed action=publish-down", output)

    def test_ssr_drops_stale_remote_ownership_before_local_link_delete(self) -> None:
        output = self.run_mode("ssr")
        self.assertIn("ssr phase=deleting-link action=delete-link", output)
        self.assertIn("error=102 residue=001", output)
        self.assertIn("deleted phase=failed action=publish-down", output)


if __name__ == "__main__":
    unittest.main()
