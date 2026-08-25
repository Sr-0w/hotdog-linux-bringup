/* SPDX-License-Identifier: GPL-2.0-only */
#include "hotdog-qmi-voice.h"

#include <errno.h>
#include <string.h>

static bool valid_dtmf(char digit)
{
	return (digit >= '0' && digit <= '9') || digit == '*' || digit == '#' ||
	       (digit >= 'A' && digit <= 'D') || (digit >= 'a' && digit <= 'd');
}

int hotdog_qmi_voice_dial_input(const struct hotdog_call *call,
				QmiMessageVoiceDialCallInput **input)
{
	GError *error = NULL;

	if (!call || !input || call->direction != HOTDOG_CALL_MO ||
	    call->state != HOTDOG_CALL_DIALING || call->transport != HOTDOG_TRANSPORT_CS ||
	    call->video || !call->number[0])
		return -EINVAL;
	*input = qmi_message_voice_dial_call_input_new();
	if (!qmi_message_voice_dial_call_input_set_calling_number(
		    *input, call->number, &error)) {
		g_clear_error(&error);
		qmi_message_voice_dial_call_input_unref(*input);
		*input = NULL;
		return -EINVAL;
	}
	return 0;
}

int hotdog_qmi_voice_decode_dial(QmiMessageVoiceDialCallOutput *output,
				 uint8_t *qmi_call_id, uint16_t *remote_result)
{
	GError *error = NULL;

	if (!output || !qmi_call_id || !remote_result)
		return -EINVAL;
	*qmi_call_id = 0;
	*remote_result = 0;
	if (!qmi_message_voice_dial_call_output_get_result(output, &error)) {
		if (error && error->domain == QMI_PROTOCOL_ERROR)
			*remote_result = (uint16_t)error->code;
		g_clear_error(&error);
		return -EREMOTEIO;
	}
	if (!qmi_message_voice_dial_call_output_get_call_id(output, qmi_call_id, &error) ||
	    !*qmi_call_id) {
		g_clear_error(&error);
		return -ENODATA;
	}
	return 0;
}

int hotdog_qmi_voice_answer_input(uint8_t qmi_call_id,
				  QmiMessageVoiceAnswerCallInput **input)
{
	GError *error = NULL;

	if (!qmi_call_id || !input)
		return -EINVAL;
	*input = qmi_message_voice_answer_call_input_new();
	if (!qmi_message_voice_answer_call_input_set_call_id(*input, qmi_call_id, &error)) {
		g_clear_error(&error);
		qmi_message_voice_answer_call_input_unref(*input);
		*input = NULL;
		return -EINVAL;
	}
	return 0;
}

int hotdog_qmi_voice_end_input(uint8_t qmi_call_id,
			       QmiMessageVoiceEndCallInput **input)
{
	GError *error = NULL;

	if (!qmi_call_id || !input)
		return -EINVAL;
	*input = qmi_message_voice_end_call_input_new();
	if (!qmi_message_voice_end_call_input_set_call_id(*input, qmi_call_id, &error)) {
		g_clear_error(&error);
		qmi_message_voice_end_call_input_unref(*input);
		*input = NULL;
		return -EINVAL;
	}
	return 0;
}

int hotdog_qmi_voice_start_dtmf_input(uint8_t qmi_call_id, char digit,
				      QmiMessageVoiceStartContinuousDtmfInput **input)
{
	GError *error = NULL;

	if (!qmi_call_id || !valid_dtmf(digit) || !input)
		return -EINVAL;
	*input = qmi_message_voice_start_continuous_dtmf_input_new();
	if (!qmi_message_voice_start_continuous_dtmf_input_set_data(
		    *input, qmi_call_id, (guint8)digit, &error)) {
		g_clear_error(&error);
		qmi_message_voice_start_continuous_dtmf_input_unref(*input);
		*input = NULL;
		return -EINVAL;
	}
	return 0;
}

int hotdog_qmi_voice_stop_dtmf_input(uint8_t qmi_call_id,
				     QmiMessageVoiceStopContinuousDtmfInput **input)
{
	GError *error = NULL;

	if (!qmi_call_id || !input)
		return -EINVAL;
	*input = qmi_message_voice_stop_continuous_dtmf_input_new();
	if (!qmi_message_voice_stop_continuous_dtmf_input_set_data(
		    *input, qmi_call_id, &error)) {
		g_clear_error(&error);
		qmi_message_voice_stop_continuous_dtmf_input_unref(*input);
		*input = NULL;
		return -EINVAL;
	}
	return 0;
}

static int map_state(QmiVoiceCallState source, enum hotdog_call_state *state)
{
	switch (source) {
	case QMI_VOICE_CALL_STATE_ORIGINATION:
	case QMI_VOICE_CALL_STATE_CC_IN_PROGRESS:
		*state = HOTDOG_CALL_DIALING;
		return 0;
	case QMI_VOICE_CALL_STATE_ALERTING:
		*state = HOTDOG_CALL_ALERTING;
		return 0;
	case QMI_VOICE_CALL_STATE_INCOMING:
	case QMI_VOICE_CALL_STATE_SETUP:
	case QMI_VOICE_CALL_STATE_WAITING:
		*state = HOTDOG_CALL_INCOMING;
		return 0;
	case QMI_VOICE_CALL_STATE_CONVERSATION:
		*state = HOTDOG_CALL_ACTIVE;
		return 0;
	case QMI_VOICE_CALL_STATE_HOLD:
		*state = HOTDOG_CALL_HELD;
		return 0;
	case QMI_VOICE_CALL_STATE_DISCONNECTING:
		*state = HOTDOG_CALL_DISCONNECTING;
		return 0;
	case QMI_VOICE_CALL_STATE_END:
		*state = HOTDOG_CALL_ENDED;
		return 0;
	case QMI_VOICE_CALL_STATE_UNKNOWN:
		return -EPROTO;
	}
	return -EPROTO;
}

