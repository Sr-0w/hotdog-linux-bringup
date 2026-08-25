/* SPDX-License-Identifier: GPL-2.0-only */
#include "hotdog-radio-state.h"

#include <errno.h>
#include <string.h>

static bool subscriptions_ready(const struct hotdog_radio_state *state,
				uint32_t available)
{
	return state->populated_subscriptions &&
	       (available & state->populated_subscriptions) == state->populated_subscriptions;
}

static void clear_runtime(struct hotdog_radio_state *state, uint32_t *actions)
{
	if (state->readiness_published)
		*actions |= HOTDOG_ACTION_REVOKE_READY;
	if (state->modemmanager_active)
		*actions |= HOTDOG_ACTION_STOP_MODEMMANAGER;
	if (state->data_active)
		*actions |= HOTDOG_ACTION_TEARDOWN_DATA;
	if (state->pending_sms)
		*actions |= HOTDOG_ACTION_FAIL_SMS;
	if (state->active_calls)
		*actions |= HOTDOG_ACTION_DROP_CALLS;
	if (state->ims_registered)
		*actions |= HOTDOG_ACTION_CLEAR_IMS;
	state->dms_online = false;
	state->readiness_published = false;
	state->modemmanager_active = false;
	state->nas_registered = false;
	state->data_active = false;
	state->ims_registered = false;
	state->pending_sms = 0;
	state->active_calls = 0;
}

void hotdog_radio_state_init(struct hotdog_radio_state *state,
			     unsigned int restart_limit)
{
	memset(state, 0, sizeof(*state));
	state->phase = HOTDOG_RADIO_WAIT_QRTR;
	state->restart_limit = restart_limit ? restart_limit : 3;
}

