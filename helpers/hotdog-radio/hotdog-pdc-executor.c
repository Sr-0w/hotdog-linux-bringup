/* SPDX-License-Identifier: GPL-2.0-only */
#include "hotdog-pdc-executor.h"

#include <errno.h>
#include <string.h>

static struct hotdog_pdc_plan *current_plan(struct hotdog_pdc_executor *executor)
{
	return executor->phase == HOTDOG_PDC_EXECUTOR_APPLY ?
		&executor->activation : &executor->recovery;
}

static int mark_attempted(struct hotdog_pdc_executor *executor,
			  const struct hotdog_pdc_operation *operation)
{
	if ((operation->type == HOTDOG_PDC_LOAD_CONFIG ||
	     operation->type == HOTDOG_PDC_SET_SELECTED) &&
	    operation->subscription >= executor->subscription_count)
		return -EINVAL;
	switch (operation->type) {
	case HOTDOG_PDC_LOAD_CONFIG:
		executor->progress.load_attempted[operation->subscription] = true;
		break;
	case HOTDOG_PDC_SET_SELECTED:
		executor->progress.selection_attempted[operation->subscription] = true;
		break;
	case HOTDOG_PDC_ACTIVATE:
		executor->progress.activation_attempted = true;
		break;
	case HOTDOG_PDC_SAVE_ACTIVE:
	case HOTDOG_PDC_SWITCH_MODEM:
	case HOTDOG_PDC_VERIFY_ACTIVE:
	case HOTDOG_PDC_DEACTIVATE:
	case HOTDOG_PDC_RESTORE_SELECTED:
	case HOTDOG_PDC_DELETE_CONFIG:
		break;
	}
	return 0;
}

int hotdog_pdc_executor_init(struct hotdog_pdc_executor *executor,
			     const struct hotdog_pdc_plan *activation,
			     const struct hotdog_pdc_subscription *subscriptions,
			     size_t subscription_count)
{
	if (!executor || !activation || !subscriptions ||
	    activation->count > HOTDOG_PDC_MAX_OPERATIONS ||
	    subscription_count > HOTDOG_PDC_MAX_SUBSCRIPTIONS)
		return -EINVAL;
	memset(executor, 0, sizeof(*executor));
	executor->activation = *activation;
	memcpy(executor->subscriptions, subscriptions,
	       subscription_count * sizeof(subscriptions[0]));
	executor->subscription_count = subscription_count;
	executor->phase = HOTDOG_PDC_EXECUTOR_APPLY;
	return 0;
}

int hotdog_pdc_executor_next(struct hotdog_pdc_executor *executor,
			     const struct hotdog_pdc_operation **operation)
{
	struct hotdog_pdc_plan *plan;
	int result;

	if (!executor || !operation)
		return -EINVAL;
	*operation = NULL;
	if (executor->awaiting)
		return -EBUSY;
	if (executor->phase == HOTDOG_PDC_EXECUTOR_BLOCKED)
		return -EUCLEAN;
	if (executor->phase == HOTDOG_PDC_EXECUTOR_COMMITTED ||
	    executor->phase == HOTDOG_PDC_EXECUTOR_ROLLED_BACK)
		return 0;
	plan = current_plan(executor);
	if (executor->operation_index >= plan->count) {
		executor->phase = executor->phase == HOTDOG_PDC_EXECUTOR_APPLY ?
			HOTDOG_PDC_EXECUTOR_COMMITTED : HOTDOG_PDC_EXECUTOR_ROLLED_BACK;
		return 0;
	}
	*operation = &plan->operations[executor->operation_index];
	if (executor->phase == HOTDOG_PDC_EXECUTOR_APPLY) {
		result = mark_attempted(executor, *operation);
		if (result) {
			executor->phase = HOTDOG_PDC_EXECUTOR_BLOCKED;
			return result;
		}
	}
	executor->awaiting = true;
	return 1;
}

int hotdog_pdc_executor_complete(struct hotdog_pdc_executor *executor, int result)
{
	int recovery_result;

	if (!executor || !executor->awaiting || result > 0)
		return -EINVAL;
	executor->awaiting = false;
	if (!result) {
		executor->operation_index++;
		return 0;
	}
	if (executor->phase == HOTDOG_PDC_EXECUTOR_RECOVER) {
		executor->rollback_failure = result;
		executor->phase = HOTDOG_PDC_EXECUTOR_BLOCKED;
		return result;
	}
	executor->failure = result;
	recovery_result = hotdog_pdc_plan_recovery(
		executor->subscriptions, executor->subscription_count,
		&executor->progress, &executor->recovery);
	if (recovery_result) {
		executor->rollback_failure = recovery_result;
		executor->phase = HOTDOG_PDC_EXECUTOR_BLOCKED;
		return recovery_result;
	}
	executor->phase = HOTDOG_PDC_EXECUTOR_RECOVER;
	executor->operation_index = 0;
	return result;
}

const char *hotdog_pdc_executor_phase_name(enum hotdog_pdc_executor_phase phase)
{
	switch (phase) {
	case HOTDOG_PDC_EXECUTOR_APPLY: return "apply";
	case HOTDOG_PDC_EXECUTOR_RECOVER: return "recover";
	case HOTDOG_PDC_EXECUTOR_COMMITTED: return "committed";
	case HOTDOG_PDC_EXECUTOR_ROLLED_BACK: return "rolled-back";
	case HOTDOG_PDC_EXECUTOR_BLOCKED: return "blocked";
	}
	return "invalid";
}
