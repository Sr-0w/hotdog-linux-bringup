/* SPDX-License-Identifier: GPL-2.0-only */
#include "hotdog-qmi-pdc-backend.h"

#include "hotdog-qmi-pdc.h"
#include "hotdog-qmi-pdc-load.h"

#include <errno.h>
#include <string.h>

static void backend_finish(struct hotdog_qmi_pdc_backend *backend,
			   int result, uint16_t remote_result)
{
	hotdog_qmi_pdc_backend_done done;
	void *user_data;

	if (!backend->active)
		return;
	backend->active = false;
	if (backend->timeout_id) {
		g_source_remove(backend->timeout_id);
		backend->timeout_id = 0;
	}
	if (backend->indication_handler) {
		g_signal_handler_disconnect(backend->client, backend->indication_handler);
		backend->indication_handler = 0;
	}
	done = backend->done;
	user_data = backend->user_data;
	backend->done = NULL;
	backend->user_data = NULL;
	if (done)
		done(backend, result, remote_result, user_data);
}

static gboolean backend_timeout(gpointer user_data)
{
	struct hotdog_qmi_pdc_backend *backend = user_data;

	backend->timeout_id = 0;
	backend_finish(backend, -ETIMEDOUT, 0);
	return G_SOURCE_REMOVE;
}

static int response_status(gboolean have_token, guint32 token,
			   gboolean success, GError *error,
			   uint32_t expected, uint16_t *remote)
{
	*remote = 0;
	if (!have_token)
		return -ENODATA;
	if (token != expected)
		return -ESTALE;
	if (!success) {
		if (error && error->domain == QMI_PROTOCOL_ERROR)
			*remote = (uint16_t)error->code;
		return -EREMOTEIO;
	}
	return 0;
}

static void load_response(QmiClientPdc *client, GAsyncResult *res,
			  struct hotdog_qmi_pdc_backend *backend)
{
	QmiMessagePdcLoadConfigOutput *output;
	GError *error = NULL;
	guint32 token = 0;
	uint16_t remote;
	gboolean have_token, success;
	int result;

	output = qmi_client_pdc_load_config_finish(client, res, &error);
	if (!output) {
		backend_finish(backend, -EIO, 0);
		g_clear_error(&error);
		return;
	}
	have_token = qmi_message_pdc_load_config_output_get_token(output, &token, NULL);
	success = qmi_message_pdc_load_config_output_get_result(output, &error);
	result = response_status(have_token, token, success, error,
				 backend->request->token, &remote);
	qmi_message_pdc_load_config_output_unref(output);
	g_clear_error(&error);
	if (result)
		backend_finish(backend, result, remote);
}

static int send_load(struct hotdog_qmi_pdc_backend *backend)
{
	qmi_client_pdc_load_config(backend->client, backend->request->input.load, 10,
				   backend->cancellable,
				   (GAsyncReadyCallback)load_response, backend);
	return 0;
}

static void load_indication(QmiClientPdc *client,
			    QmiIndicationPdcLoadConfigOutput *output,
			    struct hotdog_qmi_pdc_backend *backend)
{
	uint16_t remote = 0;
	int result;

	(void)client;
	result = hotdog_qmi_pdc_decode_load(output, &backend->request->load_state, &remote);
	if (result == -ESTALE)
		return;
	if (result) {
		backend_finish(backend, result, remote);
		return;
	}
	if (backend->request->load_state.complete) {
		backend_finish(backend, 0, 0);
		return;
	}
	if (backend->timeout_id)
		g_source_remove(backend->timeout_id);
	backend->timeout_id = g_timeout_add_seconds(15, backend_timeout, backend);
	result = hotdog_qmi_pdc_request_load_next(
		backend->request, ++*backend->token_counter);
	if (result)
		backend_finish(backend, result, 0);
	else
		send_load(backend);
}

#define DEFINE_RESPONSE(name, Type, finish_fn, token_fn, result_fn, unref_fn) \
static void name(QmiClientPdc *client, GAsyncResult *res, \
		 struct hotdog_qmi_pdc_backend *backend) \
{ \
	Type *output; GError *error = NULL; guint32 token = 0; uint16_t remote; int result; \
	gboolean have_token, success; \
	output = finish_fn(client, res, &error); \
	if (!output) { backend_finish(backend, -EIO, 0); g_clear_error(&error); return; } \
	have_token = token_fn(output, &token, NULL); success = result_fn(output, &error); \
	result = response_status(have_token, token, success, error, \
		backend->request->token, &remote); \
	unref_fn(output); g_clear_error(&error); \
	if (result) backend_finish(backend, result, remote); \
}

