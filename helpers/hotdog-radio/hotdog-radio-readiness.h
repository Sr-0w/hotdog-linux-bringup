/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef HOTDOG_RADIO_READINESS_H
#define HOTDOG_RADIO_READINESS_H

#include "hotdog-pdc.h"
#include "hotdog-uim.h"

#include <stdbool.h>
#include <stddef.h>

#define HOTDOG_READINESS_BOOT_ID_SIZE 37
#define HOTDOG_READINESS_SHA256_SIZE 65

enum hotdog_readiness_phase {
	HOTDOG_READINESS_LOCKED,
	HOTDOG_READINESS_REGISTERING,
	HOTDOG_READINESS_READY,
};

struct hotdog_readiness_subscription {
	bool populated;
	unsigned int physical_slot;
	enum hotdog_uim_app_state app_state;
	struct hotdog_uim_retries retries;
	struct hotdog_pdc_id selected;
	struct hotdog_pdc_id active;
	struct hotdog_pdc_id pending;
};

struct hotdog_radio_readiness {
	char boot_id[HOTDOG_READINESS_BOOT_ID_SIZE];
	char modem_sha256[HOTDOG_READINESS_SHA256_SIZE];
	char mcfg_sha256[HOTDOG_READINESS_SHA256_SIZE];
	enum hotdog_readiness_phase phase;
	bool dms_online;
	struct hotdog_readiness_subscription subscriptions[HOTDOG_PDC_MAX_SUBSCRIPTIONS];
};

int hotdog_radio_readiness_validate(const struct hotdog_radio_readiness *readiness);
int hotdog_radio_readiness_write(const char *path,
				  const struct hotdog_radio_readiness *readiness);
int hotdog_radio_readiness_read(const char *path,
				 struct hotdog_radio_readiness *readiness);
const char *hotdog_readiness_phase_name(enum hotdog_readiness_phase phase);

#endif
