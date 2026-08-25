/* SPDX-License-Identifier: GPL-2.0-only */
#include "hotdog-qmi-uim.h"
#ifdef HOTDOG_QMI_PDC_SUBSCRIPTIONS
#include "hotdog-mcfg.h"
#include "hotdog-qmi-pdc.h"
#endif

#include <gio/gio.h>
#include <libqmi-glib.h>
#include <libqrtr-glib.h>
#include <errno.h>
#include <stdio.h>

struct bootstrap {
	GMainLoop *loop;
	GCancellable *cancellable;
	QrtrBus *bus;
	QmiDevice *device;
	QmiClientUim *uim;
	struct hotdog_uim_inventory inventory;
#ifdef HOTDOG_QMI_PDC_SUBSCRIPTIONS
	QmiClientPdc *pdc;
	struct hotdog_pdc_catalog *catalog;
	struct hotdog_pdc_subscription pdc_subscriptions[HOTDOG_PDC_MAX_SUBSCRIPTIONS];
	uint32_t pdc_token;
	uint32_t pdc_expected_token;
	size_t pdc_query_index;
	gulong pdc_indication_id;
	guint pdc_timeout_id;
#endif
	unsigned int node;
	int pdc_probe_subscription;
	char *mcfg_root;
	gboolean plan_pdc;
	int result;
	bool finished;
};

struct release_wait {
	bool done;
};

static void client_release_ready(QmiDevice *device, GAsyncResult *res,
				 struct release_wait *wait)
{
	GError *error = NULL;

	if (!qmi_device_release_client_finish(device, res, &error)) {
		g_printerr("QMI client release failed: %s\n", error->message);
		g_clear_error(&error);
	}
	wait->done = true;
}

static void release_client(struct bootstrap *bootstrap, QmiClient *client)
{
	struct release_wait wait = { 0 };

	if (!bootstrap->device || !client)
		return;
	qmi_device_release_client(bootstrap->device, client,
				  QMI_DEVICE_RELEASE_CLIENT_FLAGS_RELEASE_CID,
				  10, NULL, (GAsyncReadyCallback)client_release_ready, &wait);
	while (!wait.done)
		g_main_context_iteration(NULL, TRUE);
}

static void finish(struct bootstrap *bootstrap, int result)
{
	if (bootstrap->finished)
		return;
	bootstrap->finished = true;
	bootstrap->result = result;
	g_main_loop_quit(bootstrap->loop);
}

#ifdef HOTDOG_QMI_PDC_SUBSCRIPTIONS
static void pdc_query_next(struct bootstrap *bootstrap);

static void print_pdc_id(const struct hotdog_pdc_id *id)
{
	size_t index;

	if (!id->length) {
		printf("-");
		return;
	}
	for (index = 0; index < id->length; index++)
		printf("%02x", id->value[index]);
}

static const struct hotdog_pdc_config *find_config(
	const struct hotdog_pdc_catalog *catalog, const struct hotdog_pdc_id *id)
{
	size_t index;

	if (!id->length)
		return NULL;
	for (index = 0; index < catalog->count; index++)
		if (hotdog_pdc_id_equal(&catalog->configs[index].id, id))
			return &catalog->configs[index];
	return NULL;
}

static int pdc_plan_dry_run(struct bootstrap *bootstrap)
{
	struct hotdog_mcfg_report report;
	struct hotdog_pdc_plan plan;
	size_t index, subscription;
	int result;

	bootstrap->catalog = g_new0(struct hotdog_pdc_catalog, 1);
	result = hotdog_mcfg_catalog_load(bootstrap->mcfg_root, bootstrap->catalog, &report);
	if (result) {
		g_printerr("MCFG catalog rejected: %d\n", result);
		return result;
	}
	for (index = 0; index < bootstrap->catalog->count; index++) {
		for (subscription = 0; subscription < bootstrap->inventory.gw_count;
		     subscription++) {
			const struct hotdog_pdc_subscription *state =
				&bootstrap->pdc_subscriptions[subscription];

			if (hotdog_pdc_id_equal(&bootstrap->catalog->configs[index].id,
						&state->active) ||
			    hotdog_pdc_id_equal(&bootstrap->catalog->configs[index].id,
						&state->pending))
				bootstrap->catalog->configs[index].loaded = true;
		}
	}
	result = hotdog_pdc_plan_activation(bootstrap->catalog,
		bootstrap->pdc_subscriptions, bootstrap->inventory.gw_count, &plan);
	printf("pdc-plan=result:%d catalog:%zu listed:%zu listed-missing:%zu operations:%zu\n",
	       result, bootstrap->catalog->count, report.listed, report.listed_missing,
	       result ? 0 : plan.count);
	if (result)
		return result;
	for (index = 0; index < plan.count; index++) {
		const struct hotdog_pdc_operation *operation = &plan.operations[index];
		const struct hotdog_pdc_config *config = find_config(bootstrap->catalog,
								    &operation->id);

		printf("pdc-plan%zu=%s sub:%u expected:%u id:", index,
		       hotdog_pdc_operation_name(operation->type), operation->subscription,
		       operation->expected_indications);
		print_pdc_id(&operation->id);
		printf(" path:%s carrier:%s\n", config ? config->path : "-",
		       config ? config->metadata.carrier : "-");
	}
	return 0;
}

