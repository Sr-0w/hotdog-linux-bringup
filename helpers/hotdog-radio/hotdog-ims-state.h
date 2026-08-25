/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef HOTDOG_IMS_STATE_H
#define HOTDOG_IMS_STATE_H

#include "hotdog-telephony.h"

#define HOTDOG_IMS_BOOT_ID_SIZE 37

struct hotdog_ims_subscription_state {
	bool populated;
	struct hotdog_ims_state ims;
};

struct hotdog_ims_runtime_state {
	char boot_id[HOTDOG_IMS_BOOT_ID_SIZE];
	unsigned int generation;
	struct hotdog_ims_subscription_state
		subscriptions[HOTDOG_TELEPHONY_MAX_SUBSCRIPTIONS];
};

int hotdog_ims_runtime_validate(const struct hotdog_ims_runtime_state *state);
int hotdog_ims_runtime_write(const char *path,
			     const struct hotdog_ims_runtime_state *state);
int hotdog_ims_runtime_read(const char *path,
			    struct hotdog_ims_runtime_state *state);

#endif
