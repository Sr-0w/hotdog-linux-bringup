/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef HOTDOG_RADIO_APPROVAL_H
#define HOTDOG_RADIO_APPROVAL_H

#include "hotdog-pdc.h"

#include <stddef.h>

#define HOTDOG_APPROVAL_BOOT_ID_SIZE 37
#define HOTDOG_APPROVAL_SHA256_SIZE 65

struct hotdog_radio_approval {
	char boot_id[HOTDOG_APPROVAL_BOOT_ID_SIZE];
	char modem_sha256[HOTDOG_APPROVAL_SHA256_SIZE];
	char mcfg_sha256[HOTDOG_APPROVAL_SHA256_SIZE];
	struct hotdog_pdc_id selected[HOTDOG_PDC_MAX_SUBSCRIPTIONS];
};

int hotdog_radio_approval_read(const char *path,
			       struct hotdog_radio_approval *approval);
int hotdog_radio_approval_validate(
	const struct hotdog_radio_approval *approval, const char *boot_id,
	const char *modem_sha256, const char *mcfg_sha256,
	const struct hotdog_pdc_subscription *subscriptions, size_t subscription_count);

#endif
