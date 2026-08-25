/* SPDX-License-Identifier: GPL-2.0-only */
#include "hotdog-ims-bearer.h"
#include "hotdog-qmi-wds-profile.h"

#include <errno.h>
#include <gio/gio.h>
#include <libqmi-glib.h>
#include <libqrtr-glib.h>
#include <stdio.h>
#include <string.h>

#define PROFILE_TIMEOUT_SECONDS 10

struct profile_probe;

struct probe_subscription {
	struct profile_probe *probe;
	QmiClientWds *client;
	struct hotdog_wds_profile_ref refs[HOTDOG_IMS_MAX_PROFILES];
	struct hotdog_ims_profile profiles[HOTDOG_IMS_MAX_PROFILES];
	unsigned int index;
	size_t ref_count;
	size_t next_ref;
	size_t profile_count;
};

struct profile_probe {
	GMainLoop *loop;
	GCancellable *cancellable;
	QrtrBus *bus;
	QmiDevice *device;
	struct probe_subscription subscriptions[HOTDOG_NETWORK_MAX_SUBSCRIPTIONS];
	unsigned int node;
	unsigned int subscription_count;
	unsigned int next_subscription;
	gulong node_removed_handler;
	bool finished;
	int result;
};

struct release_wait {
	bool done;
};

static void finish(struct profile_probe *probe, int result)
{
	if (probe->finished)
		return;
	probe->finished = true;
	probe->result = result;
	if (probe->cancellable)
		g_cancellable_cancel(probe->cancellable);
	if (probe->loop)
		g_main_loop_quit(probe->loop);
}

#if QMI_CHECK_VERSION(1, 37, 0)
static void start_next_subscription(struct profile_probe *probe);

static void finish_subscription(struct probe_subscription *subscription)
{
	struct hotdog_ims_profile_selection selection;
	int result;

	result = hotdog_ims_profile_select(
		subscription->profiles, subscription->profile_count,
		subscription->index, HOTDOG_BEARER_IMS, NULL, &selection);
	if (!result) {
		printf("subscription=%u profiles=%zu usable=%zu ims-profile=%u "
		       "family=%s mask=0x%llx apn=%s\n",
		       subscription->index, subscription->ref_count,
		       subscription->profile_count, selection.index,
		       hotdog_ip_family_name(selection.family),
		       (unsigned long long)selection.apn_type_mask, selection.apn);
	} else {
		printf("subscription=%u profiles=%zu usable=%zu ims-profile=none "
		       "selection=%d\n",
		       subscription->index, subscription->ref_count,
		       subscription->profile_count, result);
	}
	subscription->probe->next_subscription = subscription->index + 1;
	start_next_subscription(subscription->probe);
}

static void start_next_profile(struct probe_subscription *subscription);

static void profile_settings_ready(QmiClientWds *client, GAsyncResult *res,
				   struct probe_subscription *subscription)
{
	g_autoptr(QmiMessageWdsGetProfileSettingsOutput) output = NULL;
	struct hotdog_ims_profile profile;
	unsigned int index = subscription->refs[subscription->next_ref].index;
	uint16_t remote = 0;
	GError *error = NULL;
	int result;

	output = qmi_client_wds_get_profile_settings_finish(client, res, &error);
	if (!output) {
		g_printerr("WDS profile settings request failed for subscription %u "
			   "profile %u: %s\n", subscription->index, index,
			   error ? error->message : "missing output");
		g_clear_error(&error);
		finish(subscription->probe, 1);
		return;
	}
	result = hotdog_qmi_wds_decode_profile_settings(
		output, subscription->index, index, &profile, &remote);
	if (!result) {
		if (subscription->profile_count == HOTDOG_IMS_MAX_PROFILES) {
			finish(subscription->probe, 1);
			return;
		}
		subscription->profiles[subscription->profile_count++] = profile;
	} else {
		printf("subscription=%u profile=%u unusable=%d remote=%u\n",
		       subscription->index, index, result, remote);
	}
	subscription->next_ref++;
	start_next_profile(subscription);
}

static void start_next_profile(struct probe_subscription *subscription)
{
	g_autoptr(QmiMessageWdsGetProfileSettingsInput) input = NULL;

	if (subscription->next_ref == subscription->ref_count) {
		finish_subscription(subscription);
		return;
	}
	if (hotdog_qmi_wds_profile_settings_input(
		    subscription->refs[subscription->next_ref].index, &input)) {
		finish(subscription->probe, 1);
		return;
	}
	qmi_client_wds_get_profile_settings(
		subscription->client, input, PROFILE_TIMEOUT_SECONDS,
		subscription->probe->cancellable,
		(GAsyncReadyCallback)profile_settings_ready, subscription);
}

