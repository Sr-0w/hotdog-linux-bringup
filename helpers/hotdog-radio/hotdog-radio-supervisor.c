/* SPDX-License-Identifier: GPL-2.0-only */
#include "hotdog-radio-supervisor.h"

#include <errno.h>
#include <string.h>

void hotdog_radio_supervisor_init(struct hotdog_radio_supervisor *supervisor,
				  unsigned int failure_limit)
{
	memset(supervisor, 0, sizeof(*supervisor));
	supervisor->phase = HOTDOG_SUPERVISOR_WAIT_QRTR;
	supervisor->failure_limit = failure_limit ? failure_limit : 3;
}

static void block(struct hotdog_radio_supervisor *supervisor, uint32_t *actions)
{
	if (supervisor->readiness_valid)
		*actions |= HOTDOG_SUPERVISOR_ACTION_REVOKE_READINESS;
	supervisor->readiness_valid = false;
	if (supervisor->phase == HOTDOG_SUPERVISOR_STARTING_MODEMMANAGER) {
		supervisor->stop_after_start = true;
		supervisor->block_after_stop = true;
		return;
	}
	if (supervisor->modemmanager_active ||
	    supervisor->phase == HOTDOG_SUPERVISOR_STOPPING_MODEMMANAGER) {
		if (supervisor->phase != HOTDOG_SUPERVISOR_STOPPING_MODEMMANAGER)
			*actions |= HOTDOG_SUPERVISOR_ACTION_STOP_MODEMMANAGER;
		supervisor->phase = HOTDOG_SUPERVISOR_STOPPING_MODEMMANAGER;
		supervisor->block_after_stop = true;
		return;
	}
	supervisor->stop_after_start = false;
	supervisor->block_after_stop = false;
	supervisor->phase = HOTDOG_SUPERVISOR_BLOCKED;
}

static void readiness_lost(struct hotdog_radio_supervisor *supervisor,
			   bool revoke, uint32_t *actions)
{
	if (revoke || supervisor->readiness_valid)
		*actions |= HOTDOG_SUPERVISOR_ACTION_REVOKE_READINESS;
	supervisor->readiness_valid = false;
	if (supervisor->phase == HOTDOG_SUPERVISOR_ACTIVE) {
		supervisor->phase = HOTDOG_SUPERVISOR_STOPPING_MODEMMANAGER;
		*actions |= HOTDOG_SUPERVISOR_ACTION_STOP_MODEMMANAGER;
	} else if (supervisor->phase == HOTDOG_SUPERVISOR_STARTING_MODEMMANAGER) {
		supervisor->stop_after_start = true;
	} else if (supervisor->phase != HOTDOG_SUPERVISOR_STOPPING_MODEMMANAGER) {
		supervisor->phase = supervisor->qrtr_up ?
			HOTDOG_SUPERVISOR_WAIT_READINESS : HOTDOG_SUPERVISOR_WAIT_QRTR;
	}
}

