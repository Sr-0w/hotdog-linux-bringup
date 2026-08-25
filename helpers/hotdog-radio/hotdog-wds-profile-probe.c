/* SPDX-License-Identifier: GPL-2.0-only */
#include "hotdog-qmi-wds-discovery.h"

#include <errno.h>
#include <gio/gio.h>
#include <libqmi-glib.h>
#include <libqrtr-glib.h>
#include <stdio.h>

#define PROBE_TIMEOUT_SECONDS 10

struct profile_probe {
	GMainLoop *loop;
	GCancellable *cancellable;
	QrtrBus *bus;
	QmiDevice *device;
	struct hotdog_qmi_wds_discovery
		discoveries[HOTDOG_NETWORK_MAX_SUBSCRIPTIONS];
	unsigned int node;
	unsigned int subscription_count;
	unsigned int next_subscription;
	gulong node_removed_handler;
	bool finished;
	int result;
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

static void start_next_subscription(struct profile_probe *probe);

static void discovery_done(struct hotdog_qmi_wds_discovery *discovery,
			   int result, void *user_data)
{
	struct profile_probe *probe = user_data;
	size_t index;

	if (probe->finished)
		return;
	for (index = 0; index < discovery->profile_count; index++) {
		const struct hotdog_ims_profile *profile = &discovery->profiles[index];

		printf("subscription=%u profile=%u usable=1 family=%u mask=0x%llx "
		       "pcscf-pco=%u apn=%s\n",
		       discovery->subscription, profile->index, profile->pdp_type,
		       (unsigned long long)profile->apn_type_mask,
		       profile->pcscf_via_pco, profile->apn);
	}
	if (!result) {
		printf("subscription=%u profiles=%zu usable=%zu ims-profile=%u "
		       "family=%s mask=0x%llx apn=%s\n",
		       discovery->subscription, discovery->ref_count,
		       discovery->profile_count, discovery->selection.index,
		       hotdog_ip_family_name(discovery->selection.family),
		       (unsigned long long)discovery->selection.apn_type_mask,
		       discovery->selection.apn);
	} else if (result == -ENOENT || result == -ENOTUNIQ ||
		   result == -EAFNOSUPPORT) {
		printf("subscription=%u profiles=%zu usable=%zu ims-profile=none "
		       "selection=%d\n", discovery->subscription,
		       discovery->ref_count, discovery->profile_count, result);
	} else {
		g_printerr("subscription %u WDS discovery failed: %d remote=%u "
			   "residue=%u\n", discovery->subscription, result,
			   discovery->remote_result, discovery->residue);
		finish(probe, 1);
		return;
	}
	probe->next_subscription = discovery->subscription + 1;
	start_next_subscription(probe);
}

static void start_next_subscription(struct profile_probe *probe)
{
	int result;

	if (probe->next_subscription == probe->subscription_count) {
		finish(probe, 0);
		return;
	}
	result = hotdog_qmi_wds_discovery_start(
		&probe->discoveries[probe->next_subscription], probe->device,
		probe->next_subscription, discovery_done, probe);
	if (result) {
		g_printerr("subscription %u WDS discovery start failed: %d\n",
			   probe->next_subscription, result);
		finish(probe, 1);
	}
}

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
	start_next_subscription(probe);
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
			PROBE_TIMEOUT_SECONDS, probe->cancellable,
			(GAsyncReadyCallback)device_open_ready, probe);
}

static void node_removed(QrtrBus *bus, guint node_id,
			 struct profile_probe *probe)
{
	unsigned int index;

	(void)bus;
	if (node_id != probe->node)
		return;
	for (index = 0; index < probe->subscription_count; index++)
		if (probe->discoveries[index].active)
			hotdog_qmi_wds_discovery_abort_ssr(&probe->discoveries[index]);
	g_printerr("WDS QRTR node removed\n");
	finish(probe, 1);
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
	for (index = 0; index < probe.subscription_count; index++)
		hotdog_qmi_wds_discovery_init(&probe.discoveries[index]);
	probe.loop = g_main_loop_new(NULL, FALSE);
	probe.cancellable = g_cancellable_new();
	qrtr_bus_new(1000, probe.cancellable, (GAsyncReadyCallback)bus_ready, &probe);
	g_main_loop_run(probe.loop);
	result = probe.result;
	if (probe.bus && probe.node_removed_handler)
		g_signal_handler_disconnect(probe.bus, probe.node_removed_handler);
	for (index = 0; index < probe.subscription_count; index++) {
		if (probe.discoveries[index].active || probe.discoveries[index].residue)
			hotdog_qmi_wds_discovery_abort_ssr(&probe.discoveries[index]);
		hotdog_qmi_wds_discovery_clear(&probe.discoveries[index]);
	}
	g_clear_object(&probe.device);
	g_clear_object(&probe.bus);
	g_clear_object(&probe.cancellable);
	g_main_loop_unref(probe.loop);
	return result;
}
