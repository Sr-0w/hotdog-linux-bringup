/* SPDX-License-Identifier: GPL-2.0-only */
#define _POSIX_C_SOURCE 200809L
#include "hotdog-qmi-ims-session.h"
#include "hotdog-qmi-wds-profile.h"

#include <errno.h>
#include <string.h>

#define SESSION_TIMEOUT_SECONDS 20

#if QMI_CHECK_VERSION(1, 37, 0)
struct request_context {
	struct hotdog_qmi_ims_session *session;
	unsigned int generation;
	unsigned int leg;
};

static void dispatch(struct hotdog_qmi_ims_session *session,
		     const struct hotdog_ims_executor_operation *operation);

static struct request_context *request_new(
	struct hotdog_qmi_ims_session *session, unsigned int leg)
{
	struct request_context *request = g_new0(struct request_context, 1);

	request->session = session;
	request->generation = session->generation;
	request->leg = leg;
	return request;
}

static bool request_current(const struct request_context *request)
{
	return request->generation == request->session->generation;
}
#else
static void dispatch(struct hotdog_qmi_ims_session *session,
		     const struct hotdog_ims_executor_operation *operation);
#endif

static void notify(struct hotdog_qmi_ims_session *session,
		   enum hotdog_qmi_ims_session_event event, unsigned int error)
{
	if (session->callback)
		session->callback(session, event, error, session->user_data);
}

#if QMI_CHECK_VERSION(1, 37, 0)
static void cleanup_blocked(struct hotdog_qmi_ims_session *session,
			    unsigned int error)
{
	if (!error)
		error = EIO;
	if (hotdog_ims_executor_cleanup_failed(&session->executor, error))
		session->executor.phase = HOTDOG_IMS_EXECUTOR_BLOCKED;
	notify(session, HOTDOG_QMI_IMS_SESSION_BLOCKED, error);
}

static void fail(struct hotdog_qmi_ims_session *session, unsigned int error)
{
	struct hotdog_ims_executor_operation operation;

	if (!error)
		error = EIO;
	if (session->executor.phase == HOTDOG_IMS_EXECUTOR_STOPPING ||
	    session->executor.phase == HOTDOG_IMS_EXECUTOR_RELEASING_CLIENTS ||
	    session->executor.phase == HOTDOG_IMS_EXECUTOR_DELETING_LINK) {
		cleanup_blocked(session, error);
		return;
	}
	if (hotdog_ims_executor_fail(&session->executor, error, &operation)) {
		notify(session, HOTDOG_QMI_IMS_SESSION_BLOCKED, error);
		return;
	}
	dispatch(session, &operation);
}

static bool qmi_result(gboolean success, GError *error, unsigned int *code)
{
	*code = EREMOTEIO;
	if (success) {
		g_clear_error(&error);
		return true;
	}
	if (error && error->domain == QMI_PROTOCOL_ERROR)
		*code = (unsigned int)error->code;
	g_clear_error(&error);
	return false;
}

static void add_link_ready(QmiDevice *device, GAsyncResult *res,
			   struct request_context *request)
{
	struct hotdog_qmi_ims_session *session = request->session;
	struct hotdog_ims_executor_operation operation;
	GError *error = NULL;
	guint mux_id = 0;
	gchar *ifname;
	int result;

	ifname = qmi_device_add_link_with_flags_finish(device, res, &mux_id, &error);
	if (!request_current(request)) {
		if (ifname)
			qmi_device_delete_link(device, ifname, mux_id, NULL, NULL, NULL);
		g_clear_error(&error);
		g_free(ifname);
		g_free(request);
		return;
	}
	if (!ifname) {
		g_clear_error(&error);
		g_free(request);
		fail(session, EIO);
		return;
	}
	result = hotdog_ims_executor_link_added(
		&session->executor, ifname, mux_id, &operation);
	if (!result)
		result = hotdog_qmi_rmnet_link_validate(
			&session->config.rmnet, ifname, mux_id);
	if (!result) {
		memset(&session->bearer, 0, sizeof(session->bearer));
		session->bearer.subscription = session->config.profile.subscription;
		session->bearer.profile = session->config.profile.index;
		session->bearer.mux_id = mux_id;
		session->bearer.family = session->config.profile.family;
		session->bearer.auth = HOTDOG_AUTH_NONE;
		session->bearer.purpose = HOTDOG_BEARER_IMS;
		session->bearer.state = HOTDOG_BEARER_STARTING;
		memcpy(session->bearer.apn, session->config.profile.apn,
		       strlen(session->config.profile.apn) + 1);
		result = hotdog_qmi_wds_plan_build(
			&session->bearer, NULL, session->config.rmnet.endpoint_type,
			session->config.rmnet.endpoint_interface,
			QMI_WDS_CLIENT_TYPE_UNDEFINED, &session->wds);
	}
	g_free(ifname);
	g_free(request);
	if (result) {
		fail(session, (unsigned int)-result);
		return;
	}
	dispatch(session, &operation);
}

