/* SPDX-License-Identifier: GPL-2.0-only */
#define _POSIX_C_SOURCE 200809L
#include "hotdog-ims-bearer-state.h"
#include "hotdog-ims-state.h"
#include "hotdog-mcfg-runtime.h"
#include "hotdog-qmi-imsa.h"
#include "hotdog-qmi-ims-session.h"
#include "hotdog-qmi-wds-discovery.h"
#include "hotdog-radio-readiness.h"

#include <errno.h>
#include <gio/gio.h>
#include <glib-unix.h>
#include <libqmi-glib.h>
#include <libqrtr-glib.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#define DEFAULT_READINESS_PATH "/run/hotdog-radio/readiness"
#define DEFAULT_IMS_STATE_PATH "/run/hotdog-radio/ims-state"
#define DEFAULT_IMS_BEARER_PATH "/run/hotdog-radio/ims-bearer"
#define DEFAULT_BOOT_ID_PATH "/proc/sys/kernel/random/boot_id"
#define DEFAULT_RUNTIME_MANIFEST "/usr/share/hotdog-radio/mcfg/MANIFEST"
#define DEFAULT_IP_PATH "/usr/sbin/ip"

/* The OxygenOS 10 msmnile data configuration fixes the kernel-facing side
 * of the IMS path: the physical device is rmnet_ipa0 behind the IPA driver,
 * with MAPv4 aggregation. Only the mux is dynamic, and rmnet allocates it. */
#define RMNET_DRIVER "ipa"
#define RMNET_BASE_IFNAME "rmnet_ipa0"
#define RMNET_LINK_PREFIX "ims"
#define RMNET_OFFLOAD "MAPv4"

/* IFF_UP. <net/if.h> hides the flag behind feature-test macros this file
 * deliberately keeps narrow, and the value is kernel ABI. */
#define NET_FLAG_UP 0x1u

/* The IMSA side counts subscriptions with the telephony bound and the bearer
 * side with the network one. They are indexed by the same subscription here,
 * so a divergence would walk off the end of the bearer array. */
_Static_assert(HOTDOG_TELEPHONY_MAX_SUBSCRIPTIONS ==
	       HOTDOG_NETWORK_MAX_SUBSCRIPTIONS,
	       "IMSA and bearer subscription bounds must agree");

struct imsd;

struct imsd_subscription {
	struct imsd *imsd;
	unsigned int index;
	QmiClientImsa *client;
	struct hotdog_qmi_wds_discovery discovery;
	struct hotdog_qmi_ims_session session;
	struct hotdog_ims_netconfig_plan netconfig;
	gulong registration_handler;
	gulong services_handler;
	bool registration_indicated;
	bool services_indicated;
	bool base_was_up;
};

struct imsd {
	GMainLoop *loop;
	GCancellable *cancellable;
	QrtrBus *bus;
	QmiDevice *device;
	struct hotdog_radio_readiness readiness;
	struct hotdog_ims_runtime_state state;
	struct hotdog_ims_bearer_runtime_state bearer;
	struct imsd_subscription subscriptions[HOTDOG_TELEPHONY_MAX_SUBSCRIPTIONS];
	char *readiness_path;
	char *state_path;
	char *bearer_path;
	char *boot_id_path;
	char *runtime_manifest;
	char *ip_path;
	unsigned int node;
	unsigned int next_subscription;
	unsigned int next_discovery;
	unsigned int next_session;
	unsigned int generation;
	gulong node_removed_handler;
	guint readiness_poll_id;
	bool initialized;
	bool finished;
	int result;
};

struct release_wait {
	bool done;
};

static void finish(struct imsd *imsd, int result)
{
	if (imsd->finished)
		return;
	imsd->finished = true;
	imsd->result = result;
	if (imsd->cancellable)
		g_cancellable_cancel(imsd->cancellable);
	if (unlink(imsd->state_path) && errno != ENOENT)
		g_printerr("IMS state removal failed: %s\n", g_strerror(errno));
	if (unlink(imsd->bearer_path) && errno != ENOENT)
		g_printerr("IMS bearer removal failed: %s\n", g_strerror(errno));
	g_main_loop_quit(imsd->loop);
}

static int read_boot_id(const char *path, char *boot_id, size_t size)
{
	FILE *stream;
	size_t length;

	stream = fopen(path, "r");
	if (!stream)
		return -errno;
	if (!fgets(boot_id, size, stream)) {
		fclose(stream);
		return -EIO;
	}
	if (fclose(stream))
		return -EIO;
	length = strcspn(boot_id, "\r\n");
	if (boot_id[length] == '\0' && length == size - 1)
		return -EOVERFLOW;
	boot_id[length] = '\0';
	return boot_id[0] ? 0 : -ENODATA;
}