static gboolean pdc_query_timeout(gpointer user_data)
{
	struct bootstrap *bootstrap = user_data;

	bootstrap->pdc_timeout_id = 0;
	g_printerr("PDC selected-config indication timed out for subscription %u\n",
		   bootstrap->inventory.gw_sessions[bootstrap->pdc_query_index].subscription);
	finish(bootstrap, 1);
	return G_SOURCE_REMOVE;
}

static void pdc_selected_indication(QmiClientPdc *client,
				    QmiIndicationPdcGetSelectedConfigOutput *output,
				    struct bootstrap *bootstrap)
{
	struct hotdog_pdc_id active, pending;
	const struct hotdog_uim_session *session;
	uint16_t remote_result = 0;
	int result;

	(void)client;
	result = hotdog_qmi_pdc_decode_selected(output, bootstrap->pdc_expected_token,
						 &active, &pending, &remote_result);
	if (result == -ESTALE)
		return;
	if (result) {
		g_printerr("PDC selected-config indication rejected: %d remote=%u (%s)\n",
			   result, remote_result,
			   remote_result ? qmi_protocol_error_get_string(
				   (QmiProtocolError)remote_result) : "none");
		finish(bootstrap, 1);
		return;
	}
	if (bootstrap->pdc_timeout_id) {
		g_source_remove(bootstrap->pdc_timeout_id);
		bootstrap->pdc_timeout_id = 0;
	}
	session = &bootstrap->inventory.gw_sessions[bootstrap->pdc_query_index];
	bootstrap->pdc_subscriptions[bootstrap->pdc_query_index].active = active;
	bootstrap->pdc_subscriptions[bootstrap->pdc_query_index].pending = pending;
	if (session->physical_slot &&
	    session->physical_slot <= bootstrap->inventory.slot_count) {
		const struct hotdog_uim_slot *slot =
			&bootstrap->inventory.slots[session->physical_slot - 1];

		if (slot->iccid_length) {
			bootstrap->pdc_subscriptions[bootstrap->pdc_query_index].populated = true;
			g_strlcpy(bootstrap->pdc_subscriptions[bootstrap->pdc_query_index].iccid,
				  slot->iccid,
				  sizeof(bootstrap->pdc_subscriptions[bootstrap->pdc_query_index].iccid));
		}
	}
	printf("pdc-sub%u=active:", session->subscription);
	print_pdc_id(&active);
	printf(" pending:");
	print_pdc_id(&pending);
	if (remote_result)
		printf(" result:%s", qmi_protocol_error_get_string(
			       (QmiProtocolError)remote_result));
	printf("\n");
	bootstrap->pdc_query_index++;
	pdc_query_next(bootstrap);
}

static void pdc_get_selected_ready(QmiClientPdc *client, GAsyncResult *res,
				   struct bootstrap *bootstrap)
{
	QmiMessagePdcGetSelectedConfigOutput *output;
	GError *error = NULL;

	output = qmi_client_pdc_get_selected_config_finish(client, res, &error);
	if (!output) {
		g_printerr("PDC selected-config request failed: %s\n", error->message);
		g_clear_error(&error);
		finish(bootstrap, 1);
		return;
	}
	if (!qmi_message_pdc_get_selected_config_output_get_result(output, &error)) {
		g_printerr("PDC selected-config response failed: %s\n", error->message);
		g_clear_error(&error);
		qmi_message_pdc_get_selected_config_output_unref(output);
		finish(bootstrap, 1);
		return;
	}
	qmi_message_pdc_get_selected_config_output_unref(output);
}

