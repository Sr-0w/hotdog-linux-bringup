/* SPDX-License-Identifier: GPL-2.0-only */
#define _POSIX_C_SOURCE 200809L
#include "hotdog-ims-executor.h"

#include <errno.h>
#include <string.h>

static void set_operation(struct hotdog_ims_executor_operation *operation,
			  enum hotdog_ims_executor_action action,
			  unsigned int leg, uint32_t packet_handle)
{
	memset(operation, 0, sizeof(*operation));
	operation->action = action;
	operation->leg = leg;
	operation->packet_handle = packet_handle;
}

void hotdog_ims_executor_init(struct hotdog_ims_executor *executor)
{
	if (!executor)
		return;
	memset(executor, 0, sizeof(*executor));
}

int hotdog_ims_executor_begin(
	struct hotdog_ims_executor *executor, enum hotdog_ip_family family,
	struct hotdog_ims_executor_operation *operation)
{
	if (!executor || !operation || family > HOTDOG_IP_V4V6)
		return -EINVAL;
	if (executor->phase != HOTDOG_IMS_EXECUTOR_IDLE &&
	    executor->phase != HOTDOG_IMS_EXECUTOR_FAILED)
		return -EBUSY;
	memset(executor, 0, sizeof(*executor));
	executor->family = family;
	executor->leg_count = family == HOTDOG_IP_V4V6 ? 2 : 1;
	executor->phase = HOTDOG_IMS_EXECUTOR_ADDING_LINK;
	set_operation(operation, HOTDOG_IMS_EXECUTOR_ACTION_ADD_LINK, 0, 0);
	return 0;
}

int hotdog_ims_executor_link_added(
	struct hotdog_ims_executor *executor, const char *ifname, unsigned int mux_id,
	struct hotdog_ims_executor_operation *operation)
{
	size_t length;

	if (!executor || !ifname || !operation ||
	    executor->phase != HOTDOG_IMS_EXECUTOR_ADDING_LINK || !mux_id ||
	    mux_id > UINT8_MAX)
		return -EINVAL;
	length = strnlen(ifname, sizeof(executor->ifname));
	if (!length || length >= sizeof(executor->ifname))
		return -EINVAL;
	memcpy(executor->ifname, ifname, length + 1);
	executor->mux_id = mux_id;
	executor->link_owned = true;
	executor->next_leg = 0;
	executor->phase = HOTDOG_IMS_EXECUTOR_ALLOCATING_CLIENTS;
	set_operation(operation, HOTDOG_IMS_EXECUTOR_ACTION_ALLOCATE_CLIENTS,
		      executor->next_leg, 0);
	return 0;
}

int hotdog_ims_executor_client_allocated(
	struct hotdog_ims_executor *executor, unsigned int leg,
	struct hotdog_ims_executor_operation *operation)
{
	if (!executor || !operation ||
	    executor->phase != HOTDOG_IMS_EXECUTOR_ALLOCATING_CLIENTS ||
	    leg != executor->next_leg || leg >= executor->leg_count)
		return -EPROTO;
	executor->client_count++;
	executor->clients_owned = true;
	executor->next_leg++;
	if (executor->next_leg < executor->leg_count) {
		set_operation(operation, HOTDOG_IMS_EXECUTOR_ACTION_ALLOCATE_CLIENTS,
			      executor->next_leg, 0);
		return 0;
	}
	executor->next_leg = 0;
	executor->phase = HOTDOG_IMS_EXECUTOR_BINDING;
	set_operation(operation, HOTDOG_IMS_EXECUTOR_ACTION_BIND_LEG, 0, 0);
	return 0;
}

int hotdog_ims_executor_leg_bound(
	struct hotdog_ims_executor *executor, unsigned int leg,
	struct hotdog_ims_executor_operation *operation)
{
	if (!executor || !operation || executor->phase != HOTDOG_IMS_EXECUTOR_BINDING ||
	    leg != executor->next_leg || leg >= executor->leg_count)
		return -EPROTO;
	executor->next_leg++;
	if (executor->next_leg < executor->leg_count) {
		set_operation(operation, HOTDOG_IMS_EXECUTOR_ACTION_BIND_LEG,
			      executor->next_leg, 0);
		return 0;
	}
	executor->next_leg = 0;
	executor->phase = HOTDOG_IMS_EXECUTOR_STARTING;
	set_operation(operation, HOTDOG_IMS_EXECUTOR_ACTION_START_LEG, 0, 0);
	return 0;
}

