/* SPDX-License-Identifier: GPL-2.0-only */
#include "hotdog-radio-state.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct event_name {
	const char *name;
	enum hotdog_radio_event_type type;
};

static const struct event_name event_names[] = {
	{ "START", HOTDOG_EVENT_START }, { "QRTR_UP", HOTDOG_EVENT_QRTR_UP },
	{ "QRTR_DOWN", HOTDOG_EVENT_QRTR_DOWN }, { "UIM_READY", HOTDOG_EVENT_UIM_READY },
	{ "UIM_UNLOCKED", HOTDOG_EVENT_UIM_UNLOCKED }, { "PDC_STATUS", HOTDOG_EVENT_PDC_STATUS },
	{ "PDC_SELECTED", HOTDOG_EVENT_PDC_SELECTED }, { "PDC_ACTIVATED", HOTDOG_EVENT_PDC_ACTIVATED },
	{ "MODEM_SWITCHED", HOTDOG_EVENT_MODEM_SWITCHED }, { "DMS_ONLINE", HOTDOG_EVENT_DMS_ONLINE },
	{ "HANDOFF_STARTED", HOTDOG_EVENT_HANDOFF_STARTED },
	{ "HANDOFF_STOPPED", HOTDOG_EVENT_HANDOFF_STOPPED },
	{ "NAS_REGISTERED", HOTDOG_EVENT_NAS_REGISTERED }, { "NAS_LOST", HOTDOG_EVENT_NAS_LOST },
	{ "DATA_UP", HOTDOG_EVENT_DATA_UP }, { "DATA_DOWN", HOTDOG_EVENT_DATA_DOWN },
	{ "SMS_BEGIN", HOTDOG_EVENT_SMS_BEGIN }, { "SMS_DONE", HOTDOG_EVENT_SMS_DONE },
	{ "CALL_BEGIN", HOTDOG_EVENT_CALL_BEGIN }, { "CALL_END", HOTDOG_EVENT_CALL_END },
	{ "IMS_REGISTERED", HOTDOG_EVENT_IMS_REGISTERED }, { "IMS_LOST", HOTDOG_EVENT_IMS_LOST },
	{ "FATAL", HOTDOG_EVENT_FATAL },
};

static int parse_event(char *line, struct hotdog_radio_event *event)
{
	char name[32];
	unsigned int value = 0, aux = 0;
	int count;
	size_t i;

	count = sscanf(line, "%31s %i %i", name, &value, &aux);
	if (count < 1)
		return -1;
	for (i = 0; i < sizeof(event_names) / sizeof(event_names[0]); i++) {
		if (!strcmp(name, event_names[i].name)) {
			event->type = event_names[i].type;
			event->value = count > 1 ? value : 0;
			event->aux = count > 2 ? aux : 0;
			return 0;
		}
	}
	return -1;
}

static void print_actions(uint32_t actions)
{
	unsigned int bit;
	bool first = true;

	for (bit = 0; bit < 32; bit++) {
		enum hotdog_radio_action action = (enum hotdog_radio_action)(1U << bit);
		if (!(actions & action))
			continue;
		printf("%s%s", first ? "" : ",", hotdog_radio_action_name(action));
		first = false;
	}
	if (first)
		printf("none");
}

int main(void)
{
	struct hotdog_radio_state state;
	char line[256];
	unsigned int sequence = 0;

	hotdog_radio_state_init(&state, 3);
	while (fgets(line, sizeof(line), stdin)) {
		struct hotdog_radio_event event;
		uint32_t actions;
		int result;

		if (line[0] == '#' || line[0] == '\n')
			continue;
		if (parse_event(line, &event)) {
			fprintf(stderr, "invalid event at input line %u\n", sequence + 1);
			return 2;
		}
		result = hotdog_radio_reduce(&state, &event, &actions);
		printf("%u phase=%s result=%d actions=", ++sequence,
		       hotdog_radio_phase_name(state.phase), result);
		print_actions(actions);
		printf("\n");
	}
	return 0;
}
