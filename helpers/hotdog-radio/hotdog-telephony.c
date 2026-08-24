/* SPDX-License-Identifier: GPL-2.0-only */
#include "hotdog-telephony.h"

#include <ctype.h>
#include <errno.h>
#include <string.h>

static bool ims_capable(const struct hotdog_telephony_subscription *subscription,
			uint32_t capability)
{
	return subscription->ims.registration == HOTDOG_IMS_REGISTERED &&
	       (subscription->ims.capabilities & capability);
}

static int choose_transport(const struct hotdog_telephony_subscription *subscription,
			    enum hotdog_transport requested, uint32_t ims_capability,
			    bool emergency, enum hotdog_transport *selected)
{
	if (requested > HOTDOG_TRANSPORT_IMS)
		return -EINVAL;
	if (requested == HOTDOG_TRANSPORT_IMS || requested == HOTDOG_TRANSPORT_AUTO) {
		if (ims_capable(subscription, ims_capability)) {
			*selected = HOTDOG_TRANSPORT_IMS;
			return 0;
		}
		if (requested == HOTDOG_TRANSPORT_IMS)
			return -ENETDOWN;
	}
	if (subscription->cs_registered || (emergency && subscription->emergency_available)) {
		*selected = HOTDOG_TRANSPORT_CS;
		return 0;
	}
	return -ENETDOWN;
}

static struct hotdog_sms *find_sms(struct hotdog_telephony *telephony, unsigned int id)
{
	size_t i;

	for (i = 0; i < HOTDOG_TELEPHONY_MAX_SMS; i++)
		if (telephony->messages[i].id == id)
			return &telephony->messages[i];
	return NULL;
}

static struct hotdog_call *find_call(struct hotdog_telephony *telephony, unsigned int id)
{
	size_t i;

	for (i = 0; i < HOTDOG_TELEPHONY_MAX_CALLS; i++)
		if (telephony->calls[i].id == id)
			return &telephony->calls[i];
	return NULL;
}

void hotdog_telephony_init(struct hotdog_telephony *telephony)
{
	memset(telephony, 0, sizeof(*telephony));
	telephony->next_sms_id = 1;
	telephony->next_call_id = 1;
}

int hotdog_telephony_set_subscription(struct hotdog_telephony *telephony,
				      unsigned int subscription, bool populated,
				      bool cs_registered, bool emergency_available)
{
	struct hotdog_telephony_subscription *state;

	if (!telephony || subscription >= HOTDOG_TELEPHONY_MAX_SUBSCRIPTIONS)
		return -EINVAL;
	state = &telephony->subscriptions[subscription];
	if (!populated) {
		memset(state, 0, sizeof(*state));
		return 0;
	}
	state->populated = true;
	state->cs_registered = cs_registered;
	state->emergency_available = emergency_available;
	return 0;
}

int hotdog_telephony_set_ims(struct hotdog_telephony *telephony,
			     unsigned int subscription, enum hotdog_ims_registration registration,
			     enum hotdog_ims_rat rat, uint32_t capabilities,
			     unsigned int sip_code)
{
	struct hotdog_telephony_subscription *state;
	uint32_t known = HOTDOG_IMS_CAP_VOICE | HOTDOG_IMS_CAP_VIDEO | HOTDOG_IMS_CAP_SMS |
			 HOTDOG_IMS_CAP_UT | HOTDOG_IMS_CAP_RCS;

	if (!telephony || subscription >= HOTDOG_TELEPHONY_MAX_SUBSCRIPTIONS ||
	    registration > HOTDOG_IMS_BLOCKED || rat > HOTDOG_IMS_RAT_NR5G ||
	    capabilities & ~known)
		return -EINVAL;
	state = &telephony->subscriptions[subscription];
	if (!state->populated)
		return -ENODEV;
	state->ims.registration = registration;
	state->ims.rat = rat;
	state->ims.capabilities = registration == HOTDOG_IMS_REGISTERED ? capabilities : 0;
	state->ims.sip_code = sip_code;
	return 0;
}

int hotdog_telephony_set_supplementary(struct hotdog_telephony *telephony,
				       unsigned int subscription, bool call_waiting,
				       bool clip, unsigned int clir_mode)
{
	if (!telephony || subscription >= HOTDOG_TELEPHONY_MAX_SUBSCRIPTIONS || clir_mode > 2)
		return -EINVAL;
	if (!telephony->subscriptions[subscription].populated)
		return -ENODEV;
	telephony->subscriptions[subscription].supplementary.call_waiting = call_waiting;
	telephony->subscriptions[subscription].supplementary.clip = clip;
	telephony->subscriptions[subscription].supplementary.clir_mode = clir_mode;
	return 0;
}

