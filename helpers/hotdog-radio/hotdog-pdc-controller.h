/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef HOTDOG_PDC_CONTROLLER_H
#define HOTDOG_PDC_CONTROLLER_H

#include "hotdog-pdc-executor.h"
#include "hotdog-qmi-pdc-backend.h"

struct hotdog_pdc_controller;
typedef void (*hotdog_pdc_controller_done)(
	struct hotdog_pdc_controller *controller, int result,
	enum hotdog_pdc_executor_phase phase, void *user_data);
typedef void (*hotdog_pdc_controller_switch)(
	struct hotdog_pdc_controller *controller, void *user_data);

struct hotdog_pdc_controller {
	struct hotdog_pdc_executor executor;
	struct hotdog_qmi_pdc_backend *backend;
	struct hotdog_qmi_pdc_request request;
	const struct hotdog_pdc_catalog *catalog;
	const char *mcfg_root;
	hotdog_pdc_controller_done done;
	hotdog_pdc_controller_switch switch_required;
	void *user_data;
	uint32_t token;
	bool started;
	bool waiting_switch;
	bool finished;
};

int hotdog_pdc_controller_init(
	struct hotdog_pdc_controller *controller,
	struct hotdog_qmi_pdc_backend *backend,
	const struct hotdog_pdc_plan *activation,
	const struct hotdog_pdc_subscription *subscriptions,
	size_t subscription_count, const struct hotdog_pdc_catalog *catalog,
	const char *mcfg_root, hotdog_pdc_controller_done done,
	hotdog_pdc_controller_switch switch_required, void *user_data);
int hotdog_pdc_controller_start(struct hotdog_pdc_controller *controller);
void hotdog_pdc_controller_transport_lost(struct hotdog_pdc_controller *controller);
int hotdog_pdc_controller_switch_complete(struct hotdog_pdc_controller *controller,
					  int result);
void hotdog_pdc_controller_cancel(struct hotdog_pdc_controller *controller);

#endif