int hotdog_ims_executor_leg_started(
	struct hotdog_ims_executor *executor, unsigned int leg, uint32_t packet_handle,
	struct hotdog_ims_executor_operation *operation)
{
	if (!executor || !operation || !packet_handle ||
	    executor->phase != HOTDOG_IMS_EXECUTOR_STARTING ||
	    leg != executor->next_leg || leg >= executor->leg_count ||
	    executor->packet_handles[leg])
		return -EPROTO;
	executor->packet_handles[leg] = packet_handle;
	executor->next_leg++;
	if (executor->next_leg < executor->leg_count) {
		set_operation(operation, HOTDOG_IMS_EXECUTOR_ACTION_START_LEG,
			      executor->next_leg, 0);
		return 0;
	}
	executor->next_leg = 0;
	executor->phase = HOTDOG_IMS_EXECUTOR_READING_SETTINGS;
	set_operation(operation, HOTDOG_IMS_EXECUTOR_ACTION_READ_SETTINGS, 0, 0);
	return 0;
}

int hotdog_ims_executor_settings_read(
	struct hotdog_ims_executor *executor, unsigned int leg,
	struct hotdog_ims_executor_operation *operation)
{
	if (!executor || !operation ||
	    executor->phase != HOTDOG_IMS_EXECUTOR_READING_SETTINGS ||
	    leg != executor->next_leg || leg >= executor->leg_count)
		return -EPROTO;
	executor->next_leg++;
	if (executor->next_leg < executor->leg_count) {
		set_operation(operation, HOTDOG_IMS_EXECUTOR_ACTION_READ_SETTINGS,
			      executor->next_leg, 0);
		return 0;
	}
	executor->phase = HOTDOG_IMS_EXECUTOR_CONFIGURING;
	set_operation(operation, HOTDOG_IMS_EXECUTOR_ACTION_CONFIGURE_LINK, 0, 0);
	return 0;
}

int hotdog_ims_executor_configured(
	struct hotdog_ims_executor *executor,
	struct hotdog_ims_executor_operation *operation)
{
	if (!executor || !operation || executor->phase != HOTDOG_IMS_EXECUTOR_CONFIGURING)
		return -EPROTO;
	executor->local_config_owned = true;
	executor->phase = HOTDOG_IMS_EXECUTOR_UP;
	set_operation(operation, HOTDOG_IMS_EXECUTOR_ACTION_PUBLISH_UP, 0, 0);
	return 0;
}

static void next_cleanup(struct hotdog_ims_executor *executor,
			 struct hotdog_ims_executor_operation *operation)
{
	unsigned int leg;

	for (leg = 0; leg < executor->leg_count; leg++) {
		if (!executor->packet_handles[leg])
			continue;
		executor->phase = HOTDOG_IMS_EXECUTOR_STOPPING;
		set_operation(operation, HOTDOG_IMS_EXECUTOR_ACTION_STOP_LEG, leg,
			      executor->packet_handles[leg]);
		return;
	}
	if (executor->clients_owned) {
		executor->phase = HOTDOG_IMS_EXECUTOR_RELEASING_CLIENTS;
		set_operation(operation, HOTDOG_IMS_EXECUTOR_ACTION_RELEASE_CLIENTS, 0, 0);
		return;
	}
	if (executor->link_owned) {
		executor->phase = HOTDOG_IMS_EXECUTOR_DELETING_LINK;
		set_operation(operation, HOTDOG_IMS_EXECUTOR_ACTION_DELETE_LINK, 0, 0);
		return;
	}
	executor->phase = executor->error ?
		HOTDOG_IMS_EXECUTOR_FAILED : HOTDOG_IMS_EXECUTOR_IDLE;
	set_operation(operation, HOTDOG_IMS_EXECUTOR_ACTION_PUBLISH_DOWN, 0, 0);
}

static void begin_cleanup(struct hotdog_ims_executor *executor,
			  struct hotdog_ims_executor_operation *operation)
{
	if (executor->local_config_owned) {
		executor->phase = HOTDOG_IMS_EXECUTOR_UNCONFIGURING;
		set_operation(operation, HOTDOG_IMS_EXECUTOR_ACTION_UNCONFIGURE_LINK, 0, 0);
		return;
	}
	next_cleanup(executor, operation);
}

int hotdog_ims_executor_unconfigured(
	struct hotdog_ims_executor *executor,
	struct hotdog_ims_executor_operation *operation)
{
	if (!executor || !operation ||
	    executor->phase != HOTDOG_IMS_EXECUTOR_UNCONFIGURING)
		return -EPROTO;
	executor->local_config_owned = false;
	next_cleanup(executor, operation);
	return 0;
}

int hotdog_ims_executor_stop(
	struct hotdog_ims_executor *executor,
	struct hotdog_ims_executor_operation *operation)
{
	if (!executor || !operation || executor->phase != HOTDOG_IMS_EXECUTOR_UP)
		return -EPROTO;
	executor->intentional_stop = true;
	executor->error = 0;
	begin_cleanup(executor, operation);
	return 0;
}

