/* SPDX-License-Identifier: GPL-2.0-only */
#include "hotdog-qmi-wds-discovery.h"

#include <errno.h>
#include <string.h>

#define DISCOVERY_TIMEOUT_SECONDS 10

#if QMI_CHECK_VERSION(1, 37, 0)
struct discovery_request {
	struct hotdog_qmi_wds_discovery *discovery;
	unsigned int generation;
};

static struct discovery_request *request_new(
	struct hotdog_qmi_wds_discovery *discovery)
{
	struct discovery_request *request = g_new0(struct discovery_request, 1);

	request->discovery = discovery;
	request->generation = discovery->generation;
	return request;
}

static bool request_current(const struct discovery_request *request)
{
	return request->generation == request->discovery->generation;
}

static void complete(struct hotdog_qmi_wds_discovery *discovery);

static void released(QmiDevice *device, GAsyncResult *res,
		     struct discovery_request *request)
{
	struct hotdog_qmi_wds_discovery *discovery = request->discovery;
	GError *error = NULL;
	bool current = request_current(request);

	if (!qmi_device_release_client_finish(device, res, &error) && current) {
		discovery->result = -EUCLEAN;
		discovery->residue = true;
	}
	g_clear_error(&error);
	if (current && !discovery->residue)
		g_clear_object(&discovery->client);
	g_free(request);
	if (current)
		complete(discovery);
}

static void finish_result(struct hotdog_qmi_wds_discovery *discovery, int result)
{
	discovery->result = result;
	if (discovery->client) {
		qmi_device_release_client(
			discovery->device, QMI_CLIENT(discovery->client),
			QMI_DEVICE_RELEASE_CLIENT_FLAGS_RELEASE_CID,
			DISCOVERY_TIMEOUT_SECONDS, discovery->cancellable,
			(GAsyncReadyCallback)released, request_new(discovery));
		return;
	}
	complete(discovery);
}

static void complete(struct hotdog_qmi_wds_discovery *discovery)
{
	hotdog_qmi_wds_discovery_callback callback = discovery->callback;
	void *user_data = discovery->user_data;
	int result = discovery->result;

	discovery->active = false;
	if (!discovery->residue) {
		g_clear_object(&discovery->device);
		g_clear_object(&discovery->cancellable);
	}
	if (callback)
		callback(discovery, result, user_data);
}

static void start_next_profile(struct hotdog_qmi_wds_discovery *discovery);

static void settings_ready(QmiClientWds *client, GAsyncResult *res,
			   struct discovery_request *request)
{
	struct hotdog_qmi_wds_discovery *discovery = request->discovery;
	g_autoptr(QmiMessageWdsGetProfileSettingsOutput) output = NULL;
	struct hotdog_ims_profile profile;
	unsigned int index = discovery->refs[discovery->next_ref].index;
	GError *error = NULL;
	int result;

	output = qmi_client_wds_get_profile_settings_finish(client, res, &error);
	if (!request_current(request)) {
		g_clear_error(&error);
		g_free(request);
		return;
	}
	g_free(request);
	if (!output) {
		g_clear_error(&error);
		finish_result(discovery, -EIO);
		return;
	}
	result = hotdog_qmi_wds_decode_profile_settings(
		output, discovery->subscription, index, &profile,
		&discovery->remote_result);
	if (!result)
		discovery->profiles[discovery->profile_count++] = profile;
	else if (result != -ENODATA && result != -EPROTO) {
		finish_result(discovery, result);
		return;
	}
	discovery->next_ref++;
	start_next_profile(discovery);
}

static void start_next_profile(struct hotdog_qmi_wds_discovery *discovery)
{
	g_autoptr(QmiMessageWdsGetProfileSettingsInput) input = NULL;
	int result;

	if (discovery->next_ref == discovery->ref_count) {
		if (!discovery->profile_count)
			result = -ENOENT;
		else
			result = hotdog_ims_profile_select(
				discovery->profiles, discovery->profile_count,
				discovery->subscription, HOTDOG_BEARER_IMS, NULL,
				&discovery->selection);
		finish_result(discovery, result);
		return;
	}
	if (hotdog_qmi_wds_profile_settings_input(
		    discovery->refs[discovery->next_ref].index, &input)) {
		finish_result(discovery, -EINVAL);
		return;
	}
	qmi_client_wds_get_profile_settings(
		discovery->client, input, DISCOVERY_TIMEOUT_SECONDS,
		discovery->cancellable, (GAsyncReadyCallback)settings_ready,
		request_new(discovery));
}

static void list_ready(QmiClientWds *client, GAsyncResult *res,
		       struct discovery_request *request)
{
	struct hotdog_qmi_wds_discovery *discovery = request->discovery;
	g_autoptr(QmiMessageWdsGetProfileListOutput) output = NULL;
	GError *error = NULL;
	int result;

	output = qmi_client_wds_get_profile_list_finish(client, res, &error);
	if (!request_current(request)) {
		g_clear_error(&error);
		g_free(request);
		return;
	}
	g_free(request);
	if (!output) {
		g_clear_error(&error);
		finish_result(discovery, -EIO);
		return;
	}
	result = hotdog_qmi_wds_decode_profile_list(
		output, discovery->refs, G_N_ELEMENTS(discovery->refs),
		&discovery->ref_count, &discovery->remote_result);
	if (result) {
		finish_result(discovery, result);
		return;
	}
	start_next_profile(discovery);
}

