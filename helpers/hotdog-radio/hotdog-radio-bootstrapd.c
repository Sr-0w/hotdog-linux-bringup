/* SPDX-License-Identifier: GPL-2.0-only */
#include "hotdog-qmi-uim.h"
#include "hotdog-qmi-dms.h"
#include "hotdog-qmi-nas.h"
#ifdef HOTDOG_QMI_PDC_SUBSCRIPTIONS
#include "hotdog-mcfg.h"
#include "hotdog-pdc-controller.h"
#include "hotdog-qmi-pdc.h"
#include "hotdog-qmi-pdc-backend.h"
#include "hotdog-qmi-pdc-list.h"
#include "hotdog-radio-gate.h"
#include "hotdog-radio-readiness.h"
#endif

#include <gio/gio.h>
#include <libqmi-glib.h>
#include <libqrtr-glib.h>
#include <errno.h>
#include <stdio.h>

#define HOTDOG_MCFG_RUNTIME_MANIFEST "/usr/share/hotdog-radio/mcfg/MANIFEST"
#define HOTDOG_MCFG_CANONICAL_ROOT "/usr/share/hotdog-radio/mcfg/mcfg_sw"
#define HOTDOG_MODEM_CANONICAL_PATH "/usr/lib/firmware/qcom/sm8150/oneplus/hotdog/modem.mbn"
#define HOTDOG_BOOT_ID_PATH "/proc/sys/kernel/random/boot_id"
#define HOTDOG_READINESS_PATH "/run/hotdog-radio/readiness"

struct bootstrap {
	GMainLoop *loop;
	GCancellable *cancellable;
	QrtrBus *bus;
	QmiDevice *device;
	QmiClientUim *uim;
	QmiClientDms *dms;
	QmiClientNas *nas;
	struct hotdog_uim_inventory inventory;
#ifdef HOTDOG_QMI_PDC_SUBSCRIPTIONS
	QmiClientPdc *pdc;
	struct hotdog_pdc_catalog *catalog;
	struct hotdog_pdc_loaded_catalog loaded_catalog;
	struct hotdog_pdc_subscription pdc_subscriptions[HOTDOG_PDC_MAX_SUBSCRIPTIONS];
	struct hotdog_pdc_plan activation_plan;
	struct hotdog_pdc_plan cleanup_plan;
	struct hotdog_mcfg_report mcfg_report;
	struct hotdog_mcfg_runtime runtime;
	struct hotdog_qmi_pdc_backend pdc_backend;
	struct hotdog_pdc_controller pdc_controller;
	bool pdc_backend_initialized;
	bool pdc_controller_initialized;
	bool pdc_handoff;
	uint32_t pdc_token;
	uint32_t pdc_expected_token;
	size_t pdc_query_index;
	size_t pdc_query_count;
	gulong pdc_indication_id;
	gulong pdc_list_indication_id;
	guint pdc_timeout_id;
	guint pdc_list_timeout_id;
	uint32_t pdc_list_token;
	QmiDevice *switch_device;
	QrtrNode *switch_node;
	gulong switch_service_handler;
	guint switch_timeout_id;
	bool switch_reconnect_started;
#endif
	unsigned int node;
	int pdc_probe_subscription;
	char *mcfg_root;
	char *apply_pdc;
	gboolean plan_pdc;
	gboolean probe_dms;
	gboolean probe_pdc_catalog;
	gboolean probe_nas;
	int result;
	bool finished;
	gulong bus_node_added_handler;
	gulong bus_node_removed_handler;
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
			   struct bootstrap *bootstrap);

