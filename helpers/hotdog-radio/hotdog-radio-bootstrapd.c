/* SPDX-License-Identifier: GPL-2.0-only */
#include "hotdog-qmi-uim.h"
#include "hotdog-qmi-dms.h"
#ifdef HOTDOG_QMI_PDC_SUBSCRIPTIONS
#include "hotdog-mcfg.h"
#include "hotdog-qmi-pdc.h"
#include "hotdog-qmi-pdc-list.h"
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
	QmiClientDms *dms;
	struct hotdog_uim_inventory inventory;
#ifdef HOTDOG_QMI_PDC_SUBSCRIPTIONS
	QmiClientPdc *pdc;
	struct hotdog_pdc_catalog *catalog;
	struct hotdog_pdc_loaded_catalog loaded_catalog;
	struct hotdog_pdc_subscription pdc_subscriptions[HOTDOG_PDC_MAX_SUBSCRIPTIONS];
	uint32_t pdc_token;
	uint32_t pdc_expected_token;
	size_t pdc_query_index;
	size_t pdc_query_count;
	gulong pdc_indication_id;
	gulong pdc_list_indication_id;
	guint pdc_timeout_id;
	guint pdc_list_timeout_id;
	uint32_t pdc_list_token;
#endif
	unsigned int node;
	int pdc_probe_subscription;
	char *mcfg_root;
	gboolean plan_pdc;
	gboolean probe_dms;
	gboolean probe_pdc_catalog;
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

static void start_dms_probe(struct bootstrap *bootstrap);

static void dms_mode_ready(QmiClientDms *client, GAsyncResult *res,
			   struct bootstrap *bootstrap)
{
	QmiMessageDmsGetOperatingModeOutput *output;
	QmiDmsOperatingMode mode;
	GError *error = NULL;
	int result;

	output = qmi_client_dms_get_operating_mode_finish(client, res, &error);
	if (!output) {
		g_printerr("DMS operating mode request failed: %s\n", error->message);
		g_clear_error(&error);
		finish(bootstrap, 1);
		return;
	}
	result = hotdog_qmi_dms_decode_operating_mode(output, &mode);
	qmi_message_dms_get_operating_mode_output_unref(output);
	if (result) {
		g_printerr("DMS operating mode rejected: %d\n", result);
		finish(bootstrap, 1);
		return;
	}
	printf("dms-operating-mode=%s\n", hotdog_qmi_dms_mode_name(mode));
	finish(bootstrap, 0);
}

static void dms_client_ready(QmiDevice *device, GAsyncResult *res,
			     struct bootstrap *bootstrap)
{
	QmiClient *client;
	GError *error = NULL;

	client = qmi_device_allocate_client_finish(device, res, &error);
	if (!client) {
		g_printerr("DMS client allocation failed: %s\n", error->message);
		g_clear_error(&error);
		finish(bootstrap, 1);
		return;
	}
	bootstrap->dms = QMI_CLIENT_DMS(client);
	qmi_client_dms_get_operating_mode(bootstrap->dms, NULL, 10,
					  bootstrap->cancellable,
					  (GAsyncReadyCallback)dms_mode_ready,
					  bootstrap);
}

static void start_dms_probe(struct bootstrap *bootstrap)
{
	qmi_device_allocate_client(bootstrap->device, QMI_SERVICE_DMS, QMI_CID_NONE, 10,
				   bootstrap->cancellable,
				   (GAsyncReadyCallback)dms_client_ready, bootstrap);
}