static int verify_readiness(struct imsd *imsd)
{
	struct hotdog_radio_readiness readiness;
	struct hotdog_mcfg_runtime runtime;
	char boot_id[HOTDOG_READINESS_BOOT_ID_SIZE + 2];
	int result;

	result = hotdog_radio_readiness_read(imsd->readiness_path, &readiness);
	if (result)
		return result;
	result = read_boot_id(imsd->boot_id_path, boot_id, sizeof(boot_id));
	if (result)
		return result;
	if (strcmp(readiness.boot_id, boot_id))
		return -ESTALE;
	result = hotdog_mcfg_runtime_read(imsd->runtime_manifest, &runtime);
	if (result)
		return result;
	if (strcmp(readiness.modem_sha256, runtime.modem_sha256) ||
	    strcmp(readiness.mcfg_sha256, runtime.archive_sha256))
		return -ESTALE;
	if (imsd->readiness.boot_id[0]) {
		size_t index;

		for (index = 0; index < HOTDOG_TELEPHONY_MAX_SUBSCRIPTIONS; index++) {
			const struct hotdog_readiness_subscription *old =
				&imsd->readiness.subscriptions[index];
			const struct hotdog_readiness_subscription *current =
				&readiness.subscriptions[index];

			if (old->populated != current->populated ||
			    old->physical_slot != current->physical_slot ||
			    memcmp(&old->selected, &current->selected, sizeof(old->selected)) ||
			    memcmp(&old->active, &current->active, sizeof(old->active)) ||
			    memcmp(&old->pending, &current->pending, sizeof(old->pending)))
				return -ESTALE;
		}
	}
	imsd->readiness = readiness;
	return 0;
}

static int publish_state(struct imsd *imsd)
{
	int result = hotdog_ims_runtime_write(imsd->state_path, &imsd->state);

	if (result)
		g_printerr("IMS state publication failed: %d\n", result);
	else
		printf("ims-state=published generation=%u\n", imsd->state.generation);
	return result;
}

static int publish_bearer(struct imsd *imsd)
{
	int result = hotdog_ims_bearer_runtime_write(imsd->bearer_path, &imsd->bearer);

	if (result)
		g_printerr("IMS bearer publication failed: %d\n", result);
	else
		printf("ims-bearer=published generation=%u\n", imsd->bearer.generation);
	return result;
}

static void start_next_discovery(struct imsd *imsd);
static void start_next_session(struct imsd *imsd);

static void bearer_failed(struct imsd *imsd, unsigned int index, int result)
{
	struct hotdog_ims_bearer_subscription_state *bearer =
		&imsd->bearer.subscriptions[index];

	bearer->status = HOTDOG_IMS_BEARER_FAILED;
	bearer->error = result < 0 ? (unsigned int)-result : EPROTO;
	bearer->mux_id = 0;
	bearer->route_table = 0;
	bearer->fwmark = 0;
	bearer->ifname[0] = '\0';
	bearer->pcscf_address_count = 0;
	bearer->pcscf_domain_count = 0;
	bearer->residue = false;
	bearer->residue_mask = 0;
}

static void discovery_done(struct hotdog_qmi_wds_discovery *discovery,
			   int result, void *user_data)
{
	struct imsd_subscription *subscription = user_data;
	struct imsd *imsd = subscription->imsd;
	struct hotdog_ims_bearer_subscription_state *bearer =
		&imsd->bearer.subscriptions[subscription->index];

	/* An SSR abort completes every outstanding discovery synchronously,
	 * so this runs again on the way out of a teardown already decided. */
	if (imsd->finished)
		return;
	if (!result && discovery->selection.index) {
		bearer->status = HOTDOG_IMS_BEARER_STARTING;
		bearer->profile_selected = true;
		bearer->profile = discovery->selection.index;
		bearer->family = discovery->selection.family;
		printf("ims-profile subscription=%u profile=%u family=%s apn=%s\n",
		       subscription->index, discovery->selection.index,
		       hotdog_ip_family_name(discovery->selection.family),
		       discovery->selection.apn);
	} else if (!result || result == -ENOENT || result == -ENOTUNIQ ||
		   result == -EAFNOSUPPORT) {
		/* Profile 0 is not a 3GPP profile identifier, so a selection
		 * naming it describes no bearer an executor could start. */
		bearer->status = HOTDOG_IMS_BEARER_UNAVAILABLE;
		bearer->error = result ? (unsigned int)-result : EPROTO;
		printf("ims-profile subscription=%u profile=none reason=%u\n",
		       subscription->index, bearer->error);
	} else {
		bearer->error = result < 0 ? (unsigned int)-result : EPROTO;
		if (discovery->residue) {
			bearer->status = HOTDOG_IMS_BEARER_BLOCKED;
			bearer->residue = true;
			bearer->residue_mask = HOTDOG_IMS_RESIDUE_CLIENT;
		} else {
			bearer->status = HOTDOG_IMS_BEARER_FAILED;
		}
		g_printerr("subscription %u WDS discovery failed: %d remote=%u "
			   "residue=%u\n", subscription->index, result,
			   discovery->remote_result, discovery->residue);
		publish_bearer(imsd);
		finish(imsd, 1);
		return;
	}
	if (publish_bearer(imsd)) {
		finish(imsd, 1);
		return;
	}
	imsd->next_discovery = subscription->index + 1;
	start_next_discovery(imsd);
}

