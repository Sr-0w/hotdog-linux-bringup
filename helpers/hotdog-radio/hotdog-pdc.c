/* SPDX-License-Identifier: GPL-2.0-only */
#include "hotdog-pdc.h"

#include <errno.h>
#include <string.h>

bool hotdog_pdc_id_equal(const struct hotdog_pdc_id *left, const struct hotdog_pdc_id *right)
{
	return left->length == right->length &&
	       (!left->length || !memcmp(left->value, right->value, left->length));
}

static int match_score(enum hotdog_mbn_match match)
{
	switch (match) {
	case HOTDOG_MBN_MATCH_LONG_IIN: return 4;
	case HOTDOG_MBN_MATCH_IIN: return 3;
	case HOTDOG_MBN_MATCH_PLMN: return 2;
	case HOTDOG_MBN_MATCH_WILDCARD: return 1;
	case HOTDOG_MBN_MATCH_NONE: return 0;
	}
	return 0;
}

int hotdog_pdc_choose(const struct hotdog_pdc_catalog *catalog, const char *iccid,
		      uint16_t mcc, uint16_t mnc, size_t *selected)
{
	int best_score = 0;
	uint32_t best_version = 0;
	size_t best = 0, i;

	if (!catalog || !iccid || !selected)
		return -EINVAL;
	for (i = 0; i < catalog->count; i++) {
		int score = match_score(hotdog_mbn_match(&catalog->configs[i].metadata,
							 iccid, mcc, mnc));
		if (score > best_score || (score == best_score && score &&
		    catalog->configs[i].version > best_version)) {
			best_score = score;
			best_version = catalog->configs[i].version;
			best = i;
		}
	}
	if (!best_score)
		return -ENOENT;
	*selected = best;
	return 0;
}

static int append_operation(struct hotdog_pdc_plan *plan,
			    enum hotdog_pdc_operation_type type,
			    unsigned int subscription,
			    const struct hotdog_pdc_id *id,
			    unsigned int expected)
{
	struct hotdog_pdc_operation *operation;

	if (plan->count >= HOTDOG_PDC_MAX_OPERATIONS)
		return -ENOSPC;
	operation = &plan->operations[plan->count++];
	memset(operation, 0, sizeof(*operation));
	operation->type = type;
	operation->subscription = subscription;
	operation->expected_indications = expected;
	if (id)
		operation->id = *id;
	return 0;
}

int hotdog_pdc_plan_activation(const struct hotdog_pdc_catalog *catalog,
			       struct hotdog_pdc_subscription *subscriptions,
			       size_t subscription_count,
			       struct hotdog_pdc_plan *plan)
{
	unsigned int pending = 0, last_pending = 0;
	size_t i;

	if (!catalog || !subscriptions || !plan ||
	    subscription_count > HOTDOG_PDC_MAX_SUBSCRIPTIONS)
		return -EINVAL;
	memset(plan, 0, sizeof(*plan));
	for (i = 0; i < subscription_count; i++) {
		size_t selected;
		int result;

		if (!subscriptions[i].populated)
			continue;
		result = hotdog_pdc_choose(catalog, subscriptions[i].iccid,
					    subscriptions[i].mcc, subscriptions[i].mnc,
					    &selected);
		if (result)
			return result;
		subscriptions[i].selected = catalog->configs[selected].id;
		if (hotdog_pdc_id_equal(&subscriptions[i].active, &subscriptions[i].selected))
			continue;
		subscriptions[i].previous = subscriptions[i].active;
		if (append_operation(plan, HOTDOG_PDC_SAVE_ACTIVE, (unsigned int)i,
				     &subscriptions[i].active, 0) ||
		    append_operation(plan, HOTDOG_PDC_SET_SELECTED, (unsigned int)i,
				     &subscriptions[i].selected, 0))
			return -ENOSPC;
		pending++;
		last_pending = (unsigned int)i;
	}
	if (!pending)
		return 0;
	if (append_operation(plan, HOTDOG_PDC_ACTIVATE, last_pending, NULL, pending) ||
	    append_operation(plan, HOTDOG_PDC_SWITCH_MODEM, last_pending, NULL, 0))
		return -ENOSPC;
	for (i = 0; i < subscription_count; i++) {
		if (!subscriptions[i].populated ||
		    hotdog_pdc_id_equal(&subscriptions[i].active, &subscriptions[i].selected))
			continue;
		if (append_operation(plan, HOTDOG_PDC_VERIFY_ACTIVE, (unsigned int)i,
				     &subscriptions[i].selected, 0))
			return -ENOSPC;
	}
	return 0;
}

int hotdog_pdc_plan_rollback(const struct hotdog_pdc_subscription *subscriptions,
			     size_t subscription_count,
			     struct hotdog_pdc_plan *plan)
{
	unsigned int pending = 0, last_pending = 0;
	size_t i;

	if (!subscriptions || !plan || subscription_count > HOTDOG_PDC_MAX_SUBSCRIPTIONS)
		return -EINVAL;
	memset(plan, 0, sizeof(*plan));
	for (i = 0; i < subscription_count; i++) {
		if (!subscriptions[i].populated || !subscriptions[i].previous.length)
			continue;
		if (append_operation(plan, HOTDOG_PDC_DEACTIVATE, (unsigned int)i,
				     &subscriptions[i].selected, 1) ||
		    append_operation(plan, HOTDOG_PDC_RESTORE_SELECTED, (unsigned int)i,
				     &subscriptions[i].previous, 0))
			return -ENOSPC;
		pending++;
		last_pending = (unsigned int)i;
	}
	if (pending && (append_operation(plan, HOTDOG_PDC_ACTIVATE, last_pending, NULL, pending) ||
			append_operation(plan, HOTDOG_PDC_SWITCH_MODEM, last_pending, NULL, 0)))
		return -ENOSPC;
	return 0;
}

bool hotdog_pdc_plan_verified(const struct hotdog_pdc_subscription *subscriptions,
			      size_t subscription_count)
{
	size_t i;

	for (i = 0; i < subscription_count; i++) {
		if (subscriptions[i].populated &&
		    !hotdog_pdc_id_equal(&subscriptions[i].active, &subscriptions[i].selected))
			return false;
	}
	return true;
}

const char *hotdog_pdc_operation_name(enum hotdog_pdc_operation_type type)
{
	switch (type) {
	case HOTDOG_PDC_SAVE_ACTIVE: return "save-active";
	case HOTDOG_PDC_SET_SELECTED: return "set-selected";
	case HOTDOG_PDC_ACTIVATE: return "activate";
	case HOTDOG_PDC_SWITCH_MODEM: return "switch-modem";
	case HOTDOG_PDC_VERIFY_ACTIVE: return "verify-active";
	case HOTDOG_PDC_DEACTIVATE: return "deactivate";
	case HOTDOG_PDC_RESTORE_SELECTED: return "restore-selected";
	}
	return "invalid";
}