static void pdc_query_next(struct bootstrap *bootstrap)
{
	QmiMessagePdcGetSelectedConfigInput *input = NULL;
	const struct hotdog_uim_session *session;
	int result;

	if (bootstrap->pdc_query_index >= bootstrap->inventory.gw_count) {
		result = bootstrap->plan_pdc ? pdc_plan_dry_run(bootstrap) : 0;
		finish(bootstrap, result ? 1 : 0);
		return;
	}
	session = &bootstrap->inventory.gw_sessions[bootstrap->pdc_query_index];
	bootstrap->pdc_expected_token = ++bootstrap->pdc_token;
	result = hotdog_qmi_pdc_get_selected_input(session->subscription,
						   bootstrap->pdc_expected_token, &input);
	if (result) {
		g_printerr("PDC selected-config input rejected: %d\n", result);
		finish(bootstrap, 1);
		return;
	}
	bootstrap->pdc_timeout_id = g_timeout_add_seconds(12, pdc_query_timeout, bootstrap);
	qmi_client_pdc_get_selected_config(bootstrap->pdc, input, 10,
					   bootstrap->cancellable,
					   (GAsyncReadyCallback)pdc_get_selected_ready,
					   bootstrap);
	qmi_message_pdc_get_selected_config_input_unref(input);
}

static void pdc_client_ready(QmiDevice *device, GAsyncResult *res,
			     struct bootstrap *bootstrap)
{
	QmiClient *client;
	GError *error = NULL;

	client = qmi_device_allocate_client_finish(device, res, &error);
	if (!client) {
		g_printerr("PDC client allocation failed: %s\n", error->message);
		g_clear_error(&error);
		finish(bootstrap, 1);
		return;
	}
	bootstrap->pdc = QMI_CLIENT_PDC(client);
	bootstrap->pdc_indication_id = g_signal_connect(
		bootstrap->pdc, "get-selected-config",
		G_CALLBACK(pdc_selected_indication), bootstrap);
	pdc_query_next(bootstrap);
}
#endif

static void print_inventory(const struct hotdog_uim_inventory *inventory)
{
	size_t i;

	printf("slots=%zu gw_sessions=%zu onex_sessions=%zu isim_sessions=%zu\n",
	       inventory->slot_count, inventory->gw_count,
	       inventory->onex_count, inventory->isim_count);
	for (i = 0; i < inventory->slot_count; i++) {
		printf("slot%zu=%s apps=%zu error=%d physical=%u active=%u logical=%u iccid=%s length=%zu\n",
		       i + 1,
		       hotdog_uim_card_state_name(inventory->slots[i].state),
		       inventory->slots[i].app_count, inventory->slots[i].card_error,
		       inventory->slots[i].physical_present,
		       inventory->slots[i].logical_active,
		       inventory->slots[i].logical_slot,
		       inventory->slots[i].iccid_length ? "present" : "absent",
		       inventory->slots[i].iccid_length);
	}
	for (i = 0; i < inventory->gw_count; i++) {
		const struct hotdog_uim_session *session = &inventory->gw_sessions[i];
		printf("sub%u=slot%u app%u %s %s\n", session->subscription,
		       session->physical_slot, session->app_index,
		       hotdog_uim_app_type_name(session->app_type),
		       hotdog_uim_app_state_name(session->app_state));
	}
}

static void slot_status_ready(QmiClientUim *client, GAsyncResult *res,
			      struct bootstrap *bootstrap)
{
	QmiMessageUimGetSlotStatusOutput *output;
	GError *error = NULL;
	int result;

	output = qmi_client_uim_get_slot_status_finish(client, res, &error);
	if (!output) {
		g_printerr("UIM slot status failed: %s\n", error->message);
		g_clear_error(&error);
		finish(bootstrap, 1);
		return;
	}
	result = hotdog_qmi_uim_decode_slot_status(output, &bootstrap->inventory);
	qmi_message_uim_get_slot_status_output_unref(output);
	if (result) {
		g_printerr("UIM slot identity rejected: %d\n", result);
		finish(bootstrap, 1);
		return;
	}
	print_inventory(&bootstrap->inventory);
#ifdef HOTDOG_QMI_PDC_SUBSCRIPTIONS
	if (bootstrap->plan_pdc) {
		size_t index;

		if (!bootstrap->inventory.gw_count) {
			g_printerr("PDC planning requires a populated GW application\n");
			finish(bootstrap, 1);
			return;
		}
		for (index = 0; index < bootstrap->inventory.gw_count; index++) {
			const struct hotdog_uim_session *session =
				&bootstrap->inventory.gw_sessions[index];
			const struct hotdog_uim_slot *slot =
				&bootstrap->inventory.slots[session->physical_slot - 1];

			if (!slot->physical_present || !slot->iccid_length) {
				g_printerr("PDC planning lacks card identity for subscription %u\n",
					   session->subscription);
				finish(bootstrap, 1);
				return;
			}
		}
	}
	if (!bootstrap->inventory.gw_count && bootstrap->pdc_probe_subscription >= 0) {
		bootstrap->inventory.gw_count = 1;
		bootstrap->inventory.gw_sessions[0].subscription =
			(unsigned int)bootstrap->pdc_probe_subscription;
	}
	if (!bootstrap->inventory.gw_count) {
		finish(bootstrap, 0);
		return;
	}
	qmi_device_allocate_client(bootstrap->device, QMI_SERVICE_PDC, QMI_CID_NONE, 10,
				   bootstrap->cancellable,
				   (GAsyncReadyCallback)pdc_client_ready, bootstrap);
#else
	finish(bootstrap, 0);
#endif
}