DEFINE_RESPONSE(set_response, QmiMessagePdcSetSelectedConfigOutput,
	qmi_client_pdc_set_selected_config_finish,
	qmi_message_pdc_set_selected_config_output_get_token,
	qmi_message_pdc_set_selected_config_output_get_result,
	qmi_message_pdc_set_selected_config_output_unref)
DEFINE_RESPONSE(activate_response, QmiMessagePdcActivateConfigOutput,
	qmi_client_pdc_activate_config_finish,
	qmi_message_pdc_activate_config_output_get_token,
	qmi_message_pdc_activate_config_output_get_result,
	qmi_message_pdc_activate_config_output_unref)
DEFINE_RESPONSE(deactivate_response, QmiMessagePdcDeactivateConfigOutput,
	qmi_client_pdc_deactivate_config_finish,
	qmi_message_pdc_deactivate_config_output_get_token,
	qmi_message_pdc_deactivate_config_output_get_result,
	qmi_message_pdc_deactivate_config_output_unref)

static void set_indication(QmiClientPdc *client,
			   QmiIndicationPdcSetSelectedConfigOutput *output,
			   struct hotdog_qmi_pdc_backend *backend)
{
	uint16_t remote = 0;
	int result;

	(void)client;
	result = hotdog_qmi_pdc_decode_set_selected(
		output, backend->request->token, &remote);
	if (result != -ESTALE)
		backend_finish(backend, result, remote);
}

static void activate_indication(QmiClientPdc *client,
				QmiIndicationPdcActivateConfigOutput *output,
				struct hotdog_qmi_pdc_backend *backend)
{
	uint16_t remote = 0;
	int result;

	(void)client;
	result = hotdog_qmi_pdc_decode_activate(output, backend->request->token, &remote);
	if (result != -ESTALE)
		backend_finish(backend, result, remote);
}

static void deactivate_indication(QmiClientPdc *client,
				  QmiIndicationPdcDeactivateConfigOutput *output,
				  struct hotdog_qmi_pdc_backend *backend)
{
	uint16_t remote = 0;
	int result;

	(void)client;
	result = hotdog_qmi_pdc_decode_deactivate(output, backend->request->token, &remote);
	if (result != -ESTALE)
		backend_finish(backend, result, remote);
}

static void delete_response(QmiClientPdc *client, GAsyncResult *res,
			    struct hotdog_qmi_pdc_backend *backend)
{
	QmiMessagePdcDeleteConfigOutput *output;
	GError *error = NULL;
	uint16_t remote = 0;
	int result;

	output = qmi_client_pdc_delete_config_finish(client, res, &error);
	if (!output) {
		backend_finish(backend, -EIO, 0);
		g_clear_error(&error);
		return;
	}
	result = hotdog_qmi_pdc_decode_delete(
		output, backend->request->token, &remote);
	qmi_message_pdc_delete_config_output_unref(output);
	g_clear_error(&error);
	backend_finish(backend, result, remote);
}

static void verify_response(QmiClientPdc *client, GAsyncResult *res,
			    struct hotdog_qmi_pdc_backend *backend)
{
	QmiMessagePdcGetSelectedConfigOutput *output;
	GError *error = NULL;

	output = qmi_client_pdc_get_selected_config_finish(client, res, &error);
	if (!output || !qmi_message_pdc_get_selected_config_output_get_result(output, &error))
		backend_finish(backend, -EIO, 0);
	if (output)
		qmi_message_pdc_get_selected_config_output_unref(output);
	g_clear_error(&error);
}

static void verify_indication(QmiClientPdc *client,
			      QmiIndicationPdcGetSelectedConfigOutput *output,
			      struct hotdog_qmi_pdc_backend *backend)
{
	struct hotdog_pdc_id active, pending;
	uint16_t remote = 0;
	int result;

	(void)client;
	result = hotdog_qmi_pdc_decode_selected(
		output, backend->request->token, &active, &pending, &remote);
	if (result == -ESTALE)
		return;
	if (!result && (!hotdog_pdc_id_equal(&active, &backend->request->operation.id) ||
			pending.length))
		result = -EPROTO;
	backend_finish(backend, result, remote);
}

