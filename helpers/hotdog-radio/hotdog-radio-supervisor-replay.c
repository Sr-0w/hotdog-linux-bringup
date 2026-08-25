/* SPDX-License-Identifier: GPL-2.0-only */
#include "hotdog-radio-supervisor.h"

#include <stdio.h>
#include <string.h>

struct event_name {
	const char *name;
	enum hotdog_supervisor_event event;
};

static const struct event_name events[] = {
	{ "QRTR_UP", HOTDOG_SUPERVISOR_QRTR_UP },
	{ "QRTR_DOWN", HOTDOG_SUPERVISOR_QRTR_DOWN },
	{ "READY", HOTDOG_SUPERVISOR_READINESS_VALID },
	{ "INVALID", HOTDOG_SUPERVISOR_READINESS_INVALID },
	{ "REMOVED", HOTDOG_SUPERVISOR_READINESS_REMOVED },
	{ "MM_STARTED", HOTDOG_SUPERVISOR_MODEMMANAGER_STARTED },
	{ "MM_START_FAILED", HOTDOG_SUPERVISOR_MODEMMANAGER_START_FAILED },
	{ "MM_STOPPED", HOTDOG_SUPERVISOR_MODEMMANAGER_STOPPED },
	{ "MM_STOP_FAILED", HOTDOG_SUPERVISOR_MODEMMANAGER_STOP_FAILED },
	{ "RETRY", HOTDOG_SUPERVISOR_RETRY },
	{ "FATAL", HOTDOG_SUPERVISOR_FATAL },
};

static void print_actions(uint32_t actions)
{
	unsigned int bit;
	bool first = true;

	for (bit = 0; bit < 32; bit++) {
		enum hotdog_supervisor_action action = 1U << bit;

		if (!(actions & action))
			continue;
		printf("%s%s", first ? "" : ",",
		       hotdog_supervisor_action_name(action));
		first = false;
	}
	if (first)
		printf("none");
}

int main(void)
{
	struct hotdog_radio_supervisor supervisor;
	char line[128];

	hotdog_radio_supervisor_init(&supervisor, 3);
	while (fgets(line, sizeof(line), stdin)) {
		size_t index;
		bool found = false;

		line[strcspn(line, "\r\n")] = '\0';
		if (!line[0] || line[0] == '#')
			continue;
		for (index = 0; index < sizeof(events) / sizeof(events[0]); index++) {
			uint32_t actions;
			int result;

			if (strcmp(line, events[index].name))
				continue;
			result = hotdog_radio_supervisor_reduce(
				&supervisor, events[index].event, &actions);
			printf("phase=%s result=%d generation=%u actions=",
			       hotdog_supervisor_phase_name(supervisor.phase), result,
			       supervisor.generation);
			print_actions(actions);
			printf("\n");
			found = true;
			break;
		}
		if (!found) {
			fprintf(stderr, "invalid supervisor event: %s\n", line);
			return 2;
		}
	}
	return 0;
}