int hotdog_sms_submit(struct hotdog_telephony *telephony, unsigned int subscription,
		      enum hotdog_transport requested, unsigned int pdu_bytes,
		      bool delivery_report, unsigned int concat_reference,
		      unsigned int concat_part, unsigned int concat_total,
		      unsigned int *message_id)
{
	struct hotdog_telephony_subscription *service;
	struct hotdog_sms *available = NULL;
	enum hotdog_transport selected;
	size_t i;
	int result;

	if (!telephony || !message_id || subscription >= HOTDOG_TELEPHONY_MAX_SUBSCRIPTIONS ||
	    !pdu_bytes || pdu_bytes > UINT16_MAX ||
	    ((!concat_total && (concat_reference || concat_part)) ||
	     (concat_total && (concat_total < 2 || !concat_part || concat_part > concat_total))))
		return -EINVAL;
	service = &telephony->subscriptions[subscription];
	if (!service->populated)
		return -ENODEV;
	result = choose_transport(service, requested, HOTDOG_IMS_CAP_SMS, false, &selected);
	if (result)
		return result;
	for (i = 0; i < HOTDOG_TELEPHONY_MAX_SMS; i++) {
		if (!telephony->messages[i].id ||
		    telephony->messages[i].state == HOTDOG_SMS_DELIVERED ||
		    telephony->messages[i].state == HOTDOG_SMS_RECEIVED ||
		    telephony->messages[i].state == HOTDOG_SMS_FAILED) {
			available = &telephony->messages[i];
			break;
		}
	}
	if (!available)
		return -ENOSPC;
	memset(available, 0, sizeof(*available));
	available->id = telephony->next_sms_id++;
	available->subscription = subscription;
	available->generation = telephony->generation;
	available->pdu_bytes = pdu_bytes;
	available->delivery_report = delivery_report;
	available->concat_reference = concat_reference;
	available->concat_part = concat_part;
	available->concat_total = concat_total;
	available->transport = selected;
	available->direction = HOTDOG_SMS_MO;
	available->state = HOTDOG_SMS_QUEUED;
	*message_id = available->id;
	return 0;
}

int hotdog_sms_receive(struct hotdog_telephony *telephony, unsigned int subscription,
		       enum hotdog_transport transport, unsigned int pdu_bytes,
		       enum hotdog_sms_storage storage, unsigned int message_reference,
		       unsigned int *message_id)
{
	struct hotdog_telephony_subscription *service;
	struct hotdog_sms *available = NULL;
	size_t i;

	if (!telephony || !message_id || subscription >= HOTDOG_TELEPHONY_MAX_SUBSCRIPTIONS ||
	    transport == HOTDOG_TRANSPORT_AUTO || transport > HOTDOG_TRANSPORT_IMS ||
	    storage > HOTDOG_SMS_STORAGE_MODEM || !pdu_bytes || pdu_bytes > UINT16_MAX)
		return -EINVAL;
	service = &telephony->subscriptions[subscription];
	if (!service->populated)
		return -ENODEV;
	if ((transport == HOTDOG_TRANSPORT_CS && !service->cs_registered) ||
	    (transport == HOTDOG_TRANSPORT_IMS && !ims_capable(service, HOTDOG_IMS_CAP_SMS)))
		return -ENETDOWN;
	for (i = 0; i < HOTDOG_TELEPHONY_MAX_SMS; i++) {
		if (!telephony->messages[i].id ||
		    telephony->messages[i].state == HOTDOG_SMS_DELIVERED ||
		    telephony->messages[i].state == HOTDOG_SMS_RECEIVED ||
		    telephony->messages[i].state == HOTDOG_SMS_FAILED) {
			available = &telephony->messages[i];
			break;
		}
	}
	if (!available)
		return -ENOSPC;
	memset(available, 0, sizeof(*available));
	available->id = telephony->next_sms_id++;
	available->subscription = subscription;
	available->generation = telephony->generation;
	available->pdu_bytes = pdu_bytes;
	available->message_reference = message_reference;
	available->transport = transport;
	available->direction = HOTDOG_SMS_MT;
	available->state = HOTDOG_SMS_RECEIVED;
	available->storage = storage;
	*message_id = available->id;
	return 0;
}

