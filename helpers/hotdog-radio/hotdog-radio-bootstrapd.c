/* SPDX-License-Identifier: GPL-2.0-only */
#include "hotdog-qmi-uim.h"

#include <gio/gio.h>
#include <libqmi-glib.h>
#include <libqrtr-glib.h>
#include <stdio.h>

struct bootstrap {
	GMainLoop *loop;
	GCancellable *cancellable;
	QrtrBus *bus;
	QmiDevice *device;
	QmiClientUim *uim;
	unsigned int node;
	int result;
};

static void finish(struct bootstrap *bootstrap, int result)
{
	bootstrap->result = result;
	g_main_loop_quit(bootstrap->loop);
}

static void print_inventory(const struct hotdog_uim_inventory *inventory)
{
	size_t i;

	printf("slots=%zu gw_sessions=%zu onex_sessions=%zu isim_sessions=%zu\n",
	       inventory->slot_count, inventory->gw_count,
	       inventory->onex_count, inventory->isim_count);
	for (i = 0; i < inventory->slot_count; i++) {
		printf("slot%zu=%s apps=%zu error=%d\n", i + 1,
		       hotdog_uim_card_state_name(inventory->slots[i].state),
		       inventory->slots[i].app_count, inventory->slots[i].card_error);
	}
	for (i = 0; i < inventory->gw_count; i++) {
		const struct hotdog_uim_session *session = &inventory->gw_sessions[i];
		printf("sub%u=slot%u app%u %s %s\n", session->subscription,
		       session->physical_slot, session->app_index,
		       hotdog_uim_app_type_name(session->app_type),
		       hotdog_uim_app_state_name(session->app_state));
	}
}

static void card_status_ready(QmiClientUim *client, GAsyncResult *res,
			      struct bootstrap *bootstrap)
{
	QmiMessageUimGetCardStatusOutput *output;
	struct hotdog_uim_inventory inventory;
	GError *error = NULL;
	int result;

	output = qmi_client_uim_get_card_status_finish(client, res, &error);
	if (!output) {
		g_printerr("UIM card status failed: %s\n", error->message);
		g_clear_error(&error);
		finish(bootstrap, 1);
		return;
	}
	result = hotdog_qmi_uim_decode(output, &inventory);
	qmi_message_uim_get_card_status_output_unref(output);
	if (result) {
		g_printerr("UIM inventory rejected: %d\n", result);
		finish(bootstrap, 1);
		return;
	}
	print_inventory(&inventory);
	finish(bootstrap, 0);
}

static void client_ready(QmiDevice *device, GAsyncResult *res,
			 struct bootstrap *bootstrap)
{
	QmiClient *client;
	GError *error = NULL;

	client = qmi_device_allocate_client_finish(device, res, &error);
	if (!client) {
		g_printerr("UIM client allocation failed: %s\n", error->message);
		g_clear_error(&error);
		finish(bootstrap, 1);
		return;
	}
	bootstrap->uim = QMI_CLIENT_UIM(client);
	qmi_client_uim_get_card_status(bootstrap->uim, NULL, 10,
				       bootstrap->cancellable,
				       (GAsyncReadyCallback)card_status_ready,
				       bootstrap);
}

static void device_open_ready(QmiDevice *device, GAsyncResult *res,
			      struct bootstrap *bootstrap)
{
	GError *error = NULL;

	if (!qmi_device_open_finish(device, res, &error)) {
		g_printerr("QMI device open failed: %s\n", error->message);
		g_clear_error(&error);
		finish(bootstrap, 1);
		return;
	}
	qmi_device_allocate_client(device, QMI_SERVICE_UIM, QMI_CID_NONE, 10,
				   bootstrap->cancellable,
				   (GAsyncReadyCallback)client_ready, bootstrap);
}

static void device_ready(GObject *source, GAsyncResult *res,
			 struct bootstrap *bootstrap)
{
	GError *error = NULL;

	(void)source;
	bootstrap->device = qmi_device_new_finish(res, &error);
	if (!bootstrap->device) {
		g_printerr("QMI device creation failed: %s\n", error->message);
		g_clear_error(&error);
		finish(bootstrap, 1);
		return;
	}
	qmi_device_open(bootstrap->device, QMI_DEVICE_OPEN_FLAGS_EXPECT_INDICATIONS,
			10, bootstrap->cancellable,
			(GAsyncReadyCallback)device_open_ready, bootstrap);
}

static void bus_ready(GObject *source, GAsyncResult *res,
		      struct bootstrap *bootstrap)
{
	QrtrNode *node;
	GError *error = NULL;

	(void)source;
	bootstrap->bus = qrtr_bus_new_finish(res, &error);
	if (!bootstrap->bus) {
		g_printerr("QRTR bus discovery failed: %s\n", error->message);
		g_clear_error(&error);
		finish(bootstrap, 1);
		return;
	}
	node = qrtr_bus_peek_node(bootstrap->bus, bootstrap->node);
	if (!node) {
		g_printerr("QRTR node %u is unavailable\n", bootstrap->node);
		finish(bootstrap, 1);
		return;
	}
	qmi_device_new_from_node(node, bootstrap->cancellable,
				 (GAsyncReadyCallback)device_ready, bootstrap);
}

int main(int argc, char **argv)
{
	struct bootstrap bootstrap = { .node = 0 };
	GOptionContext *options;
	GError *error = NULL;
	GOptionEntry entries[] = {
		{ "node", 'n', 0, G_OPTION_ARG_INT, &bootstrap.node, "QRTR node", "ID" },
		{ NULL }
	};

	options = g_option_context_new("- bootstrap the Hotdog modem UIM state");
	g_option_context_add_main_entries(options, entries, NULL);
	if (!g_option_context_parse(options, &argc, &argv, &error)) {
		g_printerr("option parsing failed: %s\n", error->message);
		g_clear_error(&error);
		g_option_context_free(options);
		return 2;
	}
	g_option_context_free(options);
	bootstrap.loop = g_main_loop_new(NULL, FALSE);
	bootstrap.cancellable = g_cancellable_new();
	qrtr_bus_new(1000, bootstrap.cancellable,
		     (GAsyncReadyCallback)bus_ready, &bootstrap);
	g_main_loop_run(bootstrap.loop);
	g_clear_object(&bootstrap.uim);
	g_clear_object(&bootstrap.device);
	g_clear_object(&bootstrap.bus);
	g_clear_object(&bootstrap.cancellable);
	g_main_loop_unref(bootstrap.loop);
	return bootstrap.result;
}