static void start_next_discovery(struct imsd *imsd)
{
	struct imsd_subscription *subscription;
	int result;

	while (imsd->next_discovery < HOTDOG_TELEPHONY_MAX_SUBSCRIPTIONS &&
	       !imsd->bearer.subscriptions[imsd->next_discovery].populated)
		imsd->next_discovery++;
	if (imsd->next_discovery == HOTDOG_TELEPHONY_MAX_SUBSCRIPTIONS) {
		start_next_session(imsd);
		return;
	}
	subscription = &imsd->subscriptions[imsd->next_discovery];
	result = hotdog_qmi_wds_discovery_start(
		&subscription->discovery, imsd->device, subscription->index,
		discovery_done, subscription);
	if (!result)
		return;
	/* A build without the subscription-scoped profile API can select no IMS
	 * bearer at all. Record that in the state before leaving, rather than
	 * exiting with the reason only in the log. */
	imsd->bearer.subscriptions[subscription->index].status =
		HOTDOG_IMS_BEARER_UNAVAILABLE;
	imsd->bearer.subscriptions[subscription->index].error =
		result < 0 ? (unsigned int)-result : EPROTO;
	g_printerr("subscription %u WDS discovery start failed: %d\n",
		   subscription->index, result);
	publish_bearer(imsd);
	finish(imsd, 1);
}

/* Whether the base rmnet device was already up when the bearer claimed it. The
 * netconfig plan needs this so its rollback never takes down a link this daemon
 * did not raise. */
static bool base_link_is_up(const char *ifname)
{
	char path[64];
	unsigned long flags;
	FILE *stream;
	int items;

	if (snprintf(path, sizeof(path), "/sys/class/net/%s/flags", ifname) >=
	    (int)sizeof(path))
		return false;
	stream = fopen(path, "r");
	if (!stream)
		return false;
	items = fscanf(stream, "%lx", &flags);
	fclose(stream);
	return items == 1 && (flags & NET_FLAG_UP);
}

static uint32_t bearer_residue_mask(const struct imsd_subscription *subscription)
{
	const struct hotdog_ims_executor *executor = &subscription->session.executor;
	uint32_t mask = 0;
	size_t leg;

	if (subscription->netconfig.residue)
		mask |= HOTDOG_IMS_RESIDUE_CONFIG;
	for (leg = 0; leg < HOTDOG_IMS_EXECUTOR_MAX_LEGS; leg++)
		if (executor->packet_handles[leg])
			mask |= HOTDOG_IMS_RESIDUE_PACKET;
	if (executor->clients_owned)
		mask |= HOTDOG_IMS_RESIDUE_CLIENT;
	if (executor->link_owned)
		mask |= HOTDOG_IMS_RESIDUE_LINK;
	return mask;
}

static void bearer_clear_link(struct hotdog_ims_bearer_subscription_state *bearer)
{
	bearer->mux_id = 0;
	bearer->route_table = 0;
	bearer->fwmark = 0;
	bearer->ifname[0] = '\0';
	bearer->pcscf_address_count = 0;
	bearer->pcscf_domain_count = 0;
}

static void bearer_set_ifname(
	struct hotdog_ims_bearer_subscription_state *bearer, const char *ifname)
{
	memcpy(bearer->ifname, ifname, sizeof(bearer->ifname));
	bearer->ifname[sizeof(bearer->ifname) - 1] = '\0';
}

static void configure_required(struct imsd_subscription *subscription)
{
	struct imsd *imsd = subscription->imsd;
	struct hotdog_qmi_ims_session *session = &subscription->session;
	const struct hotdog_bearer_runtime *runtime =
		hotdog_qmi_ims_session_runtime(session);
	int result;

	subscription->base_was_up = base_link_is_up(RMNET_BASE_IFNAME);
	result = runtime ? hotdog_ims_netconfig_plan_build(
				   imsd->ip_path, RMNET_BASE_IFNAME,
				   subscription->base_was_up, session->executor.ifname,
				   subscription->index,
				   subscription->discovery.selection.family, runtime,
				   &subscription->netconfig)
			 : -EINVAL;
	if (!result)
		result = hotdog_ims_netconfig_apply(
			&subscription->netconfig, hotdog_ims_netconfig_spawn, NULL);
	if (result) {
		g_printerr("subscription %u IMS link configuration failed: %d "
			   "residue=%u\n", subscription->index, result,
			   subscription->netconfig.residue);
		/* A failed apply has already rolled its own steps back; the
		 * session unwinds its QMI ownership from here. */
		hotdog_qmi_ims_session_configuration_failed(
			session, result < 0 ? (unsigned int)-result : EPROTO);
		return;
	}
	printf("ims-link subscription=%u ifname=%s mux=%u table=%u steps=%zu\n",
	       subscription->index, session->executor.ifname,
	       session->executor.mux_id, subscription->netconfig.table,
	       subscription->netconfig.count);
	hotdog_qmi_ims_session_configured(session);
}