#ifdef HOTDOG_QMI_PDC_SUBSCRIPTIONS
static void pdc_query_next(struct bootstrap *bootstrap);
static void pdc_selected_indication(QmiClientPdc *client,
				    QmiIndicationPdcGetSelectedConfigOutput *output,
				    struct bootstrap *bootstrap);

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
	struct hotdog_pdc_plan cleanup, activation;
	size_t index, unmatched = 0;
	int result;

	bootstrap->catalog = g_new0(struct hotdog_pdc_catalog, 1);
	result = hotdog_mcfg_catalog_load(bootstrap->mcfg_root, bootstrap->catalog, &report);
	if (result) {
		g_printerr("MCFG catalog rejected: %d\n", result);
		return result;
	}
	result = hotdog_pdc_plan_cleanup(
		bootstrap->catalog, bootstrap->loaded_catalog.ids,
		bootstrap->loaded_catalog.count, bootstrap->pdc_subscriptions,
		HOTDOG_PDC_MAX_SUBSCRIPTIONS, &cleanup, &unmatched);
	if (result)
		return result;
	result = hotdog_pdc_plan_activation(bootstrap->catalog,
		bootstrap->pdc_subscriptions, HOTDOG_PDC_MAX_SUBSCRIPTIONS, &activation);
	printf("pdc-plan=result:%d catalog:%zu listed:%zu listed-missing:%zu operations:%zu\n",
	       result, bootstrap->catalog->count, report.listed, report.listed_missing,
	       result ? 0 : activation.count);
	if (result)
		return result;
	for (index = 0; index < activation.count; index++) {
		const struct hotdog_pdc_operation *operation = &activation.operations[index];
		const struct hotdog_pdc_config *config = find_config(bootstrap->catalog,
								    &operation->id);

		printf("pdc-plan%zu=%s sub:%u expected:%u id:", index,
		       hotdog_pdc_operation_name(operation->type), operation->subscription,
		       operation->expected_indications);
		print_pdc_id(&operation->id);
		printf(" path:%s carrier:%s\n", config ? config->path : "-",
		       config ? config->metadata.carrier : "-");
	}
	printf("pdc-deferred-cleanup-plan=result:0 resident:%zu unmatched:%zu operations:%zu\n",
	       bootstrap->loaded_catalog.count, unmatched, cleanup.count);
	for (index = 0; index < cleanup.count; index++) {
		printf("pdc-deferred-cleanup%zu=%s id:", index,
		       hotdog_pdc_operation_name(cleanup.operations[index].type));
		print_pdc_id(&cleanup.operations[index].id);
		printf("\n");
	}
	return 0;
}

static gboolean pdc_query_timeout(gpointer user_data)
{
	struct bootstrap *bootstrap = user_data;
	unsigned int subscription = bootstrap->plan_pdc ?
		(unsigned int)bootstrap->pdc_query_index :
		bootstrap->inventory.gw_sessions[bootstrap->pdc_query_index].subscription;

	bootstrap->pdc_timeout_id = 0;
	g_printerr("PDC selected-config indication timed out for subscription %u\n",
		   subscription);
	finish(bootstrap, 1);
	return G_SOURCE_REMOVE;
}

static gboolean pdc_list_timeout(gpointer user_data)
{
	struct bootstrap *bootstrap = user_data;

	bootstrap->pdc_list_timeout_id = 0;
	printf("pdc-loaded-count=0 result=timeout-empty\n");
	if (bootstrap->plan_pdc) {
		bootstrap->pdc_query_index = 0;
		bootstrap->pdc_query_count = HOTDOG_PDC_MAX_SUBSCRIPTIONS;
		bootstrap->pdc_indication_id = g_signal_connect(
			bootstrap->pdc, "get-selected-config",
			G_CALLBACK(pdc_selected_indication), bootstrap);
		pdc_query_next(bootstrap);
	} else {
		finish(bootstrap, 0);
	}
	return G_SOURCE_REMOVE;
}

static void pdc_list_indication(QmiClientPdc *client,
				QmiIndicationPdcListConfigsOutput *output,
				struct bootstrap *bootstrap)
{
	uint16_t remote_result = 0;
	size_t index;
	int result;