static void client_ready(QmiDevice *device, GAsyncResult *res,
			 struct request_context *request)
{
	struct hotdog_qmi_ims_session *session = request->session;
	struct hotdog_ims_executor_operation operation;
	QmiClient *client;
	GError *error = NULL;
	int result;

	client = qmi_device_allocate_client_finish(device, res, &error);
	if (!request_current(request)) {
		g_clear_error(&error);
		g_clear_object(&client);
		g_free(request);
		return;
	}
	if (!client) {
		g_clear_error(&error);
		g_free(request);
		fail(session, EIO);
		return;
	}
	session->clients[request->leg] = QMI_CLIENT_WDS(client);
	result = hotdog_ims_executor_client_allocated(
		&session->executor, request->leg, &operation);
	g_free(request);
	if (result) {
		fail(session, (unsigned int)-result);
		return;
	}
	dispatch(session, &operation);
}

static void bind_mux_ready(QmiClientWds *client, GAsyncResult *res,
			   struct request_context *request)
{
	struct hotdog_qmi_ims_session *session = request->session;
	struct hotdog_ims_executor_operation operation;
	g_autoptr(QmiMessageWdsBindMuxDataPortOutput) output = NULL;
	GError *error = NULL;
	unsigned int code = EREMOTEIO;
	gboolean success;
	int result;

	output = qmi_client_wds_bind_mux_data_port_finish(client, res, &error);
	if (!request_current(request)) {
		g_clear_error(&error);
		g_free(request);
		return;
	}
	success = output &&
		qmi_message_wds_bind_mux_data_port_output_get_result(output, &error);
	if (!output || !qmi_result(success, error, &code)) {
		g_free(request);
		fail(session, code);
		return;
	}
	result = hotdog_ims_executor_leg_bound(
		&session->executor, request->leg, &operation);
	g_free(request);
	if (result) {
		fail(session, (unsigned int)-result);
		return;
	}
	dispatch(session, &operation);
}

static void bind_subscription_ready(QmiClientWds *client, GAsyncResult *res,
				    struct request_context *request)
{
	struct hotdog_qmi_ims_session *session = request->session;
	g_autoptr(QmiMessageWdsBindSubscriptionOutput) output = NULL;
	uint16_t remote = 0;
	GError *error = NULL;
	int result;

	output = qmi_client_wds_bind_subscription_finish(client, res, &error);
	if (!request_current(request)) {
		g_clear_error(&error);
		g_free(request);
		return;
	}
	if (!output) {
		g_clear_error(&error);
		g_free(request);
		fail(session, EIO);
		return;
	}
	result = hotdog_qmi_wds_decode_bind_subscription(output, &remote);
	if (result) {
		g_free(request);
		fail(session, remote ? remote : (unsigned int)-result);
		return;
	}
	qmi_client_wds_bind_mux_data_port(
		client, session->wds.legs[request->leg].bind,
		SESSION_TIMEOUT_SECONDS, session->cancellable,
		(GAsyncReadyCallback)bind_mux_ready, request);
}

static void start_ready(QmiClientWds *client, GAsyncResult *res,
			struct request_context *request)
{
	struct hotdog_qmi_ims_session *session = request->session;
	struct hotdog_ims_executor_operation operation;
	g_autoptr(QmiMessageWdsStartNetworkOutput) output = NULL;
	uint32_t packet_handle = 0;
	uint16_t remote = 0;
	GError *error = NULL;
	int result;

	output = qmi_client_wds_start_network_finish(client, res, &error);
	if (!request_current(request)) {
		g_clear_error(&error);
		g_free(request);
		return;
	}
	if (!output) {
		g_clear_error(&error);
		g_free(request);
		fail(session, EIO);
		return;
	}
	result = hotdog_qmi_wds_decode_start(output, &packet_handle, &remote);
	if (!result)
		result = hotdog_ims_executor_leg_started(
			&session->executor, request->leg, packet_handle, &operation);
	g_free(request);
	if (result) {
		fail(session, remote ? remote : (unsigned int)-result);
		return;
	}
	dispatch(session, &operation);
}