int hotdog_radio_supervisor_reduce(struct hotdog_radio_supervisor *supervisor,
				   enum hotdog_supervisor_event event,
				   uint32_t *actions)
{
	if (!supervisor || !actions)
		return -EINVAL;
	*actions = HOTDOG_SUPERVISOR_ACTION_NONE;

	if (event == HOTDOG_SUPERVISOR_FATAL) {
		block(supervisor, actions);
		return 0;
	}
	if (supervisor->phase == HOTDOG_SUPERVISOR_BLOCKED)
		return -ESHUTDOWN;

	switch (event) {
	case HOTDOG_SUPERVISOR_QRTR_UP:
		if (supervisor->qrtr_up)
			return -EALREADY;
		supervisor->qrtr_up = true;
		if (supervisor->phase == HOTDOG_SUPERVISOR_WAIT_QRTR)
			supervisor->phase = HOTDOG_SUPERVISOR_WAIT_READINESS;
		*actions = supervisor->needs_reattest ?
			HOTDOG_SUPERVISOR_ACTION_REATTEST :
			HOTDOG_SUPERVISOR_ACTION_READ_READINESS;
		return 0;
	case HOTDOG_SUPERVISOR_QRTR_DOWN:
		if (!supervisor->qrtr_up)
			return -EALREADY;
		supervisor->qrtr_up = false;
		supervisor->needs_reattest = true;
		supervisor->generation++;
		readiness_lost(supervisor, true, actions);
		return 0;
	case HOTDOG_SUPERVISOR_READINESS_VALID:
		if (!supervisor->qrtr_up)
			return -ENETDOWN;
		if (supervisor->phase != HOTDOG_SUPERVISOR_WAIT_READINESS)
			return supervisor->readiness_valid ? -EALREADY : -EPROTO;
		supervisor->readiness_valid = true;
		supervisor->needs_reattest = false;
		supervisor->phase = HOTDOG_SUPERVISOR_STARTING_MODEMMANAGER;
		*actions = HOTDOG_SUPERVISOR_ACTION_START_MODEMMANAGER;
		return 0;
	case HOTDOG_SUPERVISOR_READINESS_INVALID:
		readiness_lost(supervisor, true, actions);
		return 0;
	case HOTDOG_SUPERVISOR_READINESS_REMOVED:
		readiness_lost(supervisor, false, actions);
		return 0;
	case HOTDOG_SUPERVISOR_MODEMMANAGER_STARTED:
		if (supervisor->phase != HOTDOG_SUPERVISOR_STARTING_MODEMMANAGER)
			return -EPROTO;
		supervisor->modemmanager_active = true;
		if (!supervisor->qrtr_up || !supervisor->readiness_valid ||
		    supervisor->stop_after_start) {
			supervisor->phase = HOTDOG_SUPERVISOR_STOPPING_MODEMMANAGER;
			supervisor->stop_after_start = false;
			*actions = HOTDOG_SUPERVISOR_ACTION_STOP_MODEMMANAGER;
		} else {
			supervisor->phase = HOTDOG_SUPERVISOR_ACTIVE;
			supervisor->failure_count = 0;
		}
		return 0;
	case HOTDOG_SUPERVISOR_MODEMMANAGER_START_FAILED:
		if (supervisor->phase != HOTDOG_SUPERVISOR_STARTING_MODEMMANAGER)
			return -EPROTO;
		supervisor->stop_after_start = false;
		supervisor->failure_count++;
		if (supervisor->failure_count > supervisor->failure_limit) {
			supervisor->phase = HOTDOG_SUPERVISOR_WAIT_READINESS;
			block(supervisor, actions);
		} else
			supervisor->phase = supervisor->qrtr_up ?
				HOTDOG_SUPERVISOR_WAIT_READINESS : HOTDOG_SUPERVISOR_WAIT_QRTR;
		return 0;
	case HOTDOG_SUPERVISOR_MODEMMANAGER_STOPPED:
		if (supervisor->phase != HOTDOG_SUPERVISOR_STOPPING_MODEMMANAGER)
			return -EPROTO;
		supervisor->modemmanager_active = false;
		supervisor->stop_after_start = false;
		if (supervisor->block_after_stop) {
			supervisor->block_after_stop = false;
			supervisor->phase = HOTDOG_SUPERVISOR_BLOCKED;
			return 0;
		}
		supervisor->phase = supervisor->qrtr_up ?
			HOTDOG_SUPERVISOR_WAIT_READINESS : HOTDOG_SUPERVISOR_WAIT_QRTR;
		if (supervisor->qrtr_up)
			*actions = supervisor->needs_reattest ?
				HOTDOG_SUPERVISOR_ACTION_REATTEST :
				HOTDOG_SUPERVISOR_ACTION_READ_READINESS;
		return 0;
	case HOTDOG_SUPERVISOR_MODEMMANAGER_STOP_FAILED:
		if (supervisor->phase != HOTDOG_SUPERVISOR_STOPPING_MODEMMANAGER)
			return -EPROTO;
		if (supervisor->readiness_valid)
			*actions |= HOTDOG_SUPERVISOR_ACTION_REVOKE_READINESS;
		supervisor->readiness_valid = false;
		supervisor->block_after_stop = false;
		supervisor->phase = HOTDOG_SUPERVISOR_BLOCKED;
		return 0;
	case HOTDOG_SUPERVISOR_RETRY:
		if (!supervisor->qrtr_up ||
		    supervisor->phase != HOTDOG_SUPERVISOR_WAIT_READINESS)
			return -EPROTO;
		*actions = supervisor->needs_reattest ?
			HOTDOG_SUPERVISOR_ACTION_REATTEST :
			HOTDOG_SUPERVISOR_ACTION_READ_READINESS;
		return 0;
	case HOTDOG_SUPERVISOR_FATAL:
		break;
	}
	return -EINVAL;
}

const char *hotdog_supervisor_phase_name(enum hotdog_supervisor_phase phase)
{
	static const char *const names[] = {
		"wait-qrtr", "wait-readiness", "starting-modemmanager", "active",
		"stopping-modemmanager", "blocked",
	};

	return phase <= HOTDOG_SUPERVISOR_BLOCKED ? names[phase] : "invalid";
}

const char *hotdog_supervisor_action_name(enum hotdog_supervisor_action action)
{
	switch (action) {
	case HOTDOG_SUPERVISOR_ACTION_READ_READINESS: return "read-readiness";
	case HOTDOG_SUPERVISOR_ACTION_REATTEST: return "reattest";
	case HOTDOG_SUPERVISOR_ACTION_START_MODEMMANAGER: return "start-modemmanager";
	case HOTDOG_SUPERVISOR_ACTION_STOP_MODEMMANAGER: return "stop-modemmanager";
	case HOTDOG_SUPERVISOR_ACTION_REVOKE_READINESS: return "revoke-readiness";
	case HOTDOG_SUPERVISOR_ACTION_NONE: break;
	}
	return "none";
}
