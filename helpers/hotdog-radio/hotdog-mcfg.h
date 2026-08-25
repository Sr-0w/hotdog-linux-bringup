/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef HOTDOG_MCFG_H
#define HOTDOG_MCFG_H

#include "hotdog-pdc.h"

#include <stddef.h>
#include <stdint.h>

#define HOTDOG_MCFG_MAX_FILE_SIZE (16U * 1024U * 1024U)

struct hotdog_mcfg_report {
	size_t listed;
	size_t listed_missing;
};

struct hotdog_mcfg_profile {
	unsigned char *data;
	uint32_t size;
};

int hotdog_mcfg_catalog_load(const char *root, struct hotdog_pdc_catalog *catalog,
			     struct hotdog_mcfg_report *report);
int hotdog_mcfg_profile_open(const char *root,
			     const struct hotdog_pdc_config *config,
			     struct hotdog_mcfg_profile *profile);
void hotdog_mcfg_profile_clear(struct hotdog_mcfg_profile *profile);
int hotdog_mcfg_tree_counts(const char *root, size_t *profile_count,
			    size_t *signature_count, size_t *file_count);

#endif