static void session_event(struct hotdog_qmi_ims_session *session,
			  enum hotdog_qmi_ims_session_event event,
			  unsigned int error, void *user_data)
{
	struct imsd_subscription *subscription = user_data;
	struct imsd *imsd = subscription->imsd;
	struct hotdog_ims_bearer_subscription_state *bearer =
		&imsd->bearer.subscriptions[subscription->index];
	const struct hotdog_bearer_runtime *runtime;
	uint32_t mask;

	/* An SSR unwind reports through this callback too, after the teardown
	 * has already been decided. */
	if (imsd->finished)
		return;
	switch (event) {
	case HOTDOG_QMI_IMS_SESSION_CONFIGURE_REQUIRED:
		configure_required(subscription);
		return;
	case HOTDOG_QMI_IMS_SESSION_UNCONFIGURE_REQUIRED:
		if (hotdog_ims_netconfig_rollback(&subscription->netconfig,
						  hotdog_ims_netconfig_spawn, NULL))
			g_printerr("subscription %u IMS link rollback failed: "
				   "residue=%u\n", subscription->index,
				   subscription->netconfig.residue);
		hotdog_qmi_ims_session_unconfigured(session);
		return;
	case HOTDOG_QMI_IMS_SESSION_UP:
		runtime = hotdog_qmi_ims_session_runtime(session);
		bearer->status = HOTDOG_IMS_BEARER_UP;
		bearer->error = 0;
		bearer->mux_id = session->executor.mux_id;
		bearer->route_table = subscription->netconfig.table;
		bearer->fwmark = subscription->netconfig.fwmark;
		bearer_set_ifname(bearer, session->executor.ifname);
		bearer->pcscf_address_count = runtime ? runtime->pcscf_address_count : 0;
		bearer->pcscf_domain_count = runtime ? runtime->pcscf_domain_count : 0;
		printf("ims-bearer subscription=%u up ifname=%s mux=%u pcscf=%zu/%zu\n",
		       subscription->index, bearer->ifname, bearer->mux_id,
		       bearer->pcscf_address_count, bearer->pcscf_domain_count);
		break;
	case HOTDOG_QMI_IMS_SESSION_DOWN:
		bearer_clear_link(bearer);
		if (error) {
			bearer->status = HOTDOG_IMS_BEARER_FAILED;
			bearer->error = error;
		} else {
			/* Nothing is established and nothing failed, so the
			 * subscription is back to what its selected profile
			 * alone describes. */
			bearer->status = HOTDOG_IMS_BEARER_STARTING;
			bearer->error = 0;
		}
		printf("ims-bearer subscription=%u down reason=%u\n",
		       subscription->index, error);
		break;
	case HOTDOG_QMI_IMS_SESSION_BLOCKED:
		mask = bearer_residue_mask(subscription);
		if (!mask) {
			/* Blocked with nothing actually left behind is a plain
			 * failure; claiming residue would send the supervisor
			 * after something that does not exist. */
			bearer_failed(imsd, subscription->index,
				      -(int)(error ? error : EPROTO));
		} else {
			bearer->status = HOTDOG_IMS_BEARER_BLOCKED;
			bearer->error = error ? error : EPROTO;
			bearer->residue = true;
			bearer->residue_mask = mask;
			if (mask & HOTDOG_IMS_RESIDUE_LINK) {
				bearer->mux_id = session->executor.mux_id;
				bearer_set_ifname(bearer, session->executor.ifname);
			} else {
				bearer->mux_id = 0;
				bearer->ifname[0] = '\0';
			}
		}
		g_printerr("subscription %u IMS bearer blocked: error=%u residue=0x%x\n",
			   subscription->index, error, mask);
		publish_bearer(imsd);
		finish(imsd, 1);
		return;
	}
	if (publish_bearer(imsd)) {
		finish(imsd, 1);
		return;
	}
	imsd->next_session = subscription->index + 1;
	start_next_session(imsd);
}

