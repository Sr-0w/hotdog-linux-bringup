/* SPDX-License-Identifier: GPL-2.0-only */
#include "hotdog-uim.h"

#include <errno.h>
#include <string.h>

void hotdog_uim_inventory_init(struct hotdog_uim_inventory *inventory, size_t slot_count)
{
	memset(inventory, 0, sizeof(*inventory));
	inventory->slot_count = slot_count <= HOTDOG_UIM_MAX_SLOTS ? slot_count : HOTDOG_UIM_MAX_SLOTS;
}

int hotdog_uim_add_app(struct hotdog_uim_inventory *inventory, unsigned int physical_slot,
		       const struct hotdog_uim_app *app)
{
	struct hotdog_uim_slot *slot;

	if (!inventory || !app || !physical_slot || physical_slot > inventory->slot_count)
		return -EINVAL;
	slot = &inventory->slots[physical_slot - 1];
	if (slot->app_count >= HOTDOG_UIM_MAX_APPS)
		return -ENOSPC;
	slot->apps[slot->app_count++] = *app;
	return 0;
}

static const struct hotdog_uim_app *find_app(const struct hotdog_uim_slot *slot,
					      enum hotdog_uim_app_type first,
					      enum hotdog_uim_app_type second,
					      unsigned int *index)
{
	size_t i;

	for (i = 0; i < slot->app_count; i++) {
		if (slot->apps[i].type == first ||
		    (second != HOTDOG_UIM_APP_UNKNOWN && slot->apps[i].type == second)) {
			*index = (unsigned int)i;
			return &slot->apps[i];
		}
	}
	return NULL;
}

static void set_session(struct hotdog_uim_session *session, unsigned int subscription,
			unsigned int slot, unsigned int app_index,
			const struct hotdog_uim_app *app)
{
	session->subscription = subscription;
	session->physical_slot = slot;
	session->app_index = app_index;
	session->app_type = app->type;
	session->app_state = app->state;
}

int hotdog_uim_select_sessions(struct hotdog_uim_inventory *inventory)
{
	size_t i;
	unsigned int gw_subscription = 0, onex_subscription = 0, isim_subscription = 0;

	if (!inventory)
		return -EINVAL;
	inventory->gw_count = inventory->onex_count = inventory->isim_count = 0;
	for (i = 0; i < inventory->slot_count; i++) {
		struct hotdog_uim_slot *slot = &inventory->slots[i];
		const struct hotdog_uim_app *app;
		unsigned int app_index;

		if (slot->state == HOTDOG_UIM_CARD_ERROR)
			return -EIO;
		if (slot->state != HOTDOG_UIM_CARD_PRESENT)
			continue;
		app = find_app(slot, HOTDOG_UIM_APP_USIM, HOTDOG_UIM_APP_SIM, &app_index);
		if (app) {
			set_session(&inventory->gw_sessions[inventory->gw_count++],
				    gw_subscription++, (unsigned int)i + 1, app_index, app);
		}
		app = find_app(slot, HOTDOG_UIM_APP_CSIM, HOTDOG_UIM_APP_UNKNOWN, &app_index);
		if (app) {
			set_session(&inventory->onex_sessions[inventory->onex_count++],
				    onex_subscription++, (unsigned int)i + 1, app_index, app);
		}
		app = find_app(slot, HOTDOG_UIM_APP_ISIM, HOTDOG_UIM_APP_UNKNOWN, &app_index);
		if (app) {
			set_session(&inventory->isim_sessions[inventory->isim_count++],
				    isim_subscription++, (unsigned int)i + 1, app_index, app);
		}
	}
	return inventory->gw_count ? 0 : -ENODEV;
}

int hotdog_uim_security_slot(unsigned int physical_slot)
{
	if (!physical_slot || physical_slot > 5)
		return -EINVAL;
	return (int)physical_slot;
}

bool hotdog_uim_retry_transition_safe(const struct hotdog_uim_retries *before,
				      const struct hotdog_uim_retries *after,
				      bool operation_succeeded)
{
	if (!before || !after)
		return false;
	if (operation_succeeded)
		return after->pin1 == before->pin1 && after->puk1 == before->puk1;
	return after->pin1 >= before->pin1 && after->puk1 >= before->puk1 &&
	       after->pin2 >= before->pin2 && after->puk2 >= before->puk2;
}

const char *hotdog_uim_card_state_name(enum hotdog_uim_card_state state)
{
	switch (state) {
	case HOTDOG_UIM_CARD_ABSENT: return "absent";
	case HOTDOG_UIM_CARD_PRESENT: return "present";
	case HOTDOG_UIM_CARD_ERROR: return "error";
	}
	return "invalid";
}

const char *hotdog_uim_app_type_name(enum hotdog_uim_app_type type)
{
	switch (type) {
	case HOTDOG_UIM_APP_UNKNOWN: return "unknown";
	case HOTDOG_UIM_APP_SIM: return "sim";
	case HOTDOG_UIM_APP_USIM: return "usim";
	case HOTDOG_UIM_APP_CSIM: return "csim";
	case HOTDOG_UIM_APP_ISIM: return "isim";
	}
	return "invalid";
}

const char *hotdog_uim_app_state_name(enum hotdog_uim_app_state state)
{
	switch (state) {
	case HOTDOG_UIM_APP_DETECTED: return "detected";
	case HOTDOG_UIM_APP_PIN_REQUIRED: return "pin-required";
	case HOTDOG_UIM_APP_PUK_REQUIRED: return "puk-required";
	case HOTDOG_UIM_APP_READY: return "ready";
	case HOTDOG_UIM_APP_BLOCKED: return "blocked";
	}
	return "invalid";
}