int hotdog_radio_reduce(struct hotdog_radio_state *state,
			const struct hotdog_radio_event *event,
			uint32_t *actions)
{
	if (!state || !event || !actions)
		return -EINVAL;
	*actions = HOTDOG_ACTION_NONE;

	if (event->type == HOTDOG_EVENT_QRTR_DOWN) {
		state->qrtr_up = false;
		clear_runtime(state, actions);
		if (state->phase == HOTDOG_RADIO_MODEM_SWITCH) {
			state->phase = HOTDOG_RADIO_RECOVERING;
			return 0;
		}
		state->restart_count++;
		if (state->restart_count > state->restart_limit) {
			state->phase = HOTDOG_RADIO_BLOCKED;
			*actions |= HOTDOG_ACTION_STOP;
		} else {
			state->phase = HOTDOG_RADIO_RECOVERING;
		}
		return 0;
	}

	if (event->type == HOTDOG_EVENT_FATAL) {
		clear_runtime(state, actions);
		state->phase = HOTDOG_RADIO_BLOCKED;
		*actions |= HOTDOG_ACTION_STOP;
		return 0;
	}

	switch (event->type) {
	case HOTDOG_EVENT_START:
		return state->phase == HOTDOG_RADIO_WAIT_QRTR ? 0 : -EALREADY;
	case HOTDOG_EVENT_QRTR_UP:
		if (state->phase != HOTDOG_RADIO_WAIT_QRTR &&
		    state->phase != HOTDOG_RADIO_RECOVERING)
			return -EPROTO;
		state->qrtr_up = true;
		state->phase = HOTDOG_RADIO_UIM;
		*actions = HOTDOG_ACTION_DISCOVER_UIM;
		return 0;
	case HOTDOG_EVENT_UIM_READY:
		if (state->phase != HOTDOG_RADIO_UIM)
			return -EPROTO;
		state->populated_subscriptions = event->value;
		state->unlocked_subscriptions = event->aux;
		if (!state->populated_subscriptions)
			return -ENODEV;
		state->phase = HOTDOG_RADIO_PDC;
		*actions = HOTDOG_ACTION_QUERY_PDC;
		return 0;
	case HOTDOG_EVENT_PDC_STATUS:
		if (state->phase != HOTDOG_RADIO_PDC)
			return -EPROTO;
		state->active_pdc_subscriptions = event->value;
		state->pending_pdc_subscriptions = event->aux;
		if (subscriptions_ready(state, state->active_pdc_subscriptions)) {
			state->phase = HOTDOG_RADIO_DMS_ONLINE;
			*actions = HOTDOG_ACTION_SET_DMS_ONLINE;
		} else if (state->pending_pdc_subscriptions & state->populated_subscriptions) {
			state->phase = HOTDOG_RADIO_PDC_ACTIVATING;
			*actions = HOTDOG_ACTION_ACTIVATE_PDC;
		} else {
			state->phase = HOTDOG_RADIO_PDC_SELECTING;
			*actions = HOTDOG_ACTION_SELECT_PDC;
		}
		return 0;
	case HOTDOG_EVENT_PDC_SELECTED:
		if (state->phase != HOTDOG_RADIO_PDC_SELECTING)
			return -EPROTO;
		state->pending_pdc_subscriptions = event->value;
		if (!subscriptions_ready(state, state->pending_pdc_subscriptions))
			return -ENODATA;
		state->phase = HOTDOG_RADIO_PDC_ACTIVATING;
		*actions = HOTDOG_ACTION_ACTIVATE_PDC;
		return 0;
	case HOTDOG_EVENT_PDC_ACTIVATED:
		if (state->phase != HOTDOG_RADIO_PDC_ACTIVATING)
			return -EPROTO;
		state->active_pdc_subscriptions = event->value;
		if (!subscriptions_ready(state, state->active_pdc_subscriptions))
			return -ENODATA;
		state->phase = HOTDOG_RADIO_MODEM_SWITCH;
		*actions = HOTDOG_ACTION_SWITCH_MODEM;
		return 0;
	case HOTDOG_EVENT_MODEM_SWITCHED:
		if (state->phase != HOTDOG_RADIO_MODEM_SWITCH)
			return -EPROTO;
		state->phase = HOTDOG_RADIO_PDC;
		*actions = HOTDOG_ACTION_QUERY_PDC;
		return 0;
	case HOTDOG_EVENT_DMS_ONLINE:
		if (state->phase != HOTDOG_RADIO_DMS_ONLINE ||
		    !subscriptions_ready(state, state->active_pdc_subscriptions))
			return -EPROTO;
		state->dms_online = true;
		state->readiness_published = true;
		if (subscriptions_ready(state, state->unlocked_subscriptions)) {
			state->phase = HOTDOG_RADIO_REGISTERING;
			*actions = HOTDOG_ACTION_PUBLISH_READY |
				HOTDOG_ACTION_START_REGISTRATION;
		} else {
			state->phase = HOTDOG_RADIO_LOCKED;
			*actions = HOTDOG_ACTION_PUBLISH_READY;
		}
		return 0;
	case HOTDOG_EVENT_HANDOFF_STARTED:
		if (!state->qrtr_up || !state->dms_online ||
		    !state->readiness_published || state->modemmanager_active)
			return -EPROTO;
		state->modemmanager_active = true;
		return 0;
	case HOTDOG_EVENT_HANDOFF_STOPPED:
		if (!state->modemmanager_active)
			return -ENOENT;
		state->modemmanager_active = false;
		return 0;
	case HOTDOG_EVENT_UIM_UNLOCKED:
		state->unlocked_subscriptions |= event->value;
		if (state->phase == HOTDOG_RADIO_LOCKED &&
		    subscriptions_ready(state, state->unlocked_subscriptions)) {
			state->phase = HOTDOG_RADIO_REGISTERING;
			*actions = HOTDOG_ACTION_PUBLISH_READY |
				HOTDOG_ACTION_START_REGISTRATION;
		}
		return 0;
	case HOTDOG_EVENT_NAS_REGISTERED:
		if (state->phase != HOTDOG_RADIO_REGISTERING)
			return -EPROTO;
		state->nas_registered = true;
		state->restart_count = 0;
		state->phase = HOTDOG_RADIO_READY;
		*actions = HOTDOG_ACTION_PUBLISH_READY;
		return 0;
	case HOTDOG_EVENT_NAS_LOST:
		state->nas_registered = false;
		state->data_active = false;
		state->ims_registered = false;
		if (state->phase == HOTDOG_RADIO_READY) {
			state->phase = HOTDOG_RADIO_REGISTERING;
			*actions = HOTDOG_ACTION_PUBLISH_READY;
		}
		return 0;
	case HOTDOG_EVENT_DATA_UP:
		if (state->phase != HOTDOG_RADIO_READY || !state->nas_registered) {
			*actions = HOTDOG_ACTION_REJECT_REQUEST;
			return -EHOSTDOWN;
		}
		state->data_active = true;
		return 0;
	case HOTDOG_EVENT_DATA_DOWN:
		state->data_active = false;
		return 0;
	case HOTDOG_EVENT_SMS_BEGIN:
		if (state->phase != HOTDOG_RADIO_READY || !state->nas_registered) {
			*actions = HOTDOG_ACTION_REJECT_REQUEST;
			return -EHOSTDOWN;
		}
		state->pending_sms++;
		return 0;
	case HOTDOG_EVENT_SMS_DONE:
		if (!state->pending_sms)
			return -ENOENT;
		state->pending_sms--;
		return 0;
	case HOTDOG_EVENT_CALL_BEGIN:
		if (state->phase != HOTDOG_RADIO_READY || !state->nas_registered) {
			*actions = HOTDOG_ACTION_REJECT_REQUEST;
			return -EHOSTDOWN;
		}
		state->active_calls++;
		return 0;
	case HOTDOG_EVENT_CALL_END:
		if (!state->active_calls)
			return -ENOENT;
		state->active_calls--;
		return 0;
	case HOTDOG_EVENT_IMS_REGISTERED:
		if (state->phase != HOTDOG_RADIO_READY || !state->nas_registered)
			return -EHOSTDOWN;
		state->ims_registered = true;
		return 0;
	case HOTDOG_EVENT_IMS_LOST:
		state->ims_registered = false;
		return 0;
	case HOTDOG_EVENT_QRTR_DOWN:
	case HOTDOG_EVENT_FATAL:
		break;
	}
	return -EINVAL;
}