#ifdef HOTDOG_QMI_PDC_SUBSCRIPTIONS
static int publish_readiness(struct bootstrap *bootstrap)
{
	struct hotdog_radio_readiness readiness = { .dms_online = true };
	char line[64];
	FILE *stream;
	size_t index;
	bool locked = false;

	stream = fopen(HOTDOG_BOOT_ID_PATH, "r");
	if (!stream)
		return -errno;
	if (!fgets(line, sizeof(line), stream)) {
		fclose(stream);
		return -EIO;
	}
	fclose(stream);
	line[strcspn(line, "\r\n")] = '\0';
	if (strlen(line) >= sizeof(readiness.boot_id))
		return -EOVERFLOW;
	memcpy(readiness.boot_id, line, strlen(line) + 1);
	memcpy(readiness.modem_sha256, bootstrap->runtime.modem_sha256,
	       sizeof(readiness.modem_sha256));
	memcpy(readiness.mcfg_sha256, bootstrap->runtime.archive_sha256,
	       sizeof(readiness.mcfg_sha256));
	for (index = 0; index < HOTDOG_PDC_MAX_SUBSCRIPTIONS; index++) {
		const struct hotdog_pdc_subscription *pdc =
			&bootstrap->pdc_subscriptions[index];
		struct hotdog_readiness_subscription *target =
			&readiness.subscriptions[index];
		size_t session_index;

		if (!pdc->populated)
			continue;
		target->populated = true;
		target->selected = pdc->selected;
		target->active = pdc->active;
		target->pending = pdc->pending;
		for (session_index = 0; session_index < bootstrap->inventory.gw_count;
		     session_index++) {
			const struct hotdog_uim_session *session =
				&bootstrap->inventory.gw_sessions[session_index];
			const struct hotdog_uim_slot *slot;

			if (session->subscription != index)
				continue;
			slot = &bootstrap->inventory.slots[session->physical_slot - 1];
			if (session->app_index >= slot->app_count)
				return -EPROTO;
			target->physical_slot = session->physical_slot;
			target->app_state = slot->apps[session->app_index].state;
			target->retries = slot->apps[session->app_index].retries;
			break;
		}
		if (!target->physical_slot)
			return -ENODATA;
		if (target->app_state != HOTDOG_UIM_APP_READY)
			locked = true;
	}
	readiness.phase = locked ? HOTDOG_READINESS_LOCKED :
		HOTDOG_READINESS_REGISTERING;
	if (g_mkdir_with_parents("/run/hotdog-radio", 0755))
		return -errno;
	return hotdog_radio_readiness_write(HOTDOG_READINESS_PATH, &readiness);
}

static int start_modemmanager_handoff(void)
{
	char *arguments[] = { "/sbin/rc-service", "modemmanager", "start", NULL };
	GError *error = NULL;
	gint wait_status = 0;

	if (!g_spawn_sync(NULL, arguments, NULL, G_SPAWN_STDOUT_TO_DEV_NULL,
			  NULL, NULL, NULL, NULL, &wait_status, &error)) {
		g_printerr("ModemManager handoff spawn failed: %s\n", error->message);
		g_clear_error(&error);
		return -EIO;
	}
	if (!g_spawn_check_wait_status(wait_status, &error)) {
		g_printerr("ModemManager handoff failed: %s\n", error->message);
		g_clear_error(&error);
		return -EIO;
	}
	printf("modemmanager-handoff=started\n");
	return 0;
}

static void dms_set_online_ready(QmiClientDms *client, GAsyncResult *res,
				 struct bootstrap *bootstrap)
{
	QmiMessageDmsSetOperatingModeOutput *output;
	GError *error = NULL;
	uint16_t remote = 0;
	int result;

