/* SPDX-License-Identifier: GPL-2.0-only */
#include "hotdog-uim.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static enum hotdog_uim_card_state card_state(const char *name)
{
	if (!strcmp(name, "present")) return HOTDOG_UIM_CARD_PRESENT;
	if (!strcmp(name, "error")) return HOTDOG_UIM_CARD_ERROR;
	return HOTDOG_UIM_CARD_ABSENT;
}

static enum hotdog_uim_app_type app_type(const char *name)
{
	if (!strcmp(name, "sim")) return HOTDOG_UIM_APP_SIM;
	if (!strcmp(name, "usim")) return HOTDOG_UIM_APP_USIM;
	if (!strcmp(name, "csim")) return HOTDOG_UIM_APP_CSIM;
	if (!strcmp(name, "isim")) return HOTDOG_UIM_APP_ISIM;
	return HOTDOG_UIM_APP_UNKNOWN;
}

static enum hotdog_uim_app_state app_state(const char *name)
{
	if (!strcmp(name, "pin")) return HOTDOG_UIM_APP_PIN_REQUIRED;
	if (!strcmp(name, "puk")) return HOTDOG_UIM_APP_PUK_REQUIRED;
	if (!strcmp(name, "ready")) return HOTDOG_UIM_APP_READY;
	if (!strcmp(name, "blocked")) return HOTDOG_UIM_APP_BLOCKED;
	return HOTDOG_UIM_APP_DETECTED;
}

static int hex_bytes(const char *text, unsigned char *bytes, size_t *length)
{
	size_t index, text_length = strlen(text);

	if (text_length % 2 || text_length / 2 > HOTDOG_UIM_MAX_ICCID / 2)
		return -1;
	for (index = 0; index < text_length / 2; index++) {
		unsigned int byte;
		if (sscanf(&text[index * 2], "%2x", &byte) != 1)
			return -1;
		bytes[index] = (unsigned char)byte;
	}
	*length = text_length / 2;
	return 0;
}

int main(void)
{
	struct hotdog_uim_inventory inventory;
	char line[256];

	hotdog_uim_inventory_init(&inventory, 2);
	while (fgets(line, sizeof(line), stdin)) {
		unsigned int slot;
		char state_name[24], type_name[24], app_state_name[24];

		if (sscanf(line, "SLOT %u %23s", &slot, state_name) == 2) {
			if (!slot || slot > inventory.slot_count)
				return 2;
			inventory.slots[slot - 1].state = card_state(state_name);
			continue;
		}
		if (sscanf(line, "APP %u %23s %23s", &slot, type_name, app_state_name) == 3) {
			struct hotdog_uim_app app = {
				.type = app_type(type_name),
				.state = app_state(app_state_name),
			};
			if (hotdog_uim_add_app(&inventory, slot, &app))
				return 2;
			continue;
		}
		{
			unsigned int present, active, logical;
			char encoded[HOTDOG_UIM_MAX_ICCID + 1];
			if (sscanf(line, "IDENTITY %u %u %u %u %40s", &slot, &present,
				   &active, &logical, encoded) == 5) {
				unsigned char bytes[HOTDOG_UIM_MAX_ICCID / 2];
				size_t length;
				int result;

				if (hex_bytes(encoded, bytes, &length))
					return 2;
				result = hotdog_uim_set_slot_identity(&inventory, slot,
					present != 0, active != 0, logical, bytes, length);
				printf("identity=%d slot:%u", result, slot);
				if (!result)
					printf(" iccid:%s", inventory.slots[slot - 1].iccid);
				printf("\n");
				continue;
			}
		}
		if (!strncmp(line, "SELECT", 6)) {
			size_t i;
			int result = hotdog_uim_select_sessions(&inventory);
			printf("result=%d gw=%zu onex=%zu isim=%zu\n", result,
			       inventory.gw_count, inventory.onex_count, inventory.isim_count);
			for (i = 0; i < inventory.gw_count; i++) {
				const struct hotdog_uim_session *session = &inventory.gw_sessions[i];
				printf("gw%u=slot%u,app%u,%s,%s\n", session->subscription,
				       session->physical_slot, session->app_index,
				       hotdog_uim_app_type_name(session->app_type),
				       hotdog_uim_app_state_name(session->app_state));
			}
			continue;
		}
		if (sscanf(line, "SECURITY_SLOT %u", &slot) == 1) {
			printf("security-slot=%d\n", hotdog_uim_security_slot(slot));
			continue;
		}
		{
			struct hotdog_uim_retries before, after;
			unsigned int success;
			if (sscanf(line, "RETRIES %u %u %u %u %u %u %u %u %u",
				   &before.pin1, &before.puk1, &before.pin2, &before.puk2,
				   &after.pin1, &after.puk1, &after.pin2, &after.puk2,
				   &success) == 9) {
				printf("retry-safe=%u\n",
				       hotdog_uim_retry_transition_safe(&before, &after, success));
				continue;
			}
		}
		return 2;
	}
	return 0;
}