const char *hotdog_radio_phase_name(enum hotdog_radio_phase phase)
{
	static const char *const names[] = {
		[HOTDOG_RADIO_WAIT_QRTR] = "wait-qrtr",
		[HOTDOG_RADIO_UIM] = "uim",
		[HOTDOG_RADIO_PDC] = "pdc",
		[HOTDOG_RADIO_PDC_SELECTING] = "pdc-selecting",
		[HOTDOG_RADIO_PDC_ACTIVATING] = "pdc-activating",
		[HOTDOG_RADIO_MODEM_SWITCH] = "modem-switch",
		[HOTDOG_RADIO_DMS_ONLINE] = "dms-online",
		[HOTDOG_RADIO_LOCKED] = "locked",
		[HOTDOG_RADIO_REGISTERING] = "registering",
		[HOTDOG_RADIO_READY] = "ready",
		[HOTDOG_RADIO_RECOVERING] = "recovering",
		[HOTDOG_RADIO_BLOCKED] = "blocked",
	};
	return phase < (sizeof(names) / sizeof(names[0])) ? names[phase] : "invalid";
}

const char *hotdog_radio_action_name(enum hotdog_radio_action action)
{
	switch (action) {
	case HOTDOG_ACTION_DISCOVER_UIM: return "discover-uim";
	case HOTDOG_ACTION_QUERY_PDC: return "query-pdc";
	case HOTDOG_ACTION_SELECT_PDC: return "select-pdc";
	case HOTDOG_ACTION_ACTIVATE_PDC: return "activate-pdc";
	case HOTDOG_ACTION_SWITCH_MODEM: return "switch-modem";
	case HOTDOG_ACTION_SET_DMS_ONLINE: return "set-dms-online";
	case HOTDOG_ACTION_START_REGISTRATION: return "start-registration";
	case HOTDOG_ACTION_PUBLISH_READY: return "publish-ready";
	case HOTDOG_ACTION_TEARDOWN_DATA: return "teardown-data";
	case HOTDOG_ACTION_FAIL_SMS: return "fail-sms";
	case HOTDOG_ACTION_DROP_CALLS: return "drop-calls";
	case HOTDOG_ACTION_CLEAR_IMS: return "clear-ims";
	case HOTDOG_ACTION_REJECT_REQUEST: return "reject-request";
	case HOTDOG_ACTION_STOP: return "stop";
	case HOTDOG_ACTION_REVOKE_READY: return "revoke-ready";
	case HOTDOG_ACTION_STOP_MODEMMANAGER: return "stop-modemmanager";
	case HOTDOG_ACTION_NONE: break;
	}
	return "none";
}