static void start_next_session(struct imsd *imsd)
{
	struct hotdog_qmi_ims_session_config config;
	struct imsd_subscription *subscription;
	int result;

	while (imsd->next_session < HOTDOG_TELEPHONY_MAX_SUBSCRIPTIONS &&
	       imsd->bearer.subscriptions[imsd->next_session].status !=
		       HOTDOG_IMS_BEARER_STARTING)
		imsd->next_session++;
	if (imsd->next_session == HOTDOG_TELEPHONY_MAX_SUBSCRIPTIONS)
		return;
	subscription = &imsd->subscriptions[imsd->next_session];
	memset(&config, 0, sizeof(config));
	result = hotdog_qmi_rmnet_plan_build(
		RMNET_DRIVER, 0, RMNET_BASE_IFNAME, RMNET_LINK_PREFIX,
		RMNET_OFFLOAD, RMNET_OFFLOAD, &config.rmnet);
	if (!result) {
		config.device = imsd->device;
		config.profile = subscription->discovery.selection;
		result = hotdog_qmi_ims_session_start(
			&subscription->session, &config, session_event, subscription);
	}
	if (!result)
		return;
	g_printerr("subscription %u IMS bearer start failed: %d\n",
		   subscription->index, result);
	bearer_failed(imsd, subscription->index, result);
	publish_bearer(imsd);
	finish(imsd, 1);
}

static void registration_indication(
	QmiClientImsa *client,
	QmiIndicationImsaImsRegistrationStatusChangedOutput *output,
	struct imsd_subscription *subscription)
{
	struct hotdog_ims_state *state =
		&subscription->imsd->state.subscriptions[subscription->index].ims;
	int result;

	(void)client;
	subscription->registration_indicated = true;
	result = hotdog_qmi_imsa_decode_registration_indication(output, state);
	if (result || (subscription->imsd->initialized && publish_state(subscription->imsd))) {
		g_printerr("IMSA registration indication rejected for subscription %u: %d\n",
			   subscription->index, result);
		finish(subscription->imsd, 1);
	}
}

static void services_indication(
	QmiClientImsa *client,
	QmiIndicationImsaImsServicesStatusChangedOutput *output,
	struct imsd_subscription *subscription)
{
	struct hotdog_ims_state *state =
		&subscription->imsd->state.subscriptions[subscription->index].ims;
	int result;

	(void)client;
	subscription->services_indicated = true;
	result = hotdog_qmi_imsa_decode_services_indication(output, state);
	if (result || (subscription->imsd->initialized && publish_state(subscription->imsd))) {
		g_printerr("IMSA services indication rejected for subscription %u: %d\n",
			   subscription->index, result);
		finish(subscription->imsd, 1);
	}
}

static void start_next_subscription(struct imsd *imsd);

static void services_ready(QmiClientImsa *client, GAsyncResult *res,
			   struct imsd_subscription *subscription)
{
	g_autoptr(QmiMessageImsaGetImsServicesStatusOutput) output = NULL;
	uint16_t remote = 0;
	GError *error = NULL;
	int result;

	output = qmi_client_imsa_get_ims_services_status_finish(client, res, &error);
	if (!output) {
		g_printerr("IMSA services request failed for subscription %u: %s\n",
			   subscription->index, error->message);
		g_clear_error(&error);
		finish(subscription->imsd, 1);
		return;
	}
	result = subscription->services_indicated ? 0 : hotdog_qmi_imsa_decode_services(
		output, &subscription->imsd->state.subscriptions[subscription->index].ims,
		&remote);
	if (result) {
		g_printerr("IMSA services rejected for subscription %u: %d remote=%u\n",
			   subscription->index, result, remote);
		finish(subscription->imsd, 1);
		return;
	}
	subscription->imsd->next_subscription = subscription->index + 1;
	start_next_subscription(subscription->imsd);
}

static void registration_ready(QmiClientImsa *client, GAsyncResult *res,
			       struct imsd_subscription *subscription)
{
	g_autoptr(QmiMessageImsaGetImsRegistrationStatusOutput) output = NULL;
	uint16_t remote = 0;
	GError *error = NULL;
	int result;

	output = qmi_client_imsa_get_ims_registration_status_finish(client, res, &error);
	if (!output) {
		g_printerr("IMSA registration request failed for subscription %u: %s\n",
			   subscription->index, error->message);
		g_clear_error(&error);
		finish(subscription->imsd, 1);
		return;
	}
	result = subscription->registration_indicated ? 0 :
		hotdog_qmi_imsa_decode_registration(
			output,
			&subscription->imsd->state.subscriptions[subscription->index].ims,
			&remote);
	if (result) {
		g_printerr("IMSA registration rejected for subscription %u: %d remote=%u\n",
			   subscription->index, result, remote);
		finish(subscription->imsd, 1);
		return;
	}
	qmi_client_imsa_get_ims_services_status(
		client, NULL, 10, subscription->imsd->cancellable,
		(GAsyncReadyCallback)services_ready, subscription);
}

static void indications_ready(QmiClientImsa *client, GAsyncResult *res,
			      struct imsd_subscription *subscription)
{
	g_autoptr(QmiMessageImsaRegisterIndicationsOutput) output = NULL;
	GError *error = NULL;