	output = qmi_client_dms_set_operating_mode_finish(client, res, &error);
	if (!output) {
		g_printerr("DMS Online request failed: %s\n", error->message);
		g_clear_error(&error);
		finish(bootstrap, 1);
		return;
	}
	result = hotdog_qmi_dms_decode_set_online(output, &remote);
	qmi_message_dms_set_operating_mode_output_unref(output);
	if (result) {
		g_printerr("DMS Online rejected: %d remote=%u\n", result, remote);
		finish(bootstrap, 1);
		return;
	}
	qmi_client_dms_get_operating_mode(bootstrap->dms, NULL, 10,
					  bootstrap->cancellable,
					  (GAsyncReadyCallback)dms_mode_ready,
					  bootstrap);
}
#endif

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
#ifdef HOTDOG_QMI_PDC_SUBSCRIPTIONS
	if (bootstrap->pdc_handoff) {
		if (mode == QMI_DMS_OPERATING_MODE_ONLINE) {
			result = publish_readiness(bootstrap);
			if (result)
				g_printerr("Radio readiness publication failed: %d\n", result);
			else {
				printf("radio-readiness=published phase-safe\n");
				result = start_modemmanager_handoff();
			}
			finish(bootstrap, result ? 1 : 0);
			return;
		}
		if (mode == QMI_DMS_OPERATING_MODE_SHUTTING_DOWN ||
		    mode == QMI_DMS_OPERATING_MODE_OFFLINE ||
		    mode == QMI_DMS_OPERATING_MODE_LOW_POWER) {
			QmiMessageDmsSetOperatingModeInput *input = NULL;

			result = hotdog_qmi_dms_set_online_input(&input);
			if (result) {
				finish(bootstrap, 1);
				return;
			}
			qmi_client_dms_set_operating_mode(
				bootstrap->dms, input, 15, bootstrap->cancellable,
				(GAsyncReadyCallback)dms_set_online_ready, bootstrap);
			qmi_message_dms_set_operating_mode_input_unref(input);
			return;
		}
		g_printerr("DMS mode is unsafe for Online transition: %s\n",
			   hotdog_qmi_dms_mode_name(mode));
		finish(bootstrap, 1);
		return;
	}
#endif
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

static void nas_serving_ready(QmiClientNas *client, GAsyncResult *res,
			      struct bootstrap *bootstrap)
{
	QmiMessageNasGetServingSystemOutput *output;
	struct hotdog_nas_snapshot snapshot;
	GError *error = NULL;
	size_t index;
	int result;

	output = qmi_client_nas_get_serving_system_finish(client, res, &error);
	if (!output) {
		g_printerr("NAS serving-system request failed: %s\n", error->message);
		g_clear_error(&error);
		finish(bootstrap, 1);
		return;
	}
	result = hotdog_qmi_nas_decode_serving_system(output, &snapshot);
	qmi_message_nas_get_serving_system_output_unref(output);
	if (result) {
		g_printerr("NAS serving-system rejected: %d\n", result);
		finish(bootstrap, 1);
		return;
	}
	printf("nas=registration:%s cs:%s ps:%s network:%s interfaces:%zu roaming:%s\n",
	       hotdog_qmi_nas_registration_name(snapshot.registration),
	       hotdog_qmi_nas_attach_name(snapshot.cs_attach),
	       hotdog_qmi_nas_attach_name(snapshot.ps_attach),
	       hotdog_qmi_nas_network_name(snapshot.network), snapshot.interface_count,
	       snapshot.roaming_valid ?
		qmi_nas_roaming_indicator_status_get_string(snapshot.roaming) : "unknown");
	for (index = 0; index < snapshot.interface_count; index++)
		printf("nas-interface%zu=%s\n", index,
		       qmi_nas_radio_interface_get_string(snapshot.interfaces[index]));
	finish(bootstrap, 0);
}

static void nas_client_ready(QmiDevice *device, GAsyncResult *res,
			     struct bootstrap *bootstrap)
{
	QmiClient *client;
	GError *error = NULL;

	client = qmi_device_allocate_client_finish(device, res, &error);
	if (!client) {
		g_printerr("NAS client allocation failed: %s\n", error->message);
		g_clear_error(&error);
		finish(bootstrap, 1);
		return;
	}
	bootstrap->nas = QMI_CLIENT_NAS(client);
	qmi_client_nas_get_serving_system(bootstrap->nas, NULL, 10,
					  bootstrap->cancellable,
					  (GAsyncReadyCallback)nas_serving_ready,
					  bootstrap);
}

static void start_nas_probe(struct bootstrap *bootstrap)
{
	qmi_device_allocate_client(bootstrap->device, QMI_SERVICE_NAS, QMI_CID_NONE, 10,
				   bootstrap->cancellable,
				   (GAsyncReadyCallback)nas_client_ready, bootstrap);
}