static void settings_ready(QmiClientWds *client, GAsyncResult *res,
			   struct request_context *request)
{
	struct hotdog_qmi_ims_session *session = request->session;
	struct hotdog_ims_executor_operation operation;
	g_autoptr(QmiMessageWdsGetCurrentSettingsOutput) output = NULL;
	QmiWdsIpFamily family = session->wds.legs[request->leg].family;
	uint16_t remote = 0;
	GError *error = NULL;
	int result;

	output = qmi_client_wds_get_current_settings_finish(client, res, &error);
	if (!request_current(request)) {
		g_clear_error(&error);
		g_free(request);
		return;
	}
	if (!output) {
		g_clear_error(&error);
		g_free(request);
		fail(session, EIO);
		return;
	}
	result = hotdog_qmi_wds_decode_current_settings(
		output, family, &session->runtime, &remote);
	if (!result)
		result = hotdog_ims_executor_settings_read(
			&session->executor, request->leg, &operation);
	g_free(request);
	if (result) {
		fail(session, remote ? remote : (unsigned int)-result);
		return;
	}
	dispatch(session, &operation);
}

static void stop_ready(QmiClientWds *client, GAsyncResult *res,
		       struct request_context *request)
{
	struct hotdog_qmi_ims_session *session = request->session;
	struct hotdog_ims_executor_operation operation;
	g_autoptr(QmiMessageWdsStopNetworkOutput) output = NULL;
	GError *error = NULL;
	unsigned int code = EREMOTEIO;
	gboolean success;
	int result;

	output = qmi_client_wds_stop_network_finish(client, res, &error);
	if (!request_current(request)) {
		g_clear_error(&error);
		g_free(request);
		return;
	}
	success = output && qmi_message_wds_stop_network_output_get_result(output, &error);
	if (!output || !qmi_result(success, error, &code)) {
		g_free(request);
		cleanup_blocked(session, code);
		return;
	}
	result = hotdog_ims_executor_leg_stopped(
		&session->executor, request->leg,
		session->executor.packet_handles[request->leg], &operation);
	g_free(request);
	if (result) {
		cleanup_blocked(session, (unsigned int)-result);
		return;
	}
	dispatch(session, &operation);
}

static void release_next(struct hotdog_qmi_ims_session *session);

static void release_ready(QmiDevice *device, GAsyncResult *res,
			  struct request_context *request)
{
	struct hotdog_qmi_ims_session *session = request->session;
	GError *error = NULL;

	if (!qmi_device_release_client_finish(device, res, &error)) {
		if (request_current(request)) {
			g_clear_error(&error);
			g_free(request);
			cleanup_blocked(session, EIO);
			return;
		}
		g_clear_error(&error);
	}
	if (!request_current(request)) {
		g_free(request);
		return;
	}
	g_clear_object(&session->clients[request->leg]);
	session->release_leg = request->leg + 1;
	g_free(request);
	release_next(session);
}

static void release_next(struct hotdog_qmi_ims_session *session)
{
	struct hotdog_ims_executor_operation operation;

	while (session->release_leg < session->executor.leg_count &&
	       !session->clients[session->release_leg])
		session->release_leg++;
	if (session->release_leg < session->executor.leg_count) {
		unsigned int leg = session->release_leg;

		qmi_device_release_client(
			session->config.device, QMI_CLIENT(session->clients[leg]),
			QMI_DEVICE_RELEASE_CLIENT_FLAGS_RELEASE_CID,
			SESSION_TIMEOUT_SECONDS, session->cancellable,
			(GAsyncReadyCallback)release_ready, request_new(session, leg));
		return;
	}
	if (hotdog_ims_executor_clients_released(&session->executor, &operation)) {
		cleanup_blocked(session, EPROTO);
		return;
	}
	dispatch(session, &operation);
}

static void delete_link_ready(QmiDevice *device, GAsyncResult *res,
			      struct request_context *request)
{
	struct hotdog_qmi_ims_session *session = request->session;
	struct hotdog_ims_executor_operation operation;
	GError *error = NULL;
	int result;

	if (!qmi_device_delete_link_finish(device, res, &error)) {
		if (request_current(request)) {
			g_clear_error(&error);
			g_free(request);
			cleanup_blocked(session, EIO);
			return;
		}
		g_clear_error(&error);
	}
	if (!request_current(request)) {
		g_free(request);
		return;
	}
	result = hotdog_ims_executor_link_deleted(&session->executor, &operation);
	g_free(request);
	if (result) {
		cleanup_blocked(session, (unsigned int)-result);
		return;
	}
	dispatch(session, &operation);
}