int hotdog_sms_update(struct hotdog_telephony *telephony, unsigned int message_id,
		      enum hotdog_sms_state state, unsigned int message_reference,
		      unsigned int error)
{
	struct hotdog_sms *message;
	bool allowed = false;

	if (!telephony || state > HOTDOG_SMS_FAILED)
		return -EINVAL;
	message = find_sms(telephony, message_id);
	if (!message)
		return -ENOENT;
	if (message->direction != HOTDOG_SMS_MO || message->generation != telephony->generation)
		return -EPROTO;
	switch (message->state) {
	case HOTDOG_SMS_QUEUED:
		allowed = state == HOTDOG_SMS_SUBMITTED || state == HOTDOG_SMS_FAILED;
		break;
	case HOTDOG_SMS_SUBMITTED:
		allowed = state == HOTDOG_SMS_SENT || state == HOTDOG_SMS_FAILED;
		break;
	case HOTDOG_SMS_SENT:
		allowed = state == HOTDOG_SMS_DELIVERED || state == HOTDOG_SMS_FAILED;
		break;
	default:
		break;
	}
	if (!allowed)
		return -EPROTO;
	message->state = state;
	message->message_reference = message_reference;
	message->error = error;
	return 0;
}

static bool valid_number(const char *number)
{
	size_t i;

	if (!number || !*number || strlen(number) >= HOTDOG_TELEPHONY_NUMBER_SIZE)
		return false;
	for (i = number[0] == '+'; number[i]; i++)
		if (!isdigit((unsigned char)number[i]))
			return false;
	return true;
}

static struct hotdog_call *allocate_call(struct hotdog_telephony *telephony)
{
	size_t i;

	for (i = 0; i < HOTDOG_TELEPHONY_MAX_CALLS; i++)
		if (!telephony->calls[i].id || telephony->calls[i].state == HOTDOG_CALL_ENDED)
			return &telephony->calls[i];
	return NULL;
}

int hotdog_call_dial(struct hotdog_telephony *telephony, unsigned int subscription,
		     enum hotdog_transport requested, const char *number,
		     bool emergency, bool video, unsigned int *call_id)
{
	struct hotdog_telephony_subscription *service;
	struct hotdog_call *call;
	enum hotdog_transport selected;
	uint32_t capability = video ? HOTDOG_IMS_CAP_VIDEO : HOTDOG_IMS_CAP_VOICE;
	int result;

	if (!telephony || !call_id || subscription >= HOTDOG_TELEPHONY_MAX_SUBSCRIPTIONS ||
	    !valid_number(number))
		return -EINVAL;
	service = &telephony->subscriptions[subscription];
	if (!service->populated)
		return -ENODEV;
	result = choose_transport(service, requested, capability, emergency, &selected);
	if (result)
		return result;
	if (video && selected != HOTDOG_TRANSPORT_IMS)
		return -EOPNOTSUPP;
	call = allocate_call(telephony);
	if (!call)
		return -ENOSPC;
	memset(call, 0, sizeof(*call));
	call->id = telephony->next_call_id++;
	call->subscription = subscription;
	call->generation = telephony->generation;
	call->transport = selected;
	call->direction = HOTDOG_CALL_MO;
	call->state = HOTDOG_CALL_DIALING;
	call->emergency = emergency;
	call->video = video;
	strcpy(call->number, number);
	*call_id = call->id;
	return 0;
}

int hotdog_call_incoming(struct hotdog_telephony *telephony, unsigned int subscription,
			 enum hotdog_transport transport, const char *number,
			 bool emergency, unsigned int *call_id)
{
	struct hotdog_telephony_subscription *service;
	struct hotdog_call *call;

	if (!telephony || !call_id || subscription >= HOTDOG_TELEPHONY_MAX_SUBSCRIPTIONS ||
	    transport == HOTDOG_TRANSPORT_AUTO || transport > HOTDOG_TRANSPORT_IMS ||
	    !valid_number(number))
		return -EINVAL;
	service = &telephony->subscriptions[subscription];
	if (!service->populated)
		return -ENODEV;
	if ((transport == HOTDOG_TRANSPORT_CS && !service->cs_registered && !emergency) ||
	    (transport == HOTDOG_TRANSPORT_IMS && !ims_capable(service, HOTDOG_IMS_CAP_VOICE)))
		return -ENETDOWN;
	call = allocate_call(telephony);
	if (!call)
		return -ENOSPC;
	memset(call, 0, sizeof(*call));
	call->id = telephony->next_call_id++;
	call->subscription = subscription;
	call->generation = telephony->generation;
	call->transport = transport;
	call->direction = HOTDOG_CALL_MT;
	call->state = HOTDOG_CALL_INCOMING;
	call->emergency = emergency;
	strcpy(call->number, number);
	*call_id = call->id;
	return 0;
}

