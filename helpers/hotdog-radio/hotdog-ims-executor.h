/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef HOTDOG_IMS_EXECUTOR_H
#define HOTDOG_IMS_EXECUTOR_H

#include "hotdog-network.h"

#define HOTDOG_IMS_EXECUTOR_MAX_LEGS 2
#define HOTDOG_IMS_EXECUTOR_IFNAME_SIZE 16

enum hotdog_ims_executor_phase {
	HOTDOG_IMS_EXECUTOR_IDLE,
	HOTDOG_IMS_EXECUTOR_ADDING_LINK,
	HOTDOG_IMS_EXECUTOR_ALLOCATING_CLIENTS,
	HOTDOG_IMS_EXECUTOR_BINDING,
	HOTDOG_IMS_EXECUTOR_STARTING,
	HOTDOG_IMS_EXECUTOR_READING_SETTINGS,
	HOTDOG_IMS_EXECUTOR_CONFIGURING,
	HOTDOG_IMS_EXECUTOR_UP,
	HOTDOG_IMS_EXECUTOR_STOPPING,
	HOTDOG_IMS_EXECUTOR_RELEASING_CLIENTS,
	HOTDOG_IMS_EXECUTOR_DELETING_LINK,
	HOTDOG_IMS_EXECUTOR_FAILED,
	HOTDOG_IMS_EXECUTOR_BLOCKED,
};

enum hotdog_ims_executor_action {
	HOTDOG_IMS_EXECUTOR_ACTION_NONE,
	HOTDOG_IMS_EXECUTOR_ACTION_ADD_LINK,
	HOTDOG_IMS_EXECUTOR_ACTION_ALLOCATE_CLIENTS,
	HOTDOG_IMS_EXECUTOR_ACTION_BIND_LEG,
	HOTDOG_IMS_EXECUTOR_ACTION_START_LEG,
	HOTDOG_IMS_EXECUTOR_ACTION_READ_SETTINGS,
	HOTDOG_IMS_EXECUTOR_ACTION_CONFIGURE_LINK,
	HOTDOG_IMS_EXECUTOR_ACTION_STOP_LEG,
	HOTDOG_IMS_EXECUTOR_ACTION_RELEASE_CLIENTS,
	HOTDOG_IMS_EXECUTOR_ACTION_DELETE_LINK,
	HOTDOG_IMS_EXECUTOR_ACTION_PUBLISH_UP,
	HOTDOG_IMS_EXECUTOR_ACTION_PUBLISH_DOWN,
};

struct hotdog_ims_executor_operation {
	enum hotdog_ims_executor_action action;
	unsigned int leg;
	uint32_t packet_handle;
};

struct hotdog_ims_executor {
	enum hotdog_ims_executor_phase phase;
	enum hotdog_ip_family family;
	unsigned int leg_count;
	unsigned int next_leg;
	unsigned int client_count;
	unsigned int mux_id;
	uint32_t packet_handles[HOTDOG_IMS_EXECUTOR_MAX_LEGS];
	unsigned int error;
	unsigned int cleanup_error;
	bool link_owned;
	bool clients_owned;
	bool intentional_stop;
	char ifname[HOTDOG_IMS_EXECUTOR_IFNAME_SIZE];
};

void hotdog_ims_executor_init(struct hotdog_ims_executor *executor);
int hotdog_ims_executor_begin(
	struct hotdog_ims_executor *executor, enum hotdog_ip_family family,
	struct hotdog_ims_executor_operation *operation);
int hotdog_ims_executor_link_added(
	struct hotdog_ims_executor *executor, const char *ifname, unsigned int mux_id,
	struct hotdog_ims_executor_operation *operation);
int hotdog_ims_executor_client_allocated(
	struct hotdog_ims_executor *executor, unsigned int leg,
	struct hotdog_ims_executor_operation *operation);
int hotdog_ims_executor_leg_bound(
	struct hotdog_ims_executor *executor, unsigned int leg,
	struct hotdog_ims_executor_operation *operation);
int hotdog_ims_executor_leg_started(
	struct hotdog_ims_executor *executor, unsigned int leg, uint32_t packet_handle,
	struct hotdog_ims_executor_operation *operation);
int hotdog_ims_executor_settings_read(
	struct hotdog_ims_executor *executor, unsigned int leg,
	struct hotdog_ims_executor_operation *operation);
int hotdog_ims_executor_configured(
	struct hotdog_ims_executor *executor,
	struct hotdog_ims_executor_operation *operation);
int hotdog_ims_executor_stop(
	struct hotdog_ims_executor *executor,
	struct hotdog_ims_executor_operation *operation);
int hotdog_ims_executor_fail(
	struct hotdog_ims_executor *executor, unsigned int error,
	struct hotdog_ims_executor_operation *operation);
int hotdog_ims_executor_leg_stopped(
	struct hotdog_ims_executor *executor, unsigned int leg, uint32_t packet_handle,
	struct hotdog_ims_executor_operation *operation);
int hotdog_ims_executor_clients_released(
	struct hotdog_ims_executor *executor,
	struct hotdog_ims_executor_operation *operation);
int hotdog_ims_executor_link_deleted(
	struct hotdog_ims_executor *executor,
	struct hotdog_ims_executor_operation *operation);
int hotdog_ims_executor_cleanup_failed(
	struct hotdog_ims_executor *executor, unsigned int error);
int hotdog_ims_executor_ssr(
	struct hotdog_ims_executor *executor,
	struct hotdog_ims_executor_operation *operation);
const char *hotdog_ims_executor_phase_name(enum hotdog_ims_executor_phase phase);
const char *hotdog_ims_executor_action_name(enum hotdog_ims_executor_action action);

#endif