	output = qmi_client_imsa_register_indications_finish(client, res, &error);
	if (!output || !qmi_message_imsa_register_indications_output_get_result(output, &error)) {
		g_printerr("IMSA indication registration failed for subscription %u: %s\n",
			   subscription->index, error ? error->message : "missing output");
		g_clear_error(&error);
		finish(subscription->imsd, 1);
		return;
	}
	subscription->registration_handler = g_signal_connect(
		client, "ims-registration-status-changed",
		G_CALLBACK(registration_indication), subscription);
	subscription->services_handler = g_signal_connect(
		client, "ims-services-status-changed",
		G_CALLBACK(services_indication), subscription);
	qmi_client_imsa_get_ims_registration_status(
		client, NULL, 10, subscription->imsd->cancellable,
		(GAsyncReadyCallback)registration_ready, subscription);
}

static void bind_ready(QmiClientImsa *client, GAsyncResult *res,
		       struct imsd_subscription *subscription)
{
	g_autoptr(QmiMessageImsaBindOutput) output = NULL;
	g_autoptr(QmiMessageImsaRegisterIndicationsInput) input = NULL;
	GError *error = NULL;

	output = qmi_client_imsa_bind_finish(client, res, &error);
	if (!output || !qmi_message_imsa_bind_output_get_result(output, &error)) {
		g_printerr("IMSA bind failed for subscription %u: %s\n",
			   subscription->index, error ? error->message : "missing output");
		g_clear_error(&error);
		finish(subscription->imsd, 1);
		return;
	}
	if (hotdog_qmi_imsa_register_input(&input)) {
		finish(subscription->imsd, 1);
		return;
	}
	qmi_client_imsa_register_indications(
		client, input, 10, subscription->imsd->cancellable,
		(GAsyncReadyCallback)indications_ready, subscription);
}

static void client_ready(QmiDevice *device, GAsyncResult *res,
			 struct imsd_subscription *subscription)
{
	g_autoptr(QmiMessageImsaBindInput) input = NULL;
	QmiClient *client;
	GError *error = NULL;

	client = qmi_device_allocate_client_finish(device, res, &error);
	if (!client) {
		g_printerr("IMSA client allocation failed for subscription %u: %s\n",
			   subscription->index, error->message);
		g_clear_error(&error);
		finish(subscription->imsd, 1);
		return;
	}
	subscription->client = QMI_CLIENT_IMSA(client);
	if (hotdog_qmi_imsa_bind_input(subscription->index, &input)) {
		finish(subscription->imsd, 1);
		return;
	}
	qmi_client_imsa_bind(subscription->client, input, 10,
			     subscription->imsd->cancellable,
			     (GAsyncReadyCallback)bind_ready, subscription);
}

static void start_next_subscription(struct imsd *imsd)
{
	while (imsd->next_subscription < HOTDOG_TELEPHONY_MAX_SUBSCRIPTIONS &&
	       !imsd->state.subscriptions[imsd->next_subscription].populated)
		imsd->next_subscription++;
	if (imsd->next_subscription == HOTDOG_TELEPHONY_MAX_SUBSCRIPTIONS) {
		size_t index;

		imsd->initialized = true;
		if (publish_state(imsd)) {
			finish(imsd, 1);
			return;
		}
		/* Every populated subscription enters discovery together: a
		 * populated one left absent is not a publishable state, and the
		 * requests themselves stay sequential on the one device. */
		for (index = 0; index < HOTDOG_TELEPHONY_MAX_SUBSCRIPTIONS; index++) {
			if (imsd->bearer.subscriptions[index].populated)
				imsd->bearer.subscriptions[index].status =
					HOTDOG_IMS_BEARER_DISCOVERING;
		}
		if (publish_bearer(imsd)) {
			finish(imsd, 1);
			return;
		}
		start_next_discovery(imsd);
		return;
	}
	qmi_device_allocate_client(
		imsd->device, QMI_SERVICE_IMSA, QMI_CID_NONE, 10, imsd->cancellable,
		(GAsyncReadyCallback)client_ready,
		&imsd->subscriptions[imsd->next_subscription]);
}

static void device_open_ready(QmiDevice *device, GAsyncResult *res, struct imsd *imsd)
{
	GError *error = NULL;

	if (!qmi_device_open_finish(device, res, &error)) {
		g_printerr("IMSA QMI device open failed: %s\n", error->message);
		g_clear_error(&error);
		finish(imsd, 1);
		return;
	}
	start_next_subscription(imsd);
}

