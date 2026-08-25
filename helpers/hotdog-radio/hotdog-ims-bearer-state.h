/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef HOTDOG_IMS_BEARER_STATE_H
#define HOTDOG_IMS_BEARER_STATE_H

#include "hotdog-network.h"

#define HOTDOG_IMS_BEARER_BOOT_ID_SIZE 37

enum hotdog_ims_bearer_runtime_status {
	HOTDOG_IMS_BEARER_ABSENT,
	HOTDOG_IMS_BEARER_DISCOVERING,
	HOTDOG_IMS_BEARER_UNAVAILABLE,
	HOTDOG_IMS_BEARER_STARTING,
	HOTDOG_IMS_BEARER_UP,
	HOTDOG_IMS_BEARER_FAILED,
	HOTDOG_IMS_BEARER_BLOCKED,
};

struct hotdog_ims_bearer_subscription_state {
	bool populated;
	enum hotdog_ims_bearer_runtime_status status;
	bool profile_selected;
	unsigned int profile;
	enum hotdog_ip_family family;
	unsigned int mux_id;
	char ifname[16];
	size_t pcscf_address_count;
	size_t pcscf_domain_count;
	unsigned int error;
	bool residue;
};

struct hotdog_ims_bearer_runtime_state {
	char boot_id[HOTDOG_IMS_BEARER_BOOT_ID_SIZE];
	unsigned int generation;
	struct hotdog_ims_bearer_subscription_state
		subscriptions[HOTDOG_NETWORK_MAX_SUBSCRIPTIONS];
};

int hotdog_ims_bearer_runtime_validate(
	const struct hotdog_ims_bearer_runtime_state *state);
int hotdog_ims_bearer_runtime_write(
	const char *path, const struct hotdog_ims_bearer_runtime_state *state);
int hotdog_ims_bearer_runtime_read(
	const char *path, struct hotdog_ims_bearer_runtime_state *state);
const char *hotdog_ims_bearer_runtime_status_name(
	enum hotdog_ims_bearer_runtime_status status);

#endif