static void profile_list_ready(QmiClientWds *client, GAsyncResult *res,
			       struct probe_subscription *subscription)
{
	g_autoptr(QmiMessageWdsGetProfileListOutput) output = NULL;
	uint16_t remote = 0;
	GError *error = NULL;
	int result;

	output = qmi_client_wds_get_profile_list_finish(client, res, &error);
	if (!output) {
		g_printerr("WDS profile list request failed for subscription %u: %s\n",
			   subscription->index,
			   error ? error->message : "missing output");
		g_clear_error(&error);
		finish(subscription->probe, 1);
		return;
	}
	result = hotdog_qmi_wds_decode_profile_list(
		output, subscription->refs, G_N_ELEMENTS(subscription->refs),
		&subscription->ref_count, &remote);
	if (result) {
		g_printerr("WDS profile list rejected for subscription %u: %d "
			   "remote=%u\n", subscription->index, result, remote);
		finish(subscription->probe, 1);
		return;
	}
	start_next_profile(subscription);
}

static void bind_ready(QmiClientWds *client, GAsyncResult *res,
		       struct probe_subscription *subscription)
{
	g_autoptr(QmiMessageWdsBindSubscriptionOutput) output = NULL;
	g_autoptr(QmiMessageWdsGetProfileListInput) input = NULL;
	uint16_t remote = 0;
	GError *error = NULL;
	int result;

	output = qmi_client_wds_bind_subscription_finish(client, res, &error);
	if (!output) {
		g_printerr("WDS subscription bind failed for subscription %u: %s\n",
			   subscription->index,
			   error ? error->message : "missing output");
		g_clear_error(&error);
		finish(subscription->probe, 1);
		return;
	}
	result = hotdog_qmi_wds_decode_bind_subscription(output, &remote);
	if (result || hotdog_qmi_wds_profile_list_input(&input)) {
		g_printerr("WDS subscription bind rejected for subscription %u: %d "
			   "remote=%u\n", subscription->index, result, remote);
		finish(subscription->probe, 1);
		return;
	}
	qmi_client_wds_get_profile_list(
		client, input, PROFILE_TIMEOUT_SECONDS, subscription->probe->cancellable,
		(GAsyncReadyCallback)profile_list_ready, subscription);
}

static void client_ready(QmiDevice *device, GAsyncResult *res,
			 struct probe_subscription *subscription)
{
	g_autoptr(QmiMessageWdsBindSubscriptionInput) input = NULL;
	QmiClient *client;
	GError *error = NULL;

	client = qmi_device_allocate_client_finish(device, res, &error);
	if (!client) {
		g_printerr("WDS client allocation failed for subscription %u: %s\n",
			   subscription->index,
			   error ? error->message : "missing client");
		g_clear_error(&error);
		finish(subscription->probe, 1);
		return;
	}
	subscription->client = QMI_CLIENT_WDS(client);
	if (hotdog_qmi_wds_bind_subscription_input(subscription->index, &input)) {
		finish(subscription->probe, 1);
		return;
	}
	qmi_client_wds_bind_subscription(
		subscription->client, input, PROFILE_TIMEOUT_SECONDS,
		subscription->probe->cancellable,
		(GAsyncReadyCallback)bind_ready, subscription);
}

static void start_next_subscription(struct profile_probe *probe)
{
	struct probe_subscription *subscription;

	if (probe->next_subscription == probe->subscription_count) {
		finish(probe, 0);
		return;
	}
	subscription = &probe->subscriptions[probe->next_subscription];
	qmi_device_allocate_client(
		probe->device, QMI_SERVICE_WDS, QMI_CID_NONE,
		PROFILE_TIMEOUT_SECONDS, probe->cancellable,
		(GAsyncReadyCallback)client_ready, subscription);
}
#endif

static void device_open_ready(QmiDevice *device, GAsyncResult *res,
			      struct profile_probe *probe)
{
	GError *error = NULL;

	if (!qmi_device_open_finish(device, res, &error)) {
		g_printerr("WDS QMI device open failed: %s\n",
			   error ? error->message : "unknown error");
		g_clear_error(&error);
		finish(probe, 1);
		return;
	}
#if QMI_CHECK_VERSION(1, 37, 0)
	start_next_subscription(probe);
#else
	g_printerr("subscription-scoped WDS profile probing requires libqmi 1.37\n");
	finish(probe, 2);
#endif
}

static void device_ready(GObject *source, GAsyncResult *res,
			 struct profile_probe *probe)
{
	GError *error = NULL;