static void device_ready(GObject *source, GAsyncResult *res, struct imsd *imsd)
{
	GError *error = NULL;

	(void)source;
	imsd->device = qmi_device_new_finish(res, &error);
	if (!imsd->device) {
		g_printerr("IMSA QMI device creation failed: %s\n", error->message);
		g_clear_error(&error);
		finish(imsd, 1);
		return;
	}
	qmi_device_open(imsd->device, QMI_DEVICE_OPEN_FLAGS_EXPECT_INDICATIONS,
			10, imsd->cancellable,
			(GAsyncReadyCallback)device_open_ready, imsd);
}

static void node_removed(QrtrBus *bus, guint node_id, struct imsd *imsd)
{
	size_t index;

	(void)bus;
	if (node_id != imsd->node)
		return;
	g_printerr("IMSA QRTR node removed\n");
	/* Decide the teardown before aborting: the abort completes each
	 * outstanding discovery synchronously, and those completions must not
	 * republish state the removal has already invalidated. */
	finish(imsd, 1);
	for (index = 0; index < HOTDOG_TELEPHONY_MAX_SUBSCRIPTIONS; index++) {
		hotdog_qmi_wds_discovery_abort_ssr(&imsd->subscriptions[index].discovery);
		/* Remote CIDs and packet handles died with the QMI generation;
		 * only the still-local rmnet link is worth unwinding. */
		hotdog_qmi_ims_session_ssr(&imsd->subscriptions[index].session);
	}
}

static void bus_ready(GObject *source, GAsyncResult *res, struct imsd *imsd)
{
	QrtrNode *node;
	GError *error = NULL;

	(void)source;
	imsd->bus = qrtr_bus_new_finish(res, &error);
	if (!imsd->bus) {
		g_printerr("IMSA QRTR bus failed: %s\n", error->message);
		g_clear_error(&error);
		finish(imsd, 1);
		return;
	}
	imsd->node_removed_handler = g_signal_connect(
		imsd->bus, QRTR_BUS_SIGNAL_NODE_REMOVED,
		G_CALLBACK(node_removed), imsd);
	node = qrtr_bus_peek_node(imsd->bus, imsd->node);
	if (!node) {
		g_printerr("IMSA QRTR node %u unavailable\n", imsd->node);
		finish(imsd, 1);
		return;
	}
	qmi_device_new_from_node(node, imsd->cancellable,
				 (GAsyncReadyCallback)device_ready, imsd);
}

static gboolean poll_readiness(gpointer user_data)
{
	struct imsd *imsd = user_data;

	if (!imsd->finished && verify_readiness(imsd)) {
		g_printerr("IMSA readiness became invalid\n");
		finish(imsd, 1);
	}
	return G_SOURCE_CONTINUE;
}

static gboolean terminate(gpointer user_data)
{
	finish(user_data, 0);
	return G_SOURCE_REMOVE;
}

static void release_ready(QmiDevice *device, GAsyncResult *res,
			  struct release_wait *wait)
{
	GError *error = NULL;

	if (!qmi_device_release_client_finish(device, res, &error)) {
		g_printerr("IMSA client release failed: %s\n", error->message);
		g_clear_error(&error);
	}
	wait->done = true;
}

static void release_client(struct imsd *imsd, QmiClientImsa *client)
{
	struct release_wait wait = { 0 };

	if (!imsd->device || !client)
		return;
	qmi_device_release_client(
		imsd->device, QMI_CLIENT(client), QMI_DEVICE_RELEASE_CLIENT_FLAGS_RELEASE_CID,
		10, NULL, (GAsyncReadyCallback)release_ready, &wait);
	while (!wait.done)
		g_main_context_iteration(NULL, TRUE);
}

