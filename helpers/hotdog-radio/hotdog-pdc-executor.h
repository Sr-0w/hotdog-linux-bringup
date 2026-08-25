/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef HOTDOG_PDC_EXECUTOR_H
#define HOTDOG_PDC_EXECUTOR_H

#include "hotdog-pdc.h"

#include <stdbool.h>
#include <stddef.h>

enum hotdog_pdc_executor_phase {
	HOTDOG_PDC_EXECUTOR_APPLY,
	HOTDOG_PDC_EXECUTOR_RECOVER,
	HOTDOG_PDC_EXECUTOR_COMMITTED,
	HOTDOG_PDC_EXECUTOR_ROLLED_BACK,
	HOTDOG_PDC_EXECUTOR_BLOCKED,
};

struct hotdog_pdc_executor {
	struct hotdog_pdc_plan activation;
	struct hotdog_pdc_plan recovery;
	struct hotdog_pdc_subscription subscriptions[HOTDOG_PDC_MAX_SUBSCRIPTIONS];
	struct hotdog_pdc_progress progress;
	size_t subscription_count;
	size_t operation_index;
	int failure;
	int rollback_failure;
	enum hotdog_pdc_executor_phase phase;
	bool awaiting;
};

int hotdog_pdc_executor_init(struct hotdog_pdc_executor *executor,
			     const struct hotdog_pdc_plan *activation,
			     const struct hotdog_pdc_subscription *subscriptions,
			     size_t subscription_count);
int hotdog_pdc_executor_next(struct hotdog_pdc_executor *executor,
			     const struct hotdog_pdc_operation **operation);
int hotdog_pdc_executor_complete(struct hotdog_pdc_executor *executor, int result);
const char *hotdog_pdc_executor_phase_name(enum hotdog_pdc_executor_phase phase);

#endif