static bool pdc_planning(const struct bootstrap *bootstrap)
{
	return bootstrap->plan_pdc || bootstrap->apply_pdc != NULL;
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

static int pdc_build_plans(struct bootstrap *bootstrap)
{
	size_t unmatched = 0;
	int result;

	bootstrap->catalog = g_new0(struct hotdog_pdc_catalog, 1);
	result = hotdog_mcfg_catalog_load(
		bootstrap->mcfg_root, bootstrap->catalog, &bootstrap->mcfg_report);
	if (result) {
		g_printerr("MCFG catalog rejected: %d\n", result);
		return result;
	}
	result = hotdog_pdc_plan_cleanup(
		bootstrap->catalog, bootstrap->loaded_catalog.ids,
		bootstrap->loaded_catalog.count, bootstrap->pdc_subscriptions,
		HOTDOG_PDC_MAX_SUBSCRIPTIONS, &bootstrap->cleanup_plan, &unmatched);
	if (result)
		return result;
	result = hotdog_pdc_plan_activation(bootstrap->catalog,
		bootstrap->pdc_subscriptions, HOTDOG_PDC_MAX_SUBSCRIPTIONS,
		&bootstrap->activation_plan);
	return result;
}

static void pdc_print_plans(struct bootstrap *bootstrap)
{
	size_t index;
	size_t unmatched = bootstrap->cleanup_plan.count;

	printf("pdc-plan=result:%d catalog:%zu listed:%zu listed-missing:%zu operations:%zu\n",
	       0, bootstrap->catalog->count, bootstrap->mcfg_report.listed,
	       bootstrap->mcfg_report.listed_missing, bootstrap->activation_plan.count);
	for (index = 0; index < bootstrap->activation_plan.count; index++) {
		const struct hotdog_pdc_operation *operation =
			&bootstrap->activation_plan.operations[index];
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
	       bootstrap->loaded_catalog.count, unmatched, bootstrap->cleanup_plan.count);
	for (index = 0; index < bootstrap->cleanup_plan.count; index++) {
		printf("pdc-deferred-cleanup%zu=%s id:", index,
		       hotdog_pdc_operation_name(bootstrap->cleanup_plan.operations[index].type));
		print_pdc_id(&bootstrap->cleanup_plan.operations[index].id);
		printf("\n");
	}
}

static void pdc_controller_done(struct hotdog_pdc_controller *controller,
				int result,
				enum hotdog_pdc_executor_phase phase,
				void *user_data)
{
	struct bootstrap *bootstrap = user_data;

	(void)controller;
	printf("pdc-transaction=phase:%s result:%d\n",
	       hotdog_pdc_executor_phase_name(phase), result);
	if (!result && phase == HOTDOG_PDC_EXECUTOR_COMMITTED) {
		memcpy(bootstrap->pdc_subscriptions,
		       controller->executor.subscriptions,
		       sizeof(bootstrap->pdc_subscriptions));
		bootstrap->pdc_handoff = true;
		if (unlink(HOTDOG_READINESS_PATH) && errno != ENOENT) {
			g_printerr("Cannot remove stale readiness: %s\n", g_strerror(errno));
			finish(bootstrap, 1);
			return;
		}
		start_dms_probe(bootstrap);
		return;
	}
	finish(bootstrap, result ? 1 : 0);
}

static gboolean pdc_switch_timeout(gpointer user_data)
{
	struct bootstrap *bootstrap = user_data;

	bootstrap->switch_timeout_id = 0;
	if (bootstrap->pdc_controller.transport_down)
		hotdog_pdc_controller_reconnect_failed(
			&bootstrap->pdc_controller, -ETIMEDOUT);
	else
		hotdog_pdc_controller_switch_complete(
			&bootstrap->pdc_controller, -ETIMEDOUT);
	return G_SOURCE_REMOVE;
}

static void pdc_switch_required(struct hotdog_pdc_controller *controller,
				void *user_data)
{
	struct bootstrap *bootstrap = user_data;

	(void)controller;
	printf("pdc-switch=waiting-for-qrtr-restart\n");
	if (!bootstrap->switch_timeout_id)
		bootstrap->switch_timeout_id = g_timeout_add_seconds(
			45, pdc_switch_timeout, bootstrap);
}

static void pdc_reconnect_fail(struct bootstrap *bootstrap, int result)
{
	if (bootstrap->switch_timeout_id) {
		g_source_remove(bootstrap->switch_timeout_id);
		bootstrap->switch_timeout_id = 0;
	}
	hotdog_pdc_controller_reconnect_failed(&bootstrap->pdc_controller, result);
}

static void pdc_switch_client_ready(QmiDevice *device, GAsyncResult *res,
				    struct bootstrap *bootstrap)
{
	QmiClient *client;
	GError *error = NULL;
	int result;

	client = qmi_device_allocate_client_finish(device, res, &error);
	if (!client) {
		g_printerr("PDC reconnect client failed: %s\n", error->message);
		g_clear_error(&error);
		pdc_reconnect_fail(bootstrap, -EIO);
		return;
	}
	g_clear_object(&bootstrap->pdc);
	bootstrap->pdc = QMI_CLIENT_PDC(client);
	result = hotdog_qmi_pdc_backend_rebind(
		&bootstrap->pdc_backend, bootstrap->pdc, bootstrap->cancellable);
	if (result) {
		pdc_reconnect_fail(bootstrap, result);
		return;
	}
	g_clear_object(&bootstrap->device);
	bootstrap->device = g_object_ref(device);
	if (bootstrap->switch_node && bootstrap->switch_service_handler) {
		g_signal_handler_disconnect(bootstrap->switch_node,
					    bootstrap->switch_service_handler);
		bootstrap->switch_service_handler = 0;
	}
	g_clear_object(&bootstrap->switch_node);
	g_clear_object(&bootstrap->switch_device);
	if (bootstrap->switch_timeout_id) {
		g_source_remove(bootstrap->switch_timeout_id);
		bootstrap->switch_timeout_id = 0;
	}
	bootstrap->switch_reconnect_started = false;
	printf("pdc-switch=qrtr-pdc-reconnected\n");
	hotdog_pdc_controller_reconnected(&bootstrap->pdc_controller);
}

static void pdc_switch_open_ready(QmiDevice *device, GAsyncResult *res,
				  struct bootstrap *bootstrap)
{
	GError *error = NULL;

	if (!qmi_device_open_finish(device, res, &error)) {
		g_printerr("PDC reconnect device open failed: %s\n", error->message);
		g_clear_error(&error);
		pdc_reconnect_fail(bootstrap, -EIO);
		return;
	}
	qmi_device_allocate_client(device, QMI_SERVICE_PDC, QMI_CID_NONE, 15,
				   bootstrap->cancellable,
				   (GAsyncReadyCallback)pdc_switch_client_ready, bootstrap);
}

static void pdc_switch_device_ready(GObject *source, GAsyncResult *res,
				    struct bootstrap *bootstrap)
{
	GError *error = NULL;

	(void)source;
	g_clear_object(&bootstrap->switch_device);
	bootstrap->switch_device = qmi_device_new_finish(res, &error);
	if (!bootstrap->switch_device) {
		g_printerr("PDC reconnect device creation failed: %s\n", error->message);
		g_clear_error(&error);
		pdc_reconnect_fail(bootstrap, -EIO);
		return;
	}
	qmi_device_open(bootstrap->switch_device,
			QMI_DEVICE_OPEN_FLAGS_EXPECT_INDICATIONS, 15,
			bootstrap->cancellable,
			(GAsyncReadyCallback)pdc_switch_open_ready, bootstrap);
}

static void pdc_start_reconnect(struct bootstrap *bootstrap, QrtrNode *node)
{
	if (bootstrap->switch_reconnect_started)
		return;
	bootstrap->switch_reconnect_started = true;
	qmi_device_new_from_node(node, bootstrap->cancellable,
				 (GAsyncReadyCallback)pdc_switch_device_ready, bootstrap);
}

static void pdc_switch_service_added(QrtrNode *node, guint service,
				     struct bootstrap *bootstrap)
{
	if (service == QMI_SERVICE_PDC)
		pdc_start_reconnect(bootstrap, node);
}

static void qrtr_node_removed(QrtrBus *bus, guint node_id,
			      struct bootstrap *bootstrap)
{
	(void)bus;
	if (!bootstrap->pdc_controller_initialized || node_id != bootstrap->node)
		return;
	printf("pdc-switch=qrtr-node-removed\n");
	hotdog_pdc_controller_transport_lost(&bootstrap->pdc_controller);
	g_clear_object(&bootstrap->uim);
	g_clear_object(&bootstrap->dms);
	g_clear_object(&bootstrap->nas);
	g_clear_object(&bootstrap->pdc);
	g_clear_object(&bootstrap->device);
	bootstrap->pdc_indication_id = 0;
	bootstrap->pdc_list_indication_id = 0;
	bootstrap->switch_reconnect_started = false;
	if (!bootstrap->switch_timeout_id)
		bootstrap->switch_timeout_id = g_timeout_add_seconds(
			45, pdc_switch_timeout, bootstrap);
}

static void qrtr_node_added(QrtrBus *bus, guint node_id,
			    struct bootstrap *bootstrap)
{
	QrtrNode *node;

	if (!bootstrap->pdc_controller_initialized || node_id != bootstrap->node ||
	    !bootstrap->pdc_controller.transport_down)
		return;
	node = qrtr_bus_peek_node(bus, node_id);
	if (!node)
		return;
	g_clear_object(&bootstrap->switch_node);
	bootstrap->switch_node = g_object_ref(node);
	bootstrap->switch_service_handler = g_signal_connect(
		node, QRTR_NODE_SIGNAL_SERVICE_ADDED,
		G_CALLBACK(pdc_switch_service_added), bootstrap);
	if (qrtr_node_lookup_port(node, QMI_SERVICE_PDC) >= 0)
		pdc_start_reconnect(bootstrap, node);
}

static int pdc_apply_start(struct bootstrap *bootstrap)
{
	const struct hotdog_radio_gate_paths paths = {
		.approval = bootstrap->apply_pdc,
		.runtime_manifest = HOTDOG_MCFG_RUNTIME_MANIFEST,
		.boot_id = HOTDOG_BOOT_ID_PATH,
		.modem = HOTDOG_MODEM_CANONICAL_PATH,
		.mcfg_root = HOTDOG_MCFG_CANONICAL_ROOT,
	};
	int result;

	result = hotdog_radio_gate_validate(
		&paths, bootstrap->catalog, bootstrap->pdc_subscriptions,
		HOTDOG_PDC_MAX_SUBSCRIPTIONS, &bootstrap->runtime);
	if (result) {
		g_printerr("PDC execution gate rejected: %d\n", result);
		return result;
	}
	if (unlink(HOTDOG_READINESS_PATH) && errno != ENOENT) {
		g_printerr("Cannot remove stale readiness: %s\n", g_strerror(errno));
		return -errno;
	}
	result = hotdog_qmi_pdc_backend_init(
		&bootstrap->pdc_backend, bootstrap->pdc, bootstrap->cancellable,
		&bootstrap->pdc_token);
	if (result)
		return result;
	bootstrap->pdc_backend_initialized = true;
	result = hotdog_pdc_controller_init(
		&bootstrap->pdc_controller, &bootstrap->pdc_backend,
		&bootstrap->activation_plan, bootstrap->pdc_subscriptions,
		HOTDOG_PDC_MAX_SUBSCRIPTIONS, bootstrap->catalog,
		bootstrap->mcfg_root, pdc_controller_done, pdc_switch_required,
		bootstrap);
	if (result)
		return result;
	bootstrap->pdc_controller_initialized = true;
	printf("pdc-execution-gate=passed\n");
	return hotdog_pdc_controller_start(&bootstrap->pdc_controller);
}

static gboolean pdc_query_timeout(gpointer user_data)
{
	struct bootstrap *bootstrap = user_data;
	unsigned int subscription = pdc_planning(bootstrap) ?
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
	if (pdc_planning(bootstrap)) {
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
	if (pdc_planning(bootstrap)) {
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
	subscription = pdc_planning(bootstrap) ? (unsigned int)bootstrap->pdc_query_index :
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
		result = pdc_planning(bootstrap) ? pdc_build_plans(bootstrap) : 0;
		if (result) {
			finish(bootstrap, 1);
			return;
		}
		if (pdc_planning(bootstrap))
			pdc_print_plans(bootstrap);
		if (bootstrap->apply_pdc) {
			result = pdc_apply_start(bootstrap);
			if (result)
				finish(bootstrap, 1);
			return;
		}
		if (bootstrap->probe_dms)
			start_dms_probe(bootstrap);
		else
			finish(bootstrap, 0);
		return;
	}
	subscription = pdc_planning(bootstrap) ? (unsigned int)bootstrap->pdc_query_index :
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
	if (bootstrap->probe_pdc_catalog || pdc_planning(bootstrap)) {
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
	if (pdc_planning(bootstrap)) {
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
		else if (bootstrap->probe_nas)
			start_nas_probe(bootstrap);
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
	else if (bootstrap->probe_nas)
		start_nas_probe(bootstrap);
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
	if (result && !((bootstrap->pdc_probe_subscription >= 0 || pdc_planning(bootstrap) ||
			bootstrap->probe_dms || bootstrap->probe_nas ||
			bootstrap->probe_pdc_catalog) &&
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
#ifdef HOTDOG_QMI_PDC_SUBSCRIPTIONS
	if (bootstrap->apply_pdc) {
		bootstrap->bus_node_added_handler = g_signal_connect(
			bootstrap->bus, QRTR_BUS_SIGNAL_NODE_ADDED,
			G_CALLBACK(qrtr_node_added), bootstrap);
		bootstrap->bus_node_removed_handler = g_signal_connect(
			bootstrap->bus, QRTR_BUS_SIGNAL_NODE_REMOVED,
			G_CALLBACK(qrtr_node_removed), bootstrap);
	}
#endif
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
		{ "apply-pdc", 0, 0, G_OPTION_ARG_STRING, &bootstrap.apply_pdc,
		  "Execute the freshly rebuilt PDC plan using an approval manifest", "FILE" },
		{ "probe-dms", 0, 0, G_OPTION_ARG_NONE, &bootstrap.probe_dms,
		  "Read and print the DMS operating mode", NULL },
		{ "probe-pdc-catalog", 0, 0, G_OPTION_ARG_NONE,
		  &bootstrap.probe_pdc_catalog,
		  "Read and print resident software PDC config IDs", NULL },
		{ "probe-nas", 0, 0, G_OPTION_ARG_NONE, &bootstrap.probe_nas,
		  "Read and print the NAS serving-system state", NULL },
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
	if ((bootstrap.plan_pdc || bootstrap.apply_pdc) && !bootstrap.mcfg_root) {
		g_printerr("PDC planning or execution requires --mcfg-root\n");
		g_free(bootstrap.mcfg_root);
		g_free(bootstrap.apply_pdc);
		return 2;
	}
	if (bootstrap.mcfg_root && !bootstrap.plan_pdc && !bootstrap.apply_pdc) {
		g_printerr("--mcfg-root requires --plan-pdc or --apply-pdc\n");
		g_free(bootstrap.mcfg_root);
		g_free(bootstrap.apply_pdc);
		return 2;
	}
	if (bootstrap.plan_pdc && bootstrap.apply_pdc) {
		g_printerr("--plan-pdc and --apply-pdc are mutually exclusive\n");
		g_free(bootstrap.mcfg_root);
		g_free(bootstrap.apply_pdc);
		return 2;
	}
	if ((bootstrap.plan_pdc || bootstrap.apply_pdc) &&
	    bootstrap.pdc_probe_subscription >= 0) {
		g_printerr("PDC planning/execution requires a real populated UIM session\n");
		g_free(bootstrap.mcfg_root);
		g_free(bootstrap.apply_pdc);
		return 2;
	}
	if ((bootstrap.plan_pdc || bootstrap.apply_pdc) &&
	    (bootstrap.probe_dms || bootstrap.probe_nas)) {
		g_printerr("PDC planning/execution cannot be combined with standalone probes\n");
		g_free(bootstrap.mcfg_root);
		g_free(bootstrap.apply_pdc);
		return 2;
	}
	if (bootstrap.apply_pdc && strcmp(bootstrap.mcfg_root, HOTDOG_MCFG_CANONICAL_ROOT)) {
		g_printerr("PDC execution requires the canonical packaged MCFG root\n");
		g_free(bootstrap.mcfg_root);
		g_free(bootstrap.apply_pdc);
		return 2;
	}
	if (bootstrap.probe_pdc_catalog &&
	    (bootstrap.plan_pdc || bootstrap.apply_pdc || bootstrap.probe_dms ||
	     bootstrap.probe_nas ||
	     bootstrap.pdc_probe_subscription >= 0)) {
		g_printerr("PDC catalog probing must run as a separate read-only operation\n");
		g_free(bootstrap.mcfg_root);
		g_free(bootstrap.apply_pdc);
		return 2;
	}
	if (bootstrap.probe_dms && bootstrap.probe_nas) {
		g_printerr("DMS and NAS probes must run as separate read-only operations\n");
		g_free(bootstrap.mcfg_root);
		g_free(bootstrap.apply_pdc);
		return 2;
	}
#ifndef HOTDOG_QMI_PDC_SUBSCRIPTIONS
	if (bootstrap.pdc_probe_subscription >= 0 || bootstrap.plan_pdc ||
	    bootstrap.apply_pdc ||
	    bootstrap.probe_pdc_catalog) {
		g_printerr("PDC probing and planning require the patched libqmi build\n");
		g_free(bootstrap.mcfg_root);
		g_free(bootstrap.apply_pdc);
		return 2;
	}
#endif
	bootstrap.loop = g_main_loop_new(NULL, FALSE);
	bootstrap.cancellable = g_cancellable_new();
	qrtr_bus_new(1000, bootstrap.cancellable,
		     (GAsyncReadyCallback)bus_ready, &bootstrap);
	g_main_loop_run(bootstrap.loop);
#ifdef HOTDOG_QMI_PDC_SUBSCRIPTIONS
	if (bootstrap.switch_timeout_id)
		g_source_remove(bootstrap.switch_timeout_id);
	if (bootstrap.pdc_timeout_id)
		g_source_remove(bootstrap.pdc_timeout_id);
	if (bootstrap.pdc_list_timeout_id)
		g_source_remove(bootstrap.pdc_list_timeout_id);
	if (bootstrap.pdc && bootstrap.pdc_indication_id)
		g_signal_handler_disconnect(bootstrap.pdc, bootstrap.pdc_indication_id);
	if (bootstrap.pdc && bootstrap.pdc_list_indication_id)
		g_signal_handler_disconnect(bootstrap.pdc, bootstrap.pdc_list_indication_id);
	if (bootstrap.switch_node && bootstrap.switch_service_handler)
		g_signal_handler_disconnect(bootstrap.switch_node,
					    bootstrap.switch_service_handler);
	if (bootstrap.pdc_controller_initialized && !bootstrap.pdc_controller.finished)
		hotdog_pdc_controller_cancel(&bootstrap.pdc_controller);
	if (bootstrap.pdc_backend_initialized)
		hotdog_qmi_pdc_backend_clear(&bootstrap.pdc_backend);
	release_client(&bootstrap, QMI_CLIENT(bootstrap.pdc));
	g_clear_object(&bootstrap.pdc);
	g_clear_object(&bootstrap.switch_device);
	g_clear_object(&bootstrap.switch_node);
#endif
	release_client(&bootstrap, QMI_CLIENT(bootstrap.uim));
	g_clear_object(&bootstrap.uim);
	release_client(&bootstrap, QMI_CLIENT(bootstrap.dms));
	g_clear_object(&bootstrap.dms);
	release_client(&bootstrap, QMI_CLIENT(bootstrap.nas));
	g_clear_object(&bootstrap.nas);
	g_clear_object(&bootstrap.device);
	if (bootstrap.bus && bootstrap.bus_node_added_handler)
		g_signal_handler_disconnect(bootstrap.bus,
					    bootstrap.bus_node_added_handler);
	if (bootstrap.bus && bootstrap.bus_node_removed_handler)
		g_signal_handler_disconnect(bootstrap.bus,
					    bootstrap.bus_node_removed_handler);
	g_clear_object(&bootstrap.bus);
	g_clear_object(&bootstrap.cancellable);
	g_main_loop_unref(bootstrap.loop);
#ifdef HOTDOG_QMI_PDC_SUBSCRIPTIONS
	g_free(bootstrap.catalog);
#endif
	g_free(bootstrap.mcfg_root);
	g_free(bootstrap.apply_pdc);
	return bootstrap.result;
}
