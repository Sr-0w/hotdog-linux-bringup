from __future__ import annotations

from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "helpers/hotdog-radio"

HARNESS = r'''
#include "hotdog-ims-netconfig.h"
#include <errno.h>
#include <stdio.h>
#include <string.h>

struct runner_state { unsigned int forward; int fail_forward; bool fail_rollback; };

static bool rollback_command(const struct hotdog_ims_netconfig_command *command) {
    unsigned int i;
    for (i = 0; i < command->argc; i++)
        if (!strcmp(command->argv[i], "del") || !strcmp(command->argv[i], "down"))
            return true;
    return false;
}

static int run(const struct hotdog_ims_netconfig_command *command, void *data) {
    struct runner_state *state = data;
    if (rollback_command(command)) {
        if (state->fail_rollback) { state->fail_rollback = false; return -EIO; }
        return 0;
    }
    state->forward++;
    return state->fail_forward == (int)state->forward ? -EREMOTEIO : 0;
}

static void print_command(const struct hotdog_ims_netconfig_command *command) {
    unsigned int i;
    for (i = 0; i < command->argc; i++) printf("%s%s", i ? " " : "", command->argv[i]);
}

static struct hotdog_bearer_runtime runtime(void) {
    struct hotdog_bearer_runtime value = { .mtu=1428,.ipv4_prefix=30,.ipv6_prefix=64 };
    strcpy(value.ipv4,"10.0.0.2"); strcpy(value.ipv4_gateway,"10.0.0.1");
    strcpy(value.ipv6,"2001:db8::2"); strcpy(value.ipv6_gateway,"2001:db8::1");
    return value;
}

int main(int argc, char **argv) {
    struct hotdog_ims_netconfig_plan plan;
    struct hotdog_bearer_runtime rt = runtime();
    struct runner_state runner = {0};
    size_t i;
    int result;
    if (argc != 2) return 2;
    if (!strcmp(argv[1],"plan")) {
        result=hotdog_ims_netconfig_plan_build("/sbin/ip","rmnet_ipa0",false,
                 "ims0",1,HOTDOG_IP_V4V6,&rt,&plan);
        printf("result=%d count=%zu table=%u priority=%u mark=0x%08x\n",
               result,plan.count,plan.table,plan.priority,plan.fwmark);
        for(i=0;i<plan.count;i++) { printf("%zu apply=",i); print_command(&plan.steps[i].apply);
            printf(" | rollback="); print_command(&plan.steps[i].rollback); printf("\n"); }
        return 0;
    }
    hotdog_ims_netconfig_plan_build("/sbin/ip","rmnet_ipa0",true,
             "ims0",0,HOTDOG_IP_V4V6,&rt,&plan);
    if (!strcmp(argv[1],"success")) {
        result=hotdog_ims_netconfig_apply(&plan,run,&runner);
        printf("apply=%d forward=%u residue=%u ",result,runner.forward,plan.residue);
        result=hotdog_ims_netconfig_rollback(&plan,run,&runner);
        printf("rollback=%d residue=%u\n",result,plan.residue); return 0;
    }
    if (!strcmp(argv[1],"applyfail")) {
        runner.fail_forward=4; result=hotdog_ims_netconfig_apply(&plan,run,&runner);
        printf("result=%d forward=%u residue=%u apply_error=%u rollback_error=%u\n",
               result,runner.forward,plan.residue,plan.apply_error,plan.rollback_error); return 0;
    }
    if (!strcmp(argv[1],"rollbackfail")) {
        hotdog_ims_netconfig_apply(&plan,run,&runner); runner.fail_rollback=true;
        result=hotdog_ims_netconfig_rollback(&plan,run,&runner);
        printf("first=%d residue=%u ",result,plan.residue);
        result=hotdog_ims_netconfig_rollback(&plan,run,&runner);
        printf("retry=%d residue=%u\n",result,plan.residue); return 0;
    }
    return 2;
}
'''


class HotdogImsNetconfigTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        flags = subprocess.run(
            ["pkg-config", "--cflags", "--libs", "gio-2.0", "glib-2.0"],
            check=True, capture_output=True, text=True,
        ).stdout.split()
        cls.temp = tempfile.TemporaryDirectory()
        source = Path(cls.temp.name) / "netconfig.c"
        source.write_text(HARNESS, encoding="ascii")
        cls.binary = Path(cls.temp.name) / "netconfig"
        subprocess.run(
            ["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2",
             "-I", str(SOURCE), str(SOURCE / "hotdog-ims-netconfig.c"),
             str(source), *flags, "-o", str(cls.binary)], check=True,
        )

    @classmethod
    def tearDownClass(cls) -> None:
        cls.temp.cleanup()

    def run_mode(self, mode: str) -> str:
        return subprocess.run(
            [str(self.binary), mode], check=True, capture_output=True, text=True
        ).stdout

    def test_dual_stack_plan_has_symmetric_marked_routes(self) -> None:
        output = self.run_mode("plan")
        self.assertIn("result=0 count=8 table=12001 priority=12001 mark=0x494d5301", output)
        self.assertIn("/sbin/ip -4 address add 10.0.0.2/30 dev ims0", output)
        self.assertIn("/sbin/ip -6 address add 2001:db8::2/64 dev ims0 nodad", output)
        self.assertIn("fwmark 0x494d5301 lookup 12001", output)
        self.assertIn("rollback=/sbin/ip -6 rule del priority 12001 fwmark 0x494d5301", output)

    def test_success_and_rollback_clear_every_owned_step(self) -> None:
        self.assertEqual(
            self.run_mode("success").strip(),
            "apply=0 forward=7 residue=0 rollback=0 residue=0",
        )

    def test_apply_failure_rolls_back_and_preserves_original_error(self) -> None:
        self.assertEqual(
            self.run_mode("applyfail").strip(),
            "result=-121 forward=4 residue=0 apply_error=121 rollback_error=0",
        )

    def test_rollback_residue_is_retryable(self) -> None:
        self.assertEqual(
            self.run_mode("rollbackfail").strip(),
            "first=-5 residue=1 retry=0 residue=0",
        )

    def test_runner_uses_argv_without_shell(self) -> None:
        source = (SOURCE / "hotdog-ims-netconfig.c").read_text(encoding="ascii")
        self.assertIn("g_spawn_sync", source)
        self.assertNotIn("sh -c", source)
        self.assertNotIn("system(", source)

    def test_global_base_link_command_is_separate_from_subscription_plan(self) -> None:
        source = (SOURCE / "hotdog-ims-netconfig.c").read_text(encoding="ascii")
        self.assertIn("hotdog_ims_netconfig_base_command", source)
        self.assertIn('up ? "up" : "down"', source)


if __name__ == "__main__":
    unittest.main()