int main(int argc, char **argv)
{
	struct imsd imsd = { .node = 0 };
	GOptionContext *options;
	GError *error = NULL;
	GOptionEntry entries[] = {
		{ "node", 'n', 0, G_OPTION_ARG_INT, &imsd.node, "QRTR node", "ID" },
		{ "generation", 0, 0, G_OPTION_ARG_INT, &imsd.generation,
		  "Supervisor SSR generation", "GENERATION" },
		{ "readiness", 0, 0, G_OPTION_ARG_FILENAME, &imsd.readiness_path,
		  "Readiness record", "FILE" },
		{ "state", 0, 0, G_OPTION_ARG_FILENAME, &imsd.state_path,
		  "IMS runtime state", "FILE" },
		{ "ims-bearer", 0, 0, G_OPTION_ARG_FILENAME, &imsd.bearer_path,
		  "IMS bearer runtime state", "FILE" },
		{ "boot-id", 0, 0, G_OPTION_ARG_FILENAME, &imsd.boot_id_path,
		  "Kernel boot ID", "FILE" },
		{ "runtime-manifest", 0, 0, G_OPTION_ARG_FILENAME, &imsd.runtime_manifest,
		  "Packaged MCFG manifest", "FILE" },
		{ "ip-path", 0, 0, G_OPTION_ARG_FILENAME, &imsd.ip_path,
		  "iproute2 binary used for IMS link configuration", "FILE" },
		{ NULL }
	};
	size_t index;
	int result;

	options = g_option_context_new(
		"- monitor per-subscription IMSA state and select IMS bearer profiles");
	g_option_context_add_main_entries(options, entries, NULL);
	if (!g_option_context_parse(options, &argc, &argv, &error)) {
		g_printerr("option parsing failed: %s\n", error->message);
		g_clear_error(&error);
		g_option_context_free(options);
		return 2;
	}
	g_option_context_free(options);
	if (!imsd.readiness_path) imsd.readiness_path = g_strdup(DEFAULT_READINESS_PATH);
	if (!imsd.state_path) imsd.state_path = g_strdup(DEFAULT_IMS_STATE_PATH);
	if (!imsd.bearer_path) imsd.bearer_path = g_strdup(DEFAULT_IMS_BEARER_PATH);
	if (!imsd.boot_id_path) imsd.boot_id_path = g_strdup(DEFAULT_BOOT_ID_PATH);
	if (!imsd.runtime_manifest) imsd.runtime_manifest = g_strdup(DEFAULT_RUNTIME_MANIFEST);
	if (!imsd.ip_path) imsd.ip_path = g_strdup(DEFAULT_IP_PATH);
	if (!imsd.readiness_path || !imsd.state_path || !imsd.bearer_path ||
	    !imsd.boot_id_path || !imsd.runtime_manifest || !imsd.ip_path ||
	    imsd.node > UINT16_MAX || imsd.generation > 1000000) {
		g_printerr("invalid IMS daemon configuration\n");
		result = -EINVAL;
		goto out;
	}
	result = verify_readiness(&imsd);
	if (result) {
		g_printerr("IMSA startup readiness rejected: %d\n", result);
		goto out;
	}
	memcpy(imsd.state.boot_id, imsd.readiness.boot_id, sizeof(imsd.state.boot_id));
	imsd.state.generation = imsd.generation;
	memcpy(imsd.bearer.boot_id, imsd.readiness.boot_id, sizeof(imsd.bearer.boot_id));
	imsd.bearer.generation = imsd.generation;
	for (index = 0; index < HOTDOG_TELEPHONY_MAX_SUBSCRIPTIONS; index++) {
		imsd.subscriptions[index].imsd = &imsd;
		imsd.subscriptions[index].index = index;
		hotdog_qmi_wds_discovery_init(&imsd.subscriptions[index].discovery);
		hotdog_qmi_ims_session_init(&imsd.subscriptions[index].session);
		imsd.state.subscriptions[index].populated =
			imsd.readiness.subscriptions[index].populated;
		imsd.bearer.subscriptions[index].populated =
			imsd.readiness.subscriptions[index].populated;
	}
	imsd.loop = g_main_loop_new(NULL, FALSE);
	imsd.cancellable = g_cancellable_new();
	imsd.readiness_poll_id = g_timeout_add_seconds(1, poll_readiness, &imsd);
	g_unix_signal_add(SIGINT, terminate, &imsd);
	g_unix_signal_add(SIGTERM, terminate, &imsd);
	qrtr_bus_new(1000, imsd.cancellable, (GAsyncReadyCallback)bus_ready, &imsd);
	g_main_loop_run(imsd.loop);
	result = imsd.result;
	if (imsd.readiness_poll_id)
		g_source_remove(imsd.readiness_poll_id);
	if (imsd.bus && imsd.node_removed_handler)
		g_signal_handler_disconnect(imsd.bus, imsd.node_removed_handler);
	for (index = 0; index < HOTDOG_TELEPHONY_MAX_SUBSCRIPTIONS; index++) {
		struct imsd_subscription *subscription = &imsd.subscriptions[index];

		if (subscription->discovery.active || subscription->discovery.residue)
			hotdog_qmi_wds_discovery_abort_ssr(&subscription->discovery);
		hotdog_qmi_wds_discovery_clear(&subscription->discovery);
		hotdog_qmi_ims_session_clear(&subscription->session);
		if (subscription->client && subscription->registration_handler)
			g_signal_handler_disconnect(
				subscription->client, subscription->registration_handler);
		if (subscription->client && subscription->services_handler)
			g_signal_handler_disconnect(
				subscription->client, subscription->services_handler);
		release_client(&imsd, subscription->client);
		g_clear_object(&subscription->client);
	}
	g_clear_object(&imsd.device);
	g_clear_object(&imsd.bus);
	g_clear_object(&imsd.cancellable);
	g_main_loop_unref(imsd.loop);
out:
	g_free(imsd.readiness_path);
	g_free(imsd.state_path);
	g_free(imsd.bearer_path);
	g_free(imsd.boot_id_path);
	g_free(imsd.ip_path);
	g_free(imsd.runtime_manifest);
	return result ? 1 : 0;
}