	(void)client;
	result = hotdog_qmi_pdc_decode_list(output, bootstrap->pdc_list_token,
					    &bootstrap->loaded_catalog, &remote_result);
	if (result == -ESTALE)
		return;
	if (bootstrap->pdc_list_timeout_id) {
		g_source_remove(bootstrap->pdc_list_timeout_id);
		bootstrap->pdc_list_timeout_id = 0;
	}
	if (result) {
		g_printerr("PDC list indication rejected: %d remote=%u\n",
			   result, remote_result);
		finish(bootstrap, 1);
		return;
	}
	printf("pdc-loaded-count=%zu\n", bootstrap->loaded_catalog.count);
	for (index = 0; index < bootstrap->loaded_catalog.count; index++) {
		printf("pdc-loaded%zu=", index);
		print_pdc_id(&bootstrap->loaded_catalog.ids[index]);
		printf("\n");
	}
	if (bootstrap->plan_pdc) {
		bootstrap->pdc_query_index = 0;
		bootstrap->pdc_query_count = HOTDOG_PDC_MAX_SUBSCRIPTIONS;
		bootstrap->pdc_indication_id = g_signal_connect(
			bootstrap->pdc, "get-selected-config",
			G_CALLBACK(pdc_selected_indication), bootstrap);
		pdc_query_next(bootstrap);
	} else {
		finish(bootstrap, 0);
	}
}

static void pdc_list_ready(QmiClientPdc *client, GAsyncResult *res,
			   struct bootstrap *bootstrap)
{
	QmiMessagePdcListConfigsOutput *output;
	GError *error = NULL;

	output = qmi_client_pdc_list_configs_finish(client, res, &error);
	if (!output) {
		g_printerr("PDC list request failed: %s\n", error->message);
		g_clear_error(&error);
		finish(bootstrap, 1);
		return;
	}
	if (!qmi_message_pdc_list_configs_output_get_result(output, &error)) {
		g_printerr("PDC list response failed: %s\n", error->message);
		g_clear_error(&error);
		qmi_message_pdc_list_configs_output_unref(output);
		finish(bootstrap, 1);
		return;
	}
	qmi_message_pdc_list_configs_output_unref(output);
}

static void pdc_list_start(struct bootstrap *bootstrap)
{
	QmiMessagePdcListConfigsInput *input = NULL;
	int result;

	bootstrap->pdc_list_token = ++bootstrap->pdc_token;
	result = hotdog_qmi_pdc_list_input(bootstrap->pdc_list_token, &input);
	if (result) {
		g_printerr("PDC list input rejected: %d\n", result);
		finish(bootstrap, 1);
		return;
	}
	bootstrap->pdc_list_indication_id = g_signal_connect(
		bootstrap->pdc, "list-configs", G_CALLBACK(pdc_list_indication), bootstrap);
	bootstrap->pdc_list_timeout_id = g_timeout_add_seconds(6, pdc_list_timeout, bootstrap);
	qmi_client_pdc_list_configs(bootstrap->pdc, input, 10, bootstrap->cancellable,
				    (GAsyncReadyCallback)pdc_list_ready, bootstrap);
	qmi_message_pdc_list_configs_input_unref(input);
}

static void pdc_selected_indication(QmiClientPdc *client,
				    QmiIndicationPdcGetSelectedConfigOutput *output,
				    struct bootstrap *bootstrap)
{
	struct hotdog_pdc_id active, pending;
	unsigned int subscription;
	const struct hotdog_uim_session *session = NULL;
	size_t identity_index;
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
	subscription = bootstrap->plan_pdc ? (unsigned int)bootstrap->pdc_query_index :
		bootstrap->inventory.gw_sessions[bootstrap->pdc_query_index].subscription;
	bootstrap->pdc_subscriptions[subscription].active = active;
	bootstrap->pdc_subscriptions[subscription].pending = pending;
	for (identity_index = 0; identity_index < bootstrap->inventory.gw_count;
	     identity_index++)
		if (bootstrap->inventory.gw_sessions[identity_index].subscription == subscription) {
			session = &bootstrap->inventory.gw_sessions[identity_index];
			break;
		}
	if (session && session->physical_slot &&
	    session->physical_slot <= bootstrap->inventory.slot_count) {
		const struct hotdog_uim_slot *slot =
			&bootstrap->inventory.slots[session->physical_slot - 1];

		if (slot->iccid_length) {
			bootstrap->pdc_subscriptions[subscription].populated = true;
			g_strlcpy(bootstrap->pdc_subscriptions[subscription].iccid,
				  slot->iccid,
				  sizeof(bootstrap->pdc_subscriptions[subscription].iccid));
		}
	}
	printf("pdc-sub%u=active:", subscription);
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
	unsigned int subscription;
	int result;

