/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef HOTDOG_MCFG_H
#define HOTDOG_MCFG_H

#include "hotdog-pdc.h"

#include <stddef.h>

struct hotdog_mcfg_report {
	size_t listed;
	size_t listed_missing;
};

int hotdog_mcfg_catalog_load(const char *root, struct hotdog_pdc_catalog *catalog,
			     struct hotdog_mcfg_report *report);

#endif
