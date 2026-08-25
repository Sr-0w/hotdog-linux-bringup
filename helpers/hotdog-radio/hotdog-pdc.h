/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef HOTDOG_PDC_H
#define HOTDOG_PDC_H

#include "hotdog-mbn.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define HOTDOG_PDC_MAX_CONFIGS 256
#define HOTDOG_PDC_MAX_SUBSCRIPTIONS 3
#define HOTDOG_PDC_ID_SIZE 20
#define HOTDOG_PDC_PATH_SIZE 512
#define HOTDOG_PDC_ICCID_SIZE 41
#define HOTDOG_PDC_MAX_OPERATIONS 32

struct hotdog_pdc_id {
	unsigned char value[HOTDOG_PDC_ID_SIZE];
	size_t length;
};

struct hotdog_pdc_config {
	struct hotdog_pdc_id id;
	struct hotdog_mbn_metadata metadata;
	uint32_t version;
	bool loaded;
	char path[HOTDOG_PDC_PATH_SIZE];
};

struct hotdog_pdc_catalog {
	struct hotdog_pdc_config configs[HOTDOG_PDC_MAX_CONFIGS];
	size_t count;
};

struct hotdog_pdc_subscription {
	bool populated;
	char iccid[HOTDOG_PDC_ICCID_SIZE];
	uint16_t mcc;
	uint16_t mnc;
	struct hotdog_pdc_id active;
	struct hotdog_pdc_id pending;
	struct hotdog_pdc_id previous;
	struct hotdog_pdc_id selected;
	bool changed;
	bool selected_loaded_by_us;
};

enum hotdog_pdc_operation_type {
	HOTDOG_PDC_SAVE_ACTIVE,
	HOTDOG_PDC_LOAD_CONFIG,
	HOTDOG_PDC_SET_SELECTED,
	HOTDOG_PDC_ACTIVATE,
	HOTDOG_PDC_SWITCH_MODEM,
	HOTDOG_PDC_VERIFY_ACTIVE,
	HOTDOG_PDC_DEACTIVATE,
	HOTDOG_PDC_RESTORE_SELECTED,
	HOTDOG_PDC_DELETE_CONFIG,
};

struct hotdog_pdc_operation {
	enum hotdog_pdc_operation_type type;
	unsigned int subscription;
	unsigned int expected_indications;
	struct hotdog_pdc_id id;
};

struct hotdog_pdc_plan {
	struct hotdog_pdc_operation operations[HOTDOG_PDC_MAX_OPERATIONS];
	size_t count;
};

int hotdog_pdc_choose(const struct hotdog_pdc_catalog *catalog, const char *iccid,
		      uint16_t mcc, uint16_t mnc, size_t *selected);
int hotdog_pdc_plan_activation(const struct hotdog_pdc_catalog *catalog,
			       struct hotdog_pdc_subscription *subscriptions,
			       size_t subscription_count,
			       struct hotdog_pdc_plan *plan);
int hotdog_pdc_plan_rollback(const struct hotdog_pdc_subscription *subscriptions,
			     size_t subscription_count,
			     struct hotdog_pdc_plan *plan);
bool hotdog_pdc_plan_verified(const struct hotdog_pdc_subscription *subscriptions,
			      size_t subscription_count);
size_t hotdog_pdc_mark_loaded(struct hotdog_pdc_catalog *catalog,
			      const struct hotdog_pdc_id *ids, size_t id_count);
bool hotdog_pdc_id_equal(const struct hotdog_pdc_id *left, const struct hotdog_pdc_id *right);
const char *hotdog_pdc_operation_name(enum hotdog_pdc_operation_type type);

#endif
