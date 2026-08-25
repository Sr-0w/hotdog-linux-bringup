/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef HOTDOG_RADIO_SUPERVISOR_H
#define HOTDOG_RADIO_SUPERVISOR_H

#include <stdbool.h>
#include <stdint.h>

enum hotdog_supervisor_phase {
	HOTDOG_SUPERVISOR_WAIT_QRTR,
	HOTDOG_SUPERVISOR_WAIT_READINESS,
	HOTDOG_SUPERVISOR_STARTING_MODEMMANAGER,
	HOTDOG_SUPERVISOR_ACTIVE,
	HOTDOG_SUPERVISOR_STOPPING_MODEMMANAGER,
	HOTDOG_SUPERVISOR_BLOCKED,
};

enum hotdog_supervisor_event {
	HOTDOG_SUPERVISOR_QRTR_UP,
	HOTDOG_SUPERVISOR_QRTR_DOWN,
	HOTDOG_SUPERVISOR_READINESS_VALID,
	HOTDOG_SUPERVISOR_READINESS_INVALID,
	HOTDOG_SUPERVISOR_READINESS_REMOVED,
	HOTDOG_SUPERVISOR_MODEMMANAGER_STARTED,
	HOTDOG_SUPERVISOR_MODEMMANAGER_START_FAILED,
	HOTDOG_SUPERVISOR_MODEMMANAGER_STOPPED,
	HOTDOG_SUPERVISOR_MODEMMANAGER_STOP_FAILED,
	HOTDOG_SUPERVISOR_RETRY,
	HOTDOG_SUPERVISOR_FATAL,
};

enum hotdog_supervisor_action {
	HOTDOG_SUPERVISOR_ACTION_NONE = 0,
	HOTDOG_SUPERVISOR_ACTION_READ_READINESS = 1U << 0,
	HOTDOG_SUPERVISOR_ACTION_REATTEST = 1U << 1,
	HOTDOG_SUPERVISOR_ACTION_START_MODEMMANAGER = 1U << 2,
	HOTDOG_SUPERVISOR_ACTION_STOP_MODEMMANAGER = 1U << 3,
	HOTDOG_SUPERVISOR_ACTION_REVOKE_READINESS = 1U << 4,
};

struct hotdog_radio_supervisor {
	enum hotdog_supervisor_phase phase;
	unsigned int generation;
	unsigned int failure_count;
	unsigned int failure_limit;
	bool qrtr_up;
	bool readiness_valid;
	bool modemmanager_active;
	bool stop_after_start;
	bool block_after_stop;
	bool needs_reattest;
};

void hotdog_radio_supervisor_init(struct hotdog_radio_supervisor *supervisor,
				  unsigned int failure_limit);
int hotdog_radio_supervisor_reduce(struct hotdog_radio_supervisor *supervisor,
				   enum hotdog_supervisor_event event,
				   uint32_t *actions);
const char *hotdog_supervisor_phase_name(enum hotdog_supervisor_phase phase);
const char *hotdog_supervisor_action_name(enum hotdog_supervisor_action action);

#endif