static void bound(QmiClientWds *client, GAsyncResult *res,
		  struct discovery_request *request)
{
	struct hotdog_qmi_wds_discovery *discovery = request->discovery;
	g_autoptr(QmiMessageWdsBindSubscriptionOutput) output = NULL;
	g_autoptr(QmiMessageWdsGetProfileListInput) input = NULL;
	GError *error = NULL;
	int result;

	output = qmi_client_wds_bind_subscription_finish(client, res, &error);
	if (!request_current(request)) {
		g_clear_error(&error);
		g_free(request);
		return;
	}
	g_free(request);
	if (!output) {
		g_clear_error(&error);
		finish_result(discovery, -EIO);
		return;
	}
	result = hotdog_qmi_wds_decode_bind_subscription(
		output, &discovery->remote_result);
	if (!result)
		result = hotdog_qmi_wds_profile_list_input(&input);
	if (result) {
		finish_result(discovery, result);
		return;
	}
	qmi_client_wds_get_profile_list(
		client, input, DISCOVERY_TIMEOUT_SECONDS, discovery->cancellable,
		(GAsyncReadyCallback)list_ready, request_new(discovery));
}

static void allocated(QmiDevice *device, GAsyncResult *res,
		      struct discovery_request *request)
{
	struct hotdog_qmi_wds_discovery *discovery = request->discovery;
	g_autoptr(QmiMessageWdsBindSubscriptionInput) input = NULL;
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
	g_free(request);
	if (!client) {
		g_clear_error(&error);
		finish_result(discovery, -EIO);
		return;
	}
	discovery->client = QMI_CLIENT_WDS(client);
	result = hotdog_qmi_wds_bind_subscription_input(
		discovery->subscription, &input);
	if (result) {
		finish_result(discovery, result);
		return;
	}
	qmi_client_wds_bind_subscription(
		discovery->client, input, DISCOVERY_TIMEOUT_SECONDS,
		discovery->cancellable, (GAsyncReadyCallback)bound,
		request_new(discovery));
}
#endif

void hotdog_qmi_wds_discovery_init(struct hotdog_qmi_wds_discovery *discovery)
{
	if (!discovery)
		return;
	memset(discovery, 0, sizeof(*discovery));
	discovery->initialized = true;
}

int hotdog_qmi_wds_discovery_start(
	struct hotdog_qmi_wds_discovery *discovery, QmiDevice *device,
	unsigned int subscription, hotdog_qmi_wds_discovery_callback callback,
	void *user_data)
{
	if (!discovery || !discovery->initialized || !device || !callback ||
	    subscription >= HOTDOG_NETWORK_MAX_SUBSCRIPTIONS)
		return -EINVAL;
	if (discovery->active || discovery->residue || discovery->client)
		return -EBUSY;
#if !QMI_CHECK_VERSION(1, 37, 0)
	(void)user_data;
	return -EOPNOTSUPP;
#else
	memset(discovery->refs, 0, sizeof(discovery->refs));
	memset(discovery->profiles, 0, sizeof(discovery->profiles));
	memset(&discovery->selection, 0, sizeof(discovery->selection));
	discovery->device = g_object_ref(device);
	discovery->cancellable = g_cancellable_new();
	discovery->callback = callback;
	discovery->user_data = user_data;
	discovery->subscription = subscription;
	discovery->remote_result = 0;
	discovery->ref_count = 0;
	discovery->next_ref = 0;
	discovery->profile_count = 0;
	discovery->result = 0;
	discovery->active = true;
	discovery->residue = false;
	discovery->generation++;
	qmi_device_allocate_client(
		discovery->device, QMI_SERVICE_WDS, QMI_CID_NONE,
		DISCOVERY_TIMEOUT_SECONDS, discovery->cancellable,
		(GAsyncReadyCallback)allocated, request_new(discovery));
	return 0;
#endif
}

int hotdog_qmi_wds_discovery_abort_ssr(
	struct hotdog_qmi_wds_discovery *discovery)
{
	hotdog_qmi_wds_discovery_callback callback;
	void *user_data;

	if (!discovery || !discovery->initialized ||
	    (!discovery->active && !discovery->residue))
		return -EINVAL;
	if (!discovery->active) {
		discovery->generation++;
		g_clear_object(&discovery->client);
		g_clear_object(&discovery->device);
		g_clear_object(&discovery->cancellable);
		discovery->residue = false;
		return 0;
	}
	discovery->generation++;
	if (discovery->cancellable)
		g_cancellable_cancel(discovery->cancellable);
	g_clear_object(&discovery->client);
	g_clear_object(&discovery->device);
	g_clear_object(&discovery->cancellable);
	discovery->active = false;
	discovery->residue = false;
	discovery->result = -ENETRESET;
	callback = discovery->callback;
	user_data = discovery->user_data;
	if (callback)
		callback(discovery, discovery->result, user_data);
	return 0;
}

int hotdog_qmi_wds_discovery_clear(
	struct hotdog_qmi_wds_discovery *discovery)
{
	if (!discovery)
		return -EINVAL;
	if (discovery->active || discovery->residue || discovery->client)
		return -EBUSY;
	g_clear_object(&discovery->client);
	g_clear_object(&discovery->device);
	g_clear_object(&discovery->cancellable);
	memset(discovery, 0, sizeof(*discovery));
	return 0;
}