int hotdog_ims_executor_fail(
	struct hotdog_ims_executor *executor, unsigned int error,
	struct hotdog_ims_executor_operation *operation)
{
	if (!executor || !operation || !error ||
	    executor->phase == HOTDOG_IMS_EXECUTOR_IDLE ||
	    executor->phase == HOTDOG_IMS_EXECUTOR_FAILED ||
	    executor->phase == HOTDOG_IMS_EXECUTOR_BLOCKED)
		return -EINVAL;
	executor->intentional_stop = false;
	executor->error = error;
	if (executor->phase == HOTDOG_IMS_EXECUTOR_CONFIGURING)
		executor->local_config_owned = true;
	begin_cleanup(executor, operation);
	return 0;
}

int hotdog_ims_executor_leg_stopped(
	struct hotdog_ims_executor *executor, unsigned int leg, uint32_t packet_handle,
	struct hotdog_ims_executor_operation *operation)
{
	if (!executor || !operation || executor->phase != HOTDOG_IMS_EXECUTOR_STOPPING ||
	    leg >= executor->leg_count || !packet_handle ||
	    executor->packet_handles[leg] != packet_handle)
		return -ESTALE;
	executor->packet_handles[leg] = 0;
	next_cleanup(executor, operation);
	return 0;
}

int hotdog_ims_executor_clients_released(
	struct hotdog_ims_executor *executor,
	struct hotdog_ims_executor_operation *operation)
{
	if (!executor || !operation ||
	    executor->phase != HOTDOG_IMS_EXECUTOR_RELEASING_CLIENTS)
		return -EPROTO;
	executor->clients_owned = false;
	executor->client_count = 0;
	next_cleanup(executor, operation);
	return 0;
}

int hotdog_ims_executor_link_deleted(
	struct hotdog_ims_executor *executor,
	struct hotdog_ims_executor_operation *operation)
{
	if (!executor || !operation || executor->phase != HOTDOG_IMS_EXECUTOR_DELETING_LINK)
		return -EPROTO;
	executor->link_owned = false;
	executor->mux_id = 0;
	memset(executor->ifname, 0, sizeof(executor->ifname));
	next_cleanup(executor, operation);
	return 0;
}

int hotdog_ims_executor_cleanup_failed(
	struct hotdog_ims_executor *executor, unsigned int error)
{
	if (!executor || !error ||
	    (executor->phase != HOTDOG_IMS_EXECUTOR_UNCONFIGURING &&
	     executor->phase != HOTDOG_IMS_EXECUTOR_STOPPING &&
	     executor->phase != HOTDOG_IMS_EXECUTOR_RELEASING_CLIENTS &&
	     executor->phase != HOTDOG_IMS_EXECUTOR_DELETING_LINK))
		return -EINVAL;
	executor->cleanup_error = error;
	executor->phase = HOTDOG_IMS_EXECUTOR_BLOCKED;
	return 0;
}

int hotdog_ims_executor_ssr(
	struct hotdog_ims_executor *executor,
	struct hotdog_ims_executor_operation *operation)
{
	if (!executor || !operation || executor->phase == HOTDOG_IMS_EXECUTOR_IDLE)
		return -EINVAL;
	executor->intentional_stop = false;
	executor->error = ENETRESET;
	executor->clients_owned = false;
	executor->client_count = 0;
	memset(executor->packet_handles, 0, sizeof(executor->packet_handles));
	if (executor->local_config_owned) {
		executor->phase = HOTDOG_IMS_EXECUTOR_UNCONFIGURING;
		set_operation(operation, HOTDOG_IMS_EXECUTOR_ACTION_UNCONFIGURE_LINK, 0, 0);
	} else if (executor->link_owned) {
		executor->phase = HOTDOG_IMS_EXECUTOR_DELETING_LINK;
		set_operation(operation, HOTDOG_IMS_EXECUTOR_ACTION_DELETE_LINK, 0, 0);
	} else {
		executor->phase = HOTDOG_IMS_EXECUTOR_FAILED;
		set_operation(operation, HOTDOG_IMS_EXECUTOR_ACTION_PUBLISH_DOWN, 0, 0);
	}
	return 0;
}

const char *hotdog_ims_executor_phase_name(enum hotdog_ims_executor_phase phase)
{
	static const char *const names[] = {
		"idle", "adding-link", "allocating-clients", "binding", "starting",
		"reading-settings", "configuring", "up", "unconfiguring", "stopping",
		"releasing-clients", "deleting-link", "failed", "blocked",
	};

	return phase <= HOTDOG_IMS_EXECUTOR_BLOCKED ? names[phase] : "invalid";
}

const char *hotdog_ims_executor_action_name(enum hotdog_ims_executor_action action)
{
	static const char *const names[] = {
		"none", "add-link", "allocate-clients", "bind-leg", "start-leg",
		"read-settings", "configure-link", "unconfigure-link", "stop-leg",
		"release-clients",
		"delete-link", "publish-up", "publish-down",
	};

	return action <= HOTDOG_IMS_EXECUTOR_ACTION_PUBLISH_DOWN ? names[action] :
		"invalid";
}