static bool call_transition_allowed(enum hotdog_call_state from, enum hotdog_call_state to)
{
	switch (from) {
	case HOTDOG_CALL_DIALING:
		return to == HOTDOG_CALL_ALERTING || to == HOTDOG_CALL_ACTIVE ||
		       to == HOTDOG_CALL_DISCONNECTING || to == HOTDOG_CALL_ENDED;
	case HOTDOG_CALL_ALERTING:
	case HOTDOG_CALL_INCOMING:
		return to == HOTDOG_CALL_ACTIVE || to == HOTDOG_CALL_DISCONNECTING ||
		       to == HOTDOG_CALL_ENDED;
	case HOTDOG_CALL_ACTIVE:
		return to == HOTDOG_CALL_HELD || to == HOTDOG_CALL_DISCONNECTING ||
		       to == HOTDOG_CALL_ENDED;
	case HOTDOG_CALL_HELD:
		return to == HOTDOG_CALL_ACTIVE || to == HOTDOG_CALL_DISCONNECTING ||
		       to == HOTDOG_CALL_ENDED;
	case HOTDOG_CALL_DISCONNECTING:
		return to == HOTDOG_CALL_ENDED;
	case HOTDOG_CALL_ENDED:
		return false;
	}
	return false;
}

int hotdog_call_transition(struct hotdog_telephony *telephony, unsigned int call_id,
			   enum hotdog_call_state state)
{
	struct hotdog_call *call;

	if (!telephony || state > HOTDOG_CALL_ENDED)
		return -EINVAL;
	call = find_call(telephony, call_id);
	if (!call)
		return -ENOENT;
	if (call->generation != telephony->generation ||
	    !call_transition_allowed(call->state, state))
		return -EPROTO;
	call->state = state;
	if (state != HOTDOG_CALL_ACTIVE)
		call->audio_ready = false;
	return 0;
}

int hotdog_call_set_audio(struct hotdog_telephony *telephony, unsigned int call_id,
			  bool ready)
{
	struct hotdog_call *call;

	if (!telephony)
		return -EINVAL;
	call = find_call(telephony, call_id);
	if (!call)
		return -ENOENT;
	if (call->state != HOTDOG_CALL_ACTIVE || call->generation != telephony->generation)
		return -EPROTO;
	call->audio_ready = ready;
	return 0;
}

int hotdog_call_dtmf(const struct hotdog_telephony *telephony, unsigned int call_id,
		     char digit)
{
	const struct hotdog_call *call = find_call((struct hotdog_telephony *)telephony, call_id);

	if (!call)
		return -ENOENT;
	if (call->generation != telephony->generation || call->state != HOTDOG_CALL_ACTIVE)
		return -EPROTO;
	return strchr("0123456789*#ABCD", digit) ? 0 : -EINVAL;
}

void hotdog_telephony_ssr(struct hotdog_telephony *telephony)
{
	size_t i;

	if (!telephony)
		return;
	telephony->generation++;
	for (i = 0; i < HOTDOG_TELEPHONY_MAX_SUBSCRIPTIONS; i++) {
		telephony->subscriptions[i].cs_registered = false;
		telephony->subscriptions[i].ims.registration = HOTDOG_IMS_NONE;
		telephony->subscriptions[i].ims.rat = HOTDOG_IMS_RAT_UNKNOWN;
		telephony->subscriptions[i].ims.capabilities = 0;
		telephony->subscriptions[i].ims.sip_code = 0;
	}
	for (i = 0; i < HOTDOG_TELEPHONY_MAX_SMS; i++) {
		struct hotdog_sms *message = &telephony->messages[i];

		if (message->state == HOTDOG_SMS_QUEUED ||
		    message->state == HOTDOG_SMS_SUBMITTED || message->state == HOTDOG_SMS_SENT) {
			message->state = HOTDOG_SMS_FAILED;
			message->error = ENETRESET;
		}
	}
	for (i = 0; i < HOTDOG_TELEPHONY_MAX_CALLS; i++) {
		if (telephony->calls[i].id && telephony->calls[i].state != HOTDOG_CALL_ENDED) {
			telephony->calls[i].state = HOTDOG_CALL_ENDED;
			telephony->calls[i].audio_ready = false;
		}
	}
}

const char *hotdog_transport_name(enum hotdog_transport transport)
{
	static const char *const names[] = { "auto", "cs", "ims" };
	return transport <= HOTDOG_TRANSPORT_IMS ? names[transport] : "invalid";
}

const char *hotdog_sms_state_name(enum hotdog_sms_state state)
{
	static const char *const names[] = {
		"queued", "submitted", "sent", "delivered", "received", "failed",
	};
	return state <= HOTDOG_SMS_FAILED ? names[state] : "invalid";
}

const char *hotdog_call_state_name(enum hotdog_call_state state)
{
	static const char *const names[] = {
		"dialing", "alerting", "incoming", "active", "held", "disconnecting", "ended",
	};
	return state <= HOTDOG_CALL_ENDED ? names[state] : "invalid";
}

const char *hotdog_ims_registration_name(enum hotdog_ims_registration registration)
{
	static const char *const names[] = { "none", "registering", "registered", "blocked" };
	return registration <= HOTDOG_IMS_BLOCKED ? names[registration] : "invalid";
}