static void card_status_ready(QmiClientUim *client, GAsyncResult *res,
			      struct bootstrap *bootstrap)
{
	QmiMessageUimGetCardStatusOutput *output;
	GError *error = NULL;
	int result;

	output = qmi_client_uim_get_card_status_finish(client, res, &error);
	if (!output) {
		g_printerr("UIM card status failed: %s\n", error->message);
		g_clear_error(&error);
		finish(bootstrap, 1);
		return;
	}
	result = hotdog_qmi_uim_decode(output, &bootstrap->inventory);
	qmi_message_uim_get_card_status_output_unref(output);
	if (result && !((bootstrap->pdc_probe_subscription >= 0 || bootstrap->plan_pdc) &&
			(result == -EIO || result == -ENODEV))) {
		g_printerr("UIM inventory rejected: %d\n", result);
		finish(bootstrap, 1);
		return;
	}
	qmi_client_uim_get_slot_status(bootstrap->uim, NULL, 10,
				       bootstrap->cancellable,
				       (GAsyncReadyCallback)slot_status_ready,
				       bootstrap);
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
	struct bootstrap bootstrap = { .node = 0, .pdc_probe_subscription = -1 };
	GOptionContext *options;
	GError *error = NULL;
	GOptionEntry entries[] = {
		{ "node", 'n', 0, G_OPTION_ARG_INT, &bootstrap.node, "QRTR node", "ID" },
		{ "pdc-subscription", 0, 0, G_OPTION_ARG_INT,
		  &bootstrap.pdc_probe_subscription,
		  "Read one PDC subscription even without a card", "0-2" },
		{ "mcfg-root", 0, 0, G_OPTION_ARG_STRING, &bootstrap.mcfg_root,
		  "MCFG software profile root for dry-run planning", "DIR" },
		{ "plan-pdc", 0, 0, G_OPTION_ARG_NONE, &bootstrap.plan_pdc,
		  "Build and print a PDC transaction without executing it", NULL },
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
	if (bootstrap.pdc_probe_subscription < -1 ||
	    bootstrap.pdc_probe_subscription >= HOTDOG_UIM_MAX_SLOTS) {
		g_printerr("PDC subscription must be between 0 and 2\n");
		return 2;
	}
	if (bootstrap.plan_pdc != (bootstrap.mcfg_root != NULL)) {
		g_printerr("PDC planning requires both --plan-pdc and --mcfg-root\n");
		g_free(bootstrap.mcfg_root);
		return 2;
	}
	if (bootstrap.plan_pdc && bootstrap.pdc_probe_subscription >= 0) {
		g_printerr("PDC planning requires a real populated UIM session\n");
		g_free(bootstrap.mcfg_root);
		return 2;
	}
#ifndef HOTDOG_QMI_PDC_SUBSCRIPTIONS
	if (bootstrap.pdc_probe_subscription >= 0 || bootstrap.plan_pdc) {
		g_printerr("PDC probing and planning require the patched libqmi build\n");
		g_free(bootstrap.mcfg_root);
		return 2;
	}
#endif
	bootstrap.loop = g_main_loop_new(NULL, FALSE);
	bootstrap.cancellable = g_cancellable_new();
	qrtr_bus_new(1000, bootstrap.cancellable,
		     (GAsyncReadyCallback)bus_ready, &bootstrap);
	g_main_loop_run(bootstrap.loop);
#ifdef HOTDOG_QMI_PDC_SUBSCRIPTIONS
	if (bootstrap.pdc_timeout_id)
		g_source_remove(bootstrap.pdc_timeout_id);
	if (bootstrap.pdc && bootstrap.pdc_indication_id)
		g_signal_handler_disconnect(bootstrap.pdc, bootstrap.pdc_indication_id);
	release_client(&bootstrap, QMI_CLIENT(bootstrap.pdc));
	g_clear_object(&bootstrap.pdc);
#endif
	release_client(&bootstrap, QMI_CLIENT(bootstrap.uim));
	g_clear_object(&bootstrap.uim);
	g_clear_object(&bootstrap.device);
	g_clear_object(&bootstrap.bus);
	g_clear_object(&bootstrap.cancellable);
	g_main_loop_unref(bootstrap.loop);
#ifdef HOTDOG_QMI_PDC_SUBSCRIPTIONS
	g_free(bootstrap.catalog);
#endif
	g_free(bootstrap.mcfg_root);
	return bootstrap.result;
}