static void dispatch(struct hotdog_qmi_ims_session *session,
		     const struct hotdog_ims_executor_operation *operation)
{
	struct request_context *request;

	switch (operation->action) {
	case HOTDOG_IMS_EXECUTOR_ACTION_ADD_LINK:
		qmi_device_add_link_with_flags(
			session->config.device, QMI_DEVICE_MUX_ID_AUTOMATIC,
			session->config.rmnet.base_ifname, session->config.rmnet.prefix,
			session->config.rmnet.flags, session->cancellable,
			(GAsyncReadyCallback)add_link_ready, request_new(session, 0));
		return;
	case HOTDOG_IMS_EXECUTOR_ACTION_ALLOCATE_CLIENTS:
		qmi_device_allocate_client(
			session->config.device, QMI_SERVICE_WDS, QMI_CID_NONE,
			SESSION_TIMEOUT_SECONDS, session->cancellable,
			(GAsyncReadyCallback)client_ready,
			request_new(session, operation->leg));
		return;
	case HOTDOG_IMS_EXECUTOR_ACTION_BIND_LEG: {
		g_autoptr(QmiMessageWdsBindSubscriptionInput) input = NULL;

		if (hotdog_qmi_wds_bind_subscription_input(
		    session->config.profile.subscription, &input)) {
			fail(session, EINVAL);
			return;
		}
		qmi_client_wds_bind_subscription(
			session->clients[operation->leg], input, SESSION_TIMEOUT_SECONDS,
			session->cancellable, (GAsyncReadyCallback)bind_subscription_ready,
			request_new(session, operation->leg));
		return;
	}
	case HOTDOG_IMS_EXECUTOR_ACTION_START_LEG:
		qmi_client_wds_start_network(
			session->clients[operation->leg], session->wds.legs[operation->leg].start,
			SESSION_TIMEOUT_SECONDS, session->cancellable,
			(GAsyncReadyCallback)start_ready, request_new(session, operation->leg));
		return;
	case HOTDOG_IMS_EXECUTOR_ACTION_READ_SETTINGS: {
		g_autoptr(QmiMessageWdsGetCurrentSettingsInput) input = NULL;

		if (hotdog_qmi_wds_current_settings_input(&input)) {
			fail(session, EINVAL);
			return;
		}
		qmi_client_wds_get_current_settings(
			session->clients[operation->leg], input, SESSION_TIMEOUT_SECONDS,
			session->cancellable, (GAsyncReadyCallback)settings_ready,
			request_new(session, operation->leg));
		return;
	}
	case HOTDOG_IMS_EXECUTOR_ACTION_CONFIGURE_LINK:
		notify(session, HOTDOG_QMI_IMS_SESSION_CONFIGURE_REQUIRED, 0);
		return;
	case HOTDOG_IMS_EXECUTOR_ACTION_STOP_LEG: {
		g_autoptr(QmiMessageWdsStopNetworkInput) input = NULL;

		if (hotdog_qmi_wds_stop_input(operation->packet_handle, &input)) {
			cleanup_blocked(session, EINVAL);
			return;
		}
		request = request_new(session, operation->leg);
		qmi_client_wds_stop_network(
			session->clients[operation->leg], input, SESSION_TIMEOUT_SECONDS,
			session->cancellable, (GAsyncReadyCallback)stop_ready, request);
		return;
	}
	case HOTDOG_IMS_EXECUTOR_ACTION_RELEASE_CLIENTS:
		session->release_leg = 0;
		release_next(session);
		return;
	case HOTDOG_IMS_EXECUTOR_ACTION_DELETE_LINK:
		qmi_device_delete_link(
			session->config.device, session->executor.ifname,
			session->executor.mux_id, session->cancellable,
			(GAsyncReadyCallback)delete_link_ready, request_new(session, 0));
		return;
	case HOTDOG_IMS_EXECUTOR_ACTION_PUBLISH_UP:
		notify(session, HOTDOG_QMI_IMS_SESSION_UP, 0);
		return;
	case HOTDOG_IMS_EXECUTOR_ACTION_PUBLISH_DOWN:
		hotdog_qmi_wds_plan_clear(&session->wds);
		g_clear_object(&session->config.device);
		g_clear_object(&session->cancellable);
		notify(session, HOTDOG_QMI_IMS_SESSION_DOWN, session->executor.error);
		return;
	case HOTDOG_IMS_EXECUTOR_ACTION_NONE:
		break;
	}
	cleanup_blocked(session, EPROTO);
}
#else
static void dispatch(struct hotdog_qmi_ims_session *session,
		     const struct hotdog_ims_executor_operation *operation)
{
	(void)operation;
	notify(session, HOTDOG_QMI_IMS_SESSION_BLOCKED, EOPNOTSUPP);
}
#endif