	(void)source;
	probe->device = qmi_device_new_finish(res, &error);
	if (!probe->device) {
		g_printerr("WDS QMI device creation failed: %s\n",
			   error ? error->message : "unknown error");
		g_clear_error(&error);
		finish(probe, 1);
		return;
	}
	qmi_device_open(probe->device, QMI_DEVICE_OPEN_FLAGS_NONE,
			PROFILE_TIMEOUT_SECONDS, probe->cancellable,
			(GAsyncReadyCallback)device_open_ready, probe);
}

static void node_removed(QrtrBus *bus, guint node_id,
			 struct profile_probe *probe)
{
	(void)bus;
	if (node_id == probe->node) {
		g_printerr("WDS QRTR node removed\n");
		finish(probe, 1);
	}
}

static void bus_ready(GObject *source, GAsyncResult *res,
		      struct profile_probe *probe)
{
	QrtrNode *node;
	GError *error = NULL;

	(void)source;
	probe->bus = qrtr_bus_new_finish(res, &error);
	if (!probe->bus) {
		g_printerr("WDS QRTR bus failed: %s\n",
			   error ? error->message : "unknown error");
		g_clear_error(&error);
		finish(probe, 1);
		return;
	}
	probe->node_removed_handler = g_signal_connect(
		probe->bus, QRTR_BUS_SIGNAL_NODE_REMOVED,
		G_CALLBACK(node_removed), probe);
	node = qrtr_bus_peek_node(probe->bus, probe->node);
	if (!node) {
		g_printerr("WDS QRTR node %u unavailable\n", probe->node);
		finish(probe, 1);
		return;
	}
	qmi_device_new_from_node(node, probe->cancellable,
				 (GAsyncReadyCallback)device_ready, probe);
}

static void release_ready(QmiDevice *device, GAsyncResult *res,
			  struct release_wait *wait)
{
	GError *error = NULL;

	if (!qmi_device_release_client_finish(device, res, &error)) {
		g_printerr("WDS client release failed: %s\n",
			   error ? error->message : "unknown error");
		g_clear_error(&error);
	}
	wait->done = true;
}

static void release_client(struct profile_probe *probe, QmiClientWds *client)
{
	struct release_wait wait = { 0 };

	if (!probe->device || !client)
		return;
	qmi_device_release_client(
		probe->device, QMI_CLIENT(client),
		QMI_DEVICE_RELEASE_CLIENT_FLAGS_RELEASE_CID,
		PROFILE_TIMEOUT_SECONDS, NULL,
		(GAsyncReadyCallback)release_ready, &wait);
	while (!wait.done)
		g_main_context_iteration(NULL, TRUE);
}

int main(int argc, char **argv)
{
	struct profile_probe probe = { .node = 0, .subscription_count = 2 };
	GOptionContext *options;
	GError *error = NULL;
	GOptionEntry entries[] = {
		{ "node", 'n', 0, G_OPTION_ARG_INT, &probe.node,
		  "QRTR node", "ID" },
		{ "subscriptions", 's', 0, G_OPTION_ARG_INT,
		  &probe.subscription_count, "Subscriptions to inspect", "COUNT" },
		{ .long_name = NULL }
	};
	unsigned int index;
	int result;

	options = g_option_context_new("- read subscription-scoped WDS profiles");
	g_option_context_add_main_entries(options, entries, NULL);
	if (!g_option_context_parse(options, &argc, &argv, &error)) {
		g_printerr("option parsing failed: %s\n", error->message);
		g_clear_error(&error);
		g_option_context_free(options);
		return 2;
	}
	g_option_context_free(options);
	if (probe.node > UINT16_MAX || !probe.subscription_count ||
	    probe.subscription_count > HOTDOG_NETWORK_MAX_SUBSCRIPTIONS) {
		g_printerr("invalid WDS profile probe configuration\n");
		return 2;
	}
	for (index = 0; index < probe.subscription_count; index++) {
		probe.subscriptions[index].probe = &probe;
		probe.subscriptions[index].index = index;
	}
	probe.loop = g_main_loop_new(NULL, FALSE);
	probe.cancellable = g_cancellable_new();
	qrtr_bus_new(1000, probe.cancellable, (GAsyncReadyCallback)bus_ready, &probe);
	g_main_loop_run(probe.loop);
	result = probe.result;
	if (probe.bus && probe.node_removed_handler)
		g_signal_handler_disconnect(probe.bus, probe.node_removed_handler);
	for (index = 0; index < probe.subscription_count; index++) {
		release_client(&probe, probe.subscriptions[index].client);
		g_clear_object(&probe.subscriptions[index].client);
	}
	g_clear_object(&probe.device);
	g_clear_object(&probe.bus);
	g_clear_object(&probe.cancellable);
	g_main_loop_unref(probe.loop);
	return result;
}
