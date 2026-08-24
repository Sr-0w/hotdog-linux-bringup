/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef HOTDOG_UIM_H
#define HOTDOG_UIM_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define HOTDOG_UIM_MAX_SLOTS 3
#define HOTDOG_UIM_MAX_APPS 8
#define HOTDOG_UIM_MAX_AID 32

enum hotdog_uim_card_state {
	HOTDOG_UIM_CARD_ABSENT,
	HOTDOG_UIM_CARD_PRESENT,
	HOTDOG_UIM_CARD_ERROR,
};

enum hotdog_uim_app_type {
	HOTDOG_UIM_APP_UNKNOWN,
	HOTDOG_UIM_APP_SIM,
	HOTDOG_UIM_APP_USIM,
	HOTDOG_UIM_APP_CSIM,
	HOTDOG_UIM_APP_ISIM,
};

enum hotdog_uim_app_state {
	HOTDOG_UIM_APP_DETECTED,
	HOTDOG_UIM_APP_PIN_REQUIRED,
	HOTDOG_UIM_APP_PUK_REQUIRED,
	HOTDOG_UIM_APP_READY,
	HOTDOG_UIM_APP_BLOCKED,
};

struct hotdog_uim_retries {
	unsigned int pin1;
	unsigned int puk1;
	unsigned int pin2;
	unsigned int puk2;
};

struct hotdog_uim_app {
	enum hotdog_uim_app_type type;
	enum hotdog_uim_app_state state;
	unsigned char aid[HOTDOG_UIM_MAX_AID];
	size_t aid_length;
	struct hotdog_uim_retries retries;
};

struct hotdog_uim_slot {
	enum hotdog_uim_card_state state;
	int card_error;
	struct hotdog_uim_app apps[HOTDOG_UIM_MAX_APPS];
	size_t app_count;
};

struct hotdog_uim_session {
	unsigned int subscription;
	unsigned int physical_slot;
	unsigned int app_index;
	enum hotdog_uim_app_type app_type;
	enum hotdog_uim_app_state app_state;
};

struct hotdog_uim_inventory {
	struct hotdog_uim_slot slots[HOTDOG_UIM_MAX_SLOTS];
	size_t slot_count;
	struct hotdog_uim_session gw_sessions[HOTDOG_UIM_MAX_SLOTS];
	struct hotdog_uim_session onex_sessions[HOTDOG_UIM_MAX_SLOTS];
	struct hotdog_uim_session isim_sessions[HOTDOG_UIM_MAX_SLOTS];
	size_t gw_count;
	size_t onex_count;
	size_t isim_count;
};

void hotdog_uim_inventory_init(struct hotdog_uim_inventory *inventory, size_t slot_count);
int hotdog_uim_add_app(struct hotdog_uim_inventory *inventory, unsigned int physical_slot,
		       const struct hotdog_uim_app *app);
int hotdog_uim_select_sessions(struct hotdog_uim_inventory *inventory);
int hotdog_uim_security_slot(unsigned int physical_slot);
bool hotdog_uim_retry_transition_safe(const struct hotdog_uim_retries *before,
				      const struct hotdog_uim_retries *after,
				      bool operation_succeeded);
const char *hotdog_uim_card_state_name(enum hotdog_uim_card_state state);
const char *hotdog_uim_app_type_name(enum hotdog_uim_app_type type);
const char *hotdog_uim_app_state_name(enum hotdog_uim_app_state state);

#endif