	if (bootstrap->pdc_query_index >= bootstrap->pdc_query_count) {
		result = bootstrap->plan_pdc ? pdc_plan_dry_run(bootstrap) : 0;
		if (result) {
			finish(bootstrap, 1);
			return;
		}
		if (bootstrap->probe_dms)
			start_dms_probe(bootstrap);
		else
			finish(bootstrap, 0);
		return;
	}
	subscription = bootstrap->plan_pdc ? (unsigned int)bootstrap->pdc_query_index :
		bootstrap->inventory.gw_sessions[bootstrap->pdc_query_index].subscription;
	bootstrap->pdc_expected_token = ++bootstrap->pdc_token;
	result = hotdog_qmi_pdc_get_selected_input(subscription,
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
	if (bootstrap->probe_pdc_catalog || bootstrap->plan_pdc) {
		pdc_list_start(bootstrap);
		return;
	}
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
	bootstrap->pdc_query_count = bootstrap->inventory.gw_count;
	if (!bootstrap->inventory.gw_count) {
		if (bootstrap->probe_pdc_catalog)
			qmi_device_allocate_client(bootstrap->device, QMI_SERVICE_PDC,
						   QMI_CID_NONE, 10,
						   bootstrap->cancellable,
						   (GAsyncReadyCallback)pdc_client_ready,
						   bootstrap);
		else if (bootstrap->probe_dms)
			start_dms_probe(bootstrap);
		else
			finish(bootstrap, 0);
		return;
	}
	qmi_device_allocate_client(bootstrap->device, QMI_SERVICE_PDC, QMI_CID_NONE, 10,
				   bootstrap->cancellable,
				   (GAsyncReadyCallback)pdc_client_ready, bootstrap);
#else
	if (bootstrap->probe_dms)
		start_dms_probe(bootstrap);
	else
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
	if (result && !((bootstrap->pdc_probe_subscription >= 0 || bootstrap->plan_pdc ||
			bootstrap->probe_dms || bootstrap->probe_pdc_catalog) &&
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
		{ "probe-dms", 0, 0, G_OPTION_ARG_NONE, &bootstrap.probe_dms,
		  "Read and print the DMS operating mode", NULL },
		{ "probe-pdc-catalog", 0, 0, G_OPTION_ARG_NONE,
		  &bootstrap.probe_pdc_catalog,
		  "Read and print resident software PDC config IDs", NULL },
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
	if (bootstrap.plan_pdc && bootstrap.probe_dms) {
		g_printerr("Combine DMS probing with a later verified PDC plan, not this dry-run\n");
		g_free(bootstrap.mcfg_root);
		return 2;
	}
	if (bootstrap.probe_pdc_catalog &&
	    (bootstrap.plan_pdc || bootstrap.probe_dms ||
	     bootstrap.pdc_probe_subscription >= 0)) {
		g_printerr("PDC catalog probing must run as a separate read-only operation\n");
		g_free(bootstrap.mcfg_root);
		return 2;
	}
#ifndef HOTDOG_QMI_PDC_SUBSCRIPTIONS
	if (bootstrap.pdc_probe_subscription >= 0 || bootstrap.plan_pdc ||
	    bootstrap.probe_pdc_catalog) {
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
	if (bootstrap.pdc_list_timeout_id)
		g_source_remove(bootstrap.pdc_list_timeout_id);
	if (bootstrap.pdc && bootstrap.pdc_indication_id)
		g_signal_handler_disconnect(bootstrap.pdc, bootstrap.pdc_indication_id);
	if (bootstrap.pdc && bootstrap.pdc_list_indication_id)
		g_signal_handler_disconnect(bootstrap.pdc, bootstrap.pdc_list_indication_id);
	release_client(&bootstrap, QMI_CLIENT(bootstrap.pdc));
	g_clear_object(&bootstrap.pdc);
#endif
	release_client(&bootstrap, QMI_CLIENT(bootstrap.uim));
	g_clear_object(&bootstrap.uim);
	release_client(&bootstrap, QMI_CLIENT(bootstrap.dms));
	g_clear_object(&bootstrap.dms);
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
