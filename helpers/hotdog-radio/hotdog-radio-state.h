/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef HOTDOG_RADIO_STATE_H
#define HOTDOG_RADIO_STATE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

enum hotdog_radio_phase {
	HOTDOG_RADIO_WAIT_QRTR,
	HOTDOG_RADIO_UIM,
	HOTDOG_RADIO_PDC,
	HOTDOG_RADIO_PDC_SELECTING,
	HOTDOG_RADIO_PDC_ACTIVATING,
	HOTDOG_RADIO_MODEM_SWITCH,
	HOTDOG_RADIO_DMS_ONLINE,
	HOTDOG_RADIO_LOCKED,
	HOTDOG_RADIO_REGISTERING,
	HOTDOG_RADIO_READY,
	HOTDOG_RADIO_RECOVERING,
	HOTDOG_RADIO_BLOCKED,
};

enum hotdog_radio_event_type {
	HOTDOG_EVENT_START,
	HOTDOG_EVENT_QRTR_UP,
	HOTDOG_EVENT_QRTR_DOWN,
	HOTDOG_EVENT_UIM_READY,
	HOTDOG_EVENT_UIM_UNLOCKED,
	HOTDOG_EVENT_PDC_STATUS,
	HOTDOG_EVENT_PDC_SELECTED,
	HOTDOG_EVENT_PDC_ACTIVATED,
	HOTDOG_EVENT_MODEM_SWITCHED,
	HOTDOG_EVENT_DMS_ONLINE,
	HOTDOG_EVENT_HANDOFF_STARTED,
	HOTDOG_EVENT_HANDOFF_STOPPED,
	HOTDOG_EVENT_NAS_REGISTERED,
	HOTDOG_EVENT_NAS_LOST,
	HOTDOG_EVENT_DATA_UP,
	HOTDOG_EVENT_DATA_DOWN,
	HOTDOG_EVENT_SMS_BEGIN,
	HOTDOG_EVENT_SMS_DONE,
	HOTDOG_EVENT_CALL_BEGIN,
	HOTDOG_EVENT_CALL_END,
	HOTDOG_EVENT_IMS_REGISTERED,
	HOTDOG_EVENT_IMS_LOST,
	HOTDOG_EVENT_FATAL,
};

enum hotdog_radio_action {
	HOTDOG_ACTION_NONE = 0,
	HOTDOG_ACTION_DISCOVER_UIM = 1U << 0,
	HOTDOG_ACTION_QUERY_PDC = 1U << 1,
	HOTDOG_ACTION_SELECT_PDC = 1U << 2,
	HOTDOG_ACTION_ACTIVATE_PDC = 1U << 3,
	HOTDOG_ACTION_SWITCH_MODEM = 1U << 4,
	HOTDOG_ACTION_SET_DMS_ONLINE = 1U << 5,
	HOTDOG_ACTION_START_REGISTRATION = 1U << 6,
	HOTDOG_ACTION_PUBLISH_READY = 1U << 7,
	HOTDOG_ACTION_TEARDOWN_DATA = 1U << 8,
	HOTDOG_ACTION_FAIL_SMS = 1U << 9,
	HOTDOG_ACTION_DROP_CALLS = 1U << 10,
	HOTDOG_ACTION_CLEAR_IMS = 1U << 11,
	HOTDOG_ACTION_REJECT_REQUEST = 1U << 12,
	HOTDOG_ACTION_STOP = 1U << 13,
	HOTDOG_ACTION_REVOKE_READY = 1U << 14,
	HOTDOG_ACTION_STOP_MODEMMANAGER = 1U << 15,
};

struct hotdog_radio_event {
	enum hotdog_radio_event_type type;
	uint32_t value;
	uint32_t aux;
};

struct hotdog_radio_state {
	enum hotdog_radio_phase phase;
	uint32_t populated_subscriptions;
	uint32_t unlocked_subscriptions;
	uint32_t active_pdc_subscriptions;
	uint32_t pending_pdc_subscriptions;
	unsigned int restart_count;
	unsigned int restart_limit;
	unsigned int pending_sms;
	unsigned int active_calls;
	bool qrtr_up;
	bool dms_online;
	bool readiness_published;
	bool modemmanager_active;
	bool nas_registered;
	bool data_active;
	bool ims_registered;
};

void hotdog_radio_state_init(struct hotdog_radio_state *state,
			     unsigned int restart_limit);
int hotdog_radio_reduce(struct hotdog_radio_state *state,
			const struct hotdog_radio_event *event,
			uint32_t *actions);
const char *hotdog_radio_phase_name(enum hotdog_radio_phase phase);
const char *hotdog_radio_action_name(enum hotdog_radio_action action);

#endif
