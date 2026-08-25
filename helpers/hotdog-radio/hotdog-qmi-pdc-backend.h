/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef HOTDOG_QMI_PDC_BACKEND_H
#define HOTDOG_QMI_PDC_BACKEND_H

#include "hotdog-qmi-pdc-dispatch.h"

#include <gio/gio.h>
#include <libqmi-glib.h>

#include <stdbool.h>
#include <stdint.h>

struct hotdog_qmi_pdc_backend;
typedef void (*hotdog_qmi_pdc_backend_done)(
	struct hotdog_qmi_pdc_backend *backend, int result,
	uint16_t remote_result, void *user_data);

struct hotdog_qmi_pdc_backend {
	QmiClientPdc *client;
	GCancellable *cancellable;
	struct hotdog_qmi_pdc_request *request;
	uint32_t *token_counter;
	hotdog_qmi_pdc_backend_done done;
	void *user_data;
	gulong indication_handler;
	guint timeout_id;
	bool active;
};

int hotdog_qmi_pdc_backend_init(struct hotdog_qmi_pdc_backend *backend,
				QmiClientPdc *client, GCancellable *cancellable,
				uint32_t *token_counter);
int hotdog_qmi_pdc_backend_start(struct hotdog_qmi_pdc_backend *backend,
				 struct hotdog_qmi_pdc_request *request,
				 hotdog_qmi_pdc_backend_done done,
				 void *user_data);
void hotdog_qmi_pdc_backend_cancel(struct hotdog_qmi_pdc_backend *backend);
void hotdog_qmi_pdc_backend_transport_lost(struct hotdog_qmi_pdc_backend *backend);
int hotdog_qmi_pdc_backend_rebind(struct hotdog_qmi_pdc_backend *backend,
				  QmiClientPdc *client, GCancellable *cancellable);
void hotdog_qmi_pdc_backend_clear(struct hotdog_qmi_pdc_backend *backend);

#endif