void hotdog_qmi_ims_session_init(struct hotdog_qmi_ims_session *session)
{
	if (!session)
		return;
	memset(session, 0, sizeof(*session));
	hotdog_ims_executor_init(&session->executor);
	session->initialized = true;
}

int hotdog_qmi_ims_session_start(
	struct hotdog_qmi_ims_session *session,
	const struct hotdog_qmi_ims_session_config *config,
	hotdog_qmi_ims_session_callback callback, void *user_data)
{
	struct hotdog_ims_executor_operation operation;
	int result;

	if (!session || !session->initialized || !config || !config->device ||
	    !callback || config->profile.subscription >= HOTDOG_NETWORK_MAX_SUBSCRIPTIONS ||
	    !config->profile.index || !config->profile.apn[0] ||
	    config->profile.purpose != HOTDOG_BEARER_IMS ||
	    config->profile.family > HOTDOG_IP_V4V6)
		return -EINVAL;
	if (session->executor.phase != HOTDOG_IMS_EXECUTOR_IDLE &&
	    session->executor.phase != HOTDOG_IMS_EXECUTOR_FAILED)
		return -EBUSY;
#if !QMI_CHECK_VERSION(1, 37, 0)
	(void)user_data;
	return -EOPNOTSUPP;
#endif
	session->config = *config;
	session->config.device = g_object_ref(config->device);
	session->callback = callback;
	session->user_data = user_data;
	session->generation++;
	session->cancellable = g_cancellable_new();
	memset(&session->runtime, 0, sizeof(session->runtime));
	result = hotdog_ims_executor_begin(
		&session->executor, config->profile.family, &operation);
	if (result) {
		g_clear_object(&session->config.device);
		g_clear_object(&session->cancellable);
		return result;
	}
	dispatch(session, &operation);
	return 0;
}

int hotdog_qmi_ims_session_configured(struct hotdog_qmi_ims_session *session)
{
	struct hotdog_ims_executor_operation operation;
	int result;

	if (!session || !session->initialized)
		return -EINVAL;
	result = hotdog_ims_executor_configured(&session->executor, &operation);
	if (!result)
		dispatch(session, &operation);
	return result;
}

int hotdog_qmi_ims_session_stop(struct hotdog_qmi_ims_session *session)
{
	struct hotdog_ims_executor_operation operation;
	int result;

	if (!session || !session->initialized)
		return -EINVAL;
	result = hotdog_ims_executor_stop(&session->executor, &operation);
	if (!result)
		dispatch(session, &operation);
	return result;
}

int hotdog_qmi_ims_session_ssr(struct hotdog_qmi_ims_session *session)
{
	struct hotdog_ims_executor_operation operation;
	unsigned int index;
	int result;

	if (!session || !session->initialized)
		return -EINVAL;
	session->generation++;
	if (session->cancellable)
		g_cancellable_cancel(session->cancellable);
	g_clear_object(&session->cancellable);
	session->cancellable = g_cancellable_new();
	for (index = 0; index < HOTDOG_IMS_EXECUTOR_MAX_LEGS; index++)
		g_clear_object(&session->clients[index]);
	result = hotdog_ims_executor_ssr(&session->executor, &operation);
	if (!result)
		dispatch(session, &operation);
	return result;
}

int hotdog_qmi_ims_session_clear(struct hotdog_qmi_ims_session *session)
{
	unsigned int index;

	if (!session)
		return -EINVAL;
	if (session->executor.phase != HOTDOG_IMS_EXECUTOR_IDLE &&
	    session->executor.phase != HOTDOG_IMS_EXECUTOR_FAILED)
		return -EBUSY;
	if (session->cancellable)
		g_cancellable_cancel(session->cancellable);
	for (index = 0; index < HOTDOG_IMS_EXECUTOR_MAX_LEGS; index++)
		g_clear_object(&session->clients[index]);
	hotdog_qmi_wds_plan_clear(&session->wds);
	g_clear_object(&session->config.device);
	g_clear_object(&session->cancellable);
	memset(session, 0, sizeof(*session));
	return 0;
}

const struct hotdog_bearer_runtime *hotdog_qmi_ims_session_runtime(
	const struct hotdog_qmi_ims_session *session)
{
	return session && session->initialized ? &session->runtime : NULL;
}
