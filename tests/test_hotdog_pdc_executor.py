from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]
SOURCE = ROOT / "helpers" / "hotdog-radio"


HARNESS = r'''#include "hotdog-pdc-executor.h"
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void set_id(struct hotdog_pdc_id *id, const char *text) {
    id->length = strlen(text);
    memcpy(id->value, text, id->length);
}
static void add(struct hotdog_pdc_plan *plan, enum hotdog_pdc_operation_type type,
                unsigned int sub, const char *id) {
    struct hotdog_pdc_operation *op = &plan->operations[plan->count++];
    op->type = type;
    op->subscription = sub;
    if (id) set_id(&op->id, id);
}
static void setup(struct hotdog_pdc_executor *executor) {
    struct hotdog_pdc_subscription sub = { .populated = true, .changed = true,
                                            .selected_loaded_by_us = true };
    struct hotdog_pdc_plan plan = { 0 };
    set_id(&sub.previous, "old");
    set_id(&sub.selected, "current");
    add(&plan, HOTDOG_PDC_LOAD_CONFIG, 0, "current");
    add(&plan, HOTDOG_PDC_SET_SELECTED, 0, "current");
    add(&plan, HOTDOG_PDC_ACTIVATE, 0, NULL);
    add(&plan, HOTDOG_PDC_SWITCH_MODEM, 0, NULL);
    add(&plan, HOTDOG_PDC_VERIFY_ACTIVE, 0, "current");
    if (hotdog_pdc_executor_init(executor, &plan, &sub, 1)) _Exit(90);
}
static enum hotdog_pdc_operation_type next_type(struct hotdog_pdc_executor *executor) {
    const struct hotdog_pdc_operation *operation = NULL;
    if (hotdog_pdc_executor_next(executor, &operation) != 1) _Exit(91);
    return operation->type;
}
int main(int argc, char **argv) {
    struct hotdog_pdc_executor executor;
    const struct hotdog_pdc_operation *operation = NULL;
    (void)argc;
    setup(&executor);
    if (!strcmp(argv[1], "success")) {
        while (hotdog_pdc_executor_next(&executor, &operation) == 1)
            if (hotdog_pdc_executor_complete(&executor, 0)) return 1;
        printf("phase=%s\n", hotdog_pdc_executor_phase_name(executor.phase));
        return executor.phase == HOTDOG_PDC_EXECUTOR_COMMITTED ? 0 : 2;
    }
    if (next_type(&executor) != HOTDOG_PDC_LOAD_CONFIG) return 3;
    if (!strcmp(argv[1], "load-fail")) {
        hotdog_pdc_executor_complete(&executor, -EIO);
        printf("recovery0=%s\n", hotdog_pdc_operation_name(next_type(&executor)));
        hotdog_pdc_executor_complete(&executor, 0);
        hotdog_pdc_executor_next(&executor, &operation);
        printf("phase=%s failure=%d\n", hotdog_pdc_executor_phase_name(executor.phase),
               executor.failure);
        return 0;
    }
    hotdog_pdc_executor_complete(&executor, 0);
    if (next_type(&executor) != HOTDOG_PDC_SET_SELECTED) return 4;
    if (!strcmp(argv[1], "set-fail")) {
        int i;
        hotdog_pdc_executor_complete(&executor, -EPROTO);
        for (i = 0; i < 3; i++) {
            printf("recovery%d=%s\n", i,
                   hotdog_pdc_operation_name(next_type(&executor)));
            hotdog_pdc_executor_complete(&executor, 0);
        }
        hotdog_pdc_executor_next(&executor, &operation);
        printf("phase=%s\n", hotdog_pdc_executor_phase_name(executor.phase));
        return 0;
    }
    if (!strcmp(argv[1], "rollback-fail")) {
        hotdog_pdc_executor_complete(&executor, -EIO);
        next_type(&executor);
        hotdog_pdc_executor_complete(&executor, -EREMOTEIO);
        printf("phase=%s rollback_failure=%d\n",
               hotdog_pdc_executor_phase_name(executor.phase), executor.rollback_failure);
        return 0;
    }
    return 5;
}
'''


class HotdogPdcExecutorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls._temporary = tempfile.TemporaryDirectory()
        source = Path(cls._temporary.name) / "executor-harness.c"
        cls.binary = Path(cls._temporary.name) / "executor-harness"
        source.write_text(HARNESS)
        subprocess.run(
            [
                "cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2",
                "-I", str(SOURCE), str(SOURCE / "hotdog-mbn.c"),
                str(SOURCE / "hotdog-pdc.c"), str(SOURCE / "hotdog-pdc-executor.c"),
                str(source), "-o", str(cls.binary),
            ],
            check=True,
        )

    @classmethod
    def tearDownClass(cls) -> None:
        cls._temporary.cleanup()

    def run_case(self, name: str) -> str:
        return subprocess.run(
            [str(self.binary), name], check=True, capture_output=True, text=True,
        ).stdout

    def test_success_requires_every_operation_confirmation(self) -> None:
        self.assertEqual(self.run_case("success").strip(), "phase=committed")

    def test_load_failure_deletes_only_partial_profile(self) -> None:
        output = self.run_case("load-fail")
        self.assertIn("recovery0=delete-config", output)
        self.assertIn("phase=rolled-back failure=-5", output)

    def test_selection_failure_restores_without_activation(self) -> None:
        output = self.run_case("set-fail")
        self.assertEqual(
            [line for line in output.splitlines() if line.startswith("recovery")],
            ["recovery0=deactivate", "recovery1=restore-selected", "recovery2=delete-config"],
        )
        self.assertIn("phase=rolled-back", output)

    def test_rollback_failure_is_blocked_with_residue(self) -> None:
        output = self.run_case("rollback-fail")
        self.assertIn("phase=blocked rollback_failure=-121", output)


if __name__ == "__main__":
    unittest.main()