int hotdog_qmi_voice_map_call(
	const QmiIndicationVoiceAllCallStatusOutputCallInformationCall *source,
	unsigned int subscription, struct hotdog_qmi_voice_call *call)
{
	int result;

	if (!source || !call || !source->id ||
	    subscription >= HOTDOG_TELEPHONY_MAX_SUBSCRIPTIONS)
		return -EINVAL;
	memset(call, 0, sizeof(*call));
	switch (source->type) {
	case QMI_VOICE_CALL_TYPE_VOICE:
		call->call.transport = HOTDOG_TRANSPORT_CS;
		break;
	case QMI_VOICE_CALL_TYPE_VOICE_IP:
		call->call.transport = HOTDOG_TRANSPORT_IMS;
		break;
	case QMI_VOICE_CALL_TYPE_EMERGENCY:
		call->call.transport = HOTDOG_TRANSPORT_CS;
		call->call.emergency = true;
		break;
	case QMI_VOICE_CALL_TYPE_OTAPA:
	case QMI_VOICE_CALL_TYPE_NON_STD_OTASP:
	case QMI_VOICE_CALL_TYPE_SUPS:
		return -EOPNOTSUPP;
	default:
		return -EPROTO;
	}
	if (source->direction == QMI_VOICE_CALL_DIRECTION_MO)
		call->call.direction = HOTDOG_CALL_MO;
	else if (source->direction == QMI_VOICE_CALL_DIRECTION_MT)
		call->call.direction = HOTDOG_CALL_MT;
	else
		return -EPROTO;
	result = map_state(source->state, &call->call.state);
	if (result)
		return result;
	call->qmi_call_id = source->id;
	call->mode = source->mode;
	call->call.subscription = subscription;
	return 0;
}

static struct hotdog_qmi_voice_call *find_call(
	struct hotdog_qmi_voice_snapshot *snapshot, uint8_t id)
{
	size_t index;

	for (index = 0; index < snapshot->count; index++)
		if (snapshot->calls[index].qmi_call_id == id)
			return &snapshot->calls[index];
	return NULL;
}

int hotdog_qmi_voice_decode_all_calls(
	QmiIndicationVoiceAllCallStatusOutput *output, unsigned int subscription,
	struct hotdog_qmi_voice_snapshot *snapshot)
{
	bool call_ids[256] = { false };
	bool number_ids[256] = { false };
	GArray *information = NULL, *numbers = NULL;
	GError *error = NULL;
	size_t index;

	if (!output || !snapshot ||
	    subscription >= HOTDOG_TELEPHONY_MAX_SUBSCRIPTIONS)
		return -EINVAL;
	memset(snapshot, 0, sizeof(*snapshot));
	if (!qmi_indication_voice_all_call_status_output_get_call_information(
		    output, &information, &error)) {
		g_clear_error(&error);
		return -ENODATA;
	}
	for (index = 0; index < information->len; index++) {
		const QmiIndicationVoiceAllCallStatusOutputCallInformationCall *source =
			&g_array_index(information,
				QmiIndicationVoiceAllCallStatusOutputCallInformationCall, index);
		int result;

		if (!source->id || call_ids[source->id])
			return -EPROTO;
		call_ids[source->id] = true;
		if (snapshot->count >= HOTDOG_TELEPHONY_MAX_CALLS)
			return -EOVERFLOW;
		result = hotdog_qmi_voice_map_call(
			source, subscription, &snapshot->calls[snapshot->count]);
		if (result == -EOPNOTSUPP)
			continue;
		if (result)
			return result;
		snapshot->count++;
	}
	if (!qmi_indication_voice_all_call_status_output_get_remote_party_number(
		    output, &numbers, NULL))
		return 0;
	for (index = 0; index < numbers->len; index++) {
		const QmiIndicationVoiceAllCallStatusOutputRemotePartyNumberCall *source =
			&g_array_index(numbers,
				QmiIndicationVoiceAllCallStatusOutputRemotePartyNumberCall, index);
		struct hotdog_qmi_voice_call *call = find_call(snapshot, source->id);

		if (!source->id || number_ids[source->id])
			return -EPROTO;
		number_ids[source->id] = true;
		if (!call)
			continue;
		if (call->number_present)
			return -EPROTO;
		if (source->presentation_indicator != QMI_VOICE_PRESENTATION_ALLOWED &&
		    source->presentation_indicator != QMI_VOICE_PRESENTATION_PAYPHONE)
			continue;
		if (!source->type || strlen(source->type) >= sizeof(call->call.number))
			return -EOVERFLOW;
		memcpy(call->call.number, source->type, strlen(source->type) + 1);
		call->number_present = true;
	}
	return 0;
}
