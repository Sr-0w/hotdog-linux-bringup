/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef HOTDOG_RADIO_GATE_H
#define HOTDOG_RADIO_GATE_H

#include "hotdog-mcfg-runtime.h"
#include "hotdog-pdc.h"

#include <stddef.h>

struct hotdog_radio_gate_paths {
	const char *approval;
	const char *runtime_manifest;
	const char *boot_id;
	const char *modem;
	const char *mcfg_root;
};

int hotdog_radio_gate_validate(
	const struct hotdog_radio_gate_paths *paths,
	const struct hotdog_pdc_catalog *catalog,
	const struct hotdog_pdc_subscription *subscriptions,
	size_t subscription_count,
	struct hotdog_mcfg_runtime *runtime);

#endif