int hotdog_qmi_pdc_backend_init(struct hotdog_qmi_pdc_backend *backend,
				QmiClientPdc *client, GCancellable *cancellable,
				uint32_t *token_counter)
{
	if (!backend || !client || !cancellable || !token_counter)
		return -EINVAL;
	memset(backend, 0, sizeof(*backend));
	backend->client = g_object_ref(client);
	backend->cancellable = g_object_ref(cancellable);
	backend->token_counter = token_counter;
	return 0;
}

int hotdog_qmi_pdc_backend_start(struct hotdog_qmi_pdc_backend *backend,
				 struct hotdog_qmi_pdc_request *request,
				 hotdog_qmi_pdc_backend_done done,
				 void *user_data)
{
	if (!backend || !backend->client || !request || !done || backend->active)
		return -EINVAL;
	if (request->type == HOTDOG_QMI_PDC_REQUEST_SWITCH)
		return -EINPROGRESS;
	backend->request = request;
	backend->done = done;
	backend->user_data = user_data;
	backend->active = true;
	if (request->type == HOTDOG_QMI_PDC_REQUEST_LOCAL) {
		backend_finish(backend, 0, 0);
		return 0;
	}
	backend->timeout_id = g_timeout_add_seconds(15, backend_timeout, backend);
	switch (request->type) {
	case HOTDOG_QMI_PDC_REQUEST_LOAD:
		backend->indication_handler = g_signal_connect(
			backend->client, "load-config", G_CALLBACK(load_indication), backend);
		return send_load(backend);
	case HOTDOG_QMI_PDC_REQUEST_SET:
		backend->indication_handler = g_signal_connect(
			backend->client, "set-selected-config", G_CALLBACK(set_indication), backend);
		qmi_client_pdc_set_selected_config(
			backend->client, request->input.set, 10, backend->cancellable,
			(GAsyncReadyCallback)set_response, backend);
		return 0;
	case HOTDOG_QMI_PDC_REQUEST_ACTIVATE:
		backend->indication_handler = g_signal_connect(
			backend->client, "activate-config", G_CALLBACK(activate_indication), backend);
		qmi_client_pdc_activate_config(
			backend->client, request->input.activate, 10, backend->cancellable,
			(GAsyncReadyCallback)activate_response, backend);
		return 0;
	case HOTDOG_QMI_PDC_REQUEST_DEACTIVATE:
		backend->indication_handler = g_signal_connect(
			backend->client, "deactivate-config", G_CALLBACK(deactivate_indication), backend);
		qmi_client_pdc_deactivate_config(
			backend->client, request->input.deactivate, 10, backend->cancellable,
			(GAsyncReadyCallback)deactivate_response, backend);
		return 0;
	case HOTDOG_QMI_PDC_REQUEST_DELETE:
		qmi_client_pdc_delete_config(
			backend->client, request->input.delete_config, 10, backend->cancellable,
			(GAsyncReadyCallback)delete_response, backend);
		return 0;
	case HOTDOG_QMI_PDC_REQUEST_VERIFY:
		backend->indication_handler = g_signal_connect(
			backend->client, "get-selected-config", G_CALLBACK(verify_indication), backend);
		qmi_client_pdc_get_selected_config(
			backend->client, request->input.verify, 10, backend->cancellable,
			(GAsyncReadyCallback)verify_response, backend);
		return 0;
	case HOTDOG_QMI_PDC_REQUEST_LOCAL:
	case HOTDOG_QMI_PDC_REQUEST_SWITCH:
		break;
	}
	backend_finish(backend, -EINVAL, 0);
	return -EINVAL;
}

void hotdog_qmi_pdc_backend_cancel(struct hotdog_qmi_pdc_backend *backend)
{
	if (backend && backend->active)
		backend_finish(backend, -ECANCELED, 0);
}

void hotdog_qmi_pdc_backend_clear(struct hotdog_qmi_pdc_backend *backend)
{
	if (!backend)
		return;
	hotdog_qmi_pdc_backend_cancel(backend);
	g_clear_object(&backend->client);
	g_clear_object(&backend->cancellable);
	memset(backend, 0, sizeof(*backend));
}
