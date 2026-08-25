/* SPDX-License-Identifier: GPL-2.0-only */
#include "hotdog-pdc-controller.h"

#include <errno.h>
#include <string.h>

static void controller_drive(struct hotdog_pdc_controller *controller);

static void controller_finish(struct hotdog_pdc_controller *controller)
{
	int result;

	if (controller->finished)
		return;
	controller->finished = true;
	switch (controller->executor.phase) {
	case HOTDOG_PDC_EXECUTOR_COMMITTED:
		result = 0;
		break;
	case HOTDOG_PDC_EXECUTOR_ROLLED_BACK:
		result = controller->executor.failure ? controller->executor.failure : -ECANCELED;
		break;
	case HOTDOG_PDC_EXECUTOR_BLOCKED:
		result = controller->executor.rollback_failure ?
			controller->executor.rollback_failure : -EUCLEAN;
		break;
	case HOTDOG_PDC_EXECUTOR_APPLY:
	case HOTDOG_PDC_EXECUTOR_RECOVER:
		result = -EINPROGRESS;
		break;
	}
	controller->done(controller, result, controller->executor.phase,
			 controller->user_data);
}

static void backend_done(struct hotdog_qmi_pdc_backend *backend, int result,
			 uint16_t remote_result, void *user_data)
{
	struct hotdog_pdc_controller *controller = user_data;

	(void)backend;
	(void)remote_result;
	hotdog_pdc_executor_complete(&controller->executor, result);
	hotdog_qmi_pdc_request_clear(&controller->request);
	controller_drive(controller);
}

static void controller_drive(struct hotdog_pdc_controller *controller)
{
	const struct hotdog_pdc_operation *operation;
	int result;

	if (controller->finished || controller->waiting_switch)
		return;
	result = hotdog_pdc_executor_next(&controller->executor, &operation);
	if (!result) {
		controller_finish(controller);
		return;
	}
	if (result < 0) {
		controller->executor.phase = HOTDOG_PDC_EXECUTOR_BLOCKED;
		controller->executor.rollback_failure = result;
		controller_finish(controller);
		return;
	}
	result = hotdog_qmi_pdc_request_prepare(
		&controller->request, operation, controller->catalog,
		controller->mcfg_root, ++controller->token);
	if (result) {
		hotdog_pdc_executor_complete(&controller->executor, result);
		controller_drive(controller);
		return;
	}
	result = hotdog_qmi_pdc_backend_start(
		controller->backend, &controller->request, backend_done, controller);
	if (result == -EINPROGRESS &&
	    controller->request.type == HOTDOG_QMI_PDC_REQUEST_SWITCH) {
		controller->waiting_switch = true;
		controller->switch_required(controller, controller->user_data);
		return;
	}
	if (result) {
		hotdog_pdc_executor_complete(&controller->executor, result);
		hotdog_qmi_pdc_request_clear(&controller->request);
		controller_drive(controller);
	}
}

int hotdog_pdc_controller_init(
	struct hotdog_pdc_controller *controller,
	struct hotdog_qmi_pdc_backend *backend,
	const struct hotdog_pdc_plan *activation,
	const struct hotdog_pdc_subscription *subscriptions,
	size_t subscription_count, const struct hotdog_pdc_catalog *catalog,
	const char *mcfg_root, hotdog_pdc_controller_done done,
	hotdog_pdc_controller_switch switch_required, void *user_data)
{
	int result;

	if (!controller || !backend || !catalog || !mcfg_root || !done ||
	    !switch_required)
		return -EINVAL;
	memset(controller, 0, sizeof(*controller));
	result = hotdog_pdc_executor_init(
		&controller->executor, activation, subscriptions, subscription_count);
	if (result)
		return result;
	controller->backend = backend;
	controller->catalog = catalog;
	controller->mcfg_root = mcfg_root;
	controller->done = done;
	controller->switch_required = switch_required;
	controller->user_data = user_data;
	return 0;
}

int hotdog_pdc_controller_start(struct hotdog_pdc_controller *controller)
{
	if (!controller || controller->started)
		return -EINVAL;
	controller->started = true;
	controller_drive(controller);
	return 0;
}

void hotdog_pdc_controller_transport_lost(struct hotdog_pdc_controller *controller)
{
	if (!controller || controller->finished || controller->waiting_switch)
		return;
	hotdog_qmi_pdc_backend_transport_lost(controller->backend);
}

int hotdog_pdc_controller_switch_complete(struct hotdog_pdc_controller *controller,
					  int result)
{
	if (!controller || !controller->waiting_switch || result > 0)
		return -EINVAL;
	controller->waiting_switch = false;
	hotdog_pdc_executor_complete(&controller->executor, result);
	hotdog_qmi_pdc_request_clear(&controller->request);
	controller_drive(controller);
	return result;
}

void hotdog_pdc_controller_cancel(struct hotdog_pdc_controller *controller)
{
	if (!controller || controller->finished)
		return;
	if (controller->backend->active)
		hotdog_qmi_pdc_backend_cancel(controller->backend);
	else if (controller->executor.awaiting) {
		hotdog_pdc_executor_complete(&controller->executor, -ECANCELED);
		hotdog_qmi_pdc_request_clear(&controller->request);
		controller->waiting_switch = false;
		controller_drive(controller);
	}
}
