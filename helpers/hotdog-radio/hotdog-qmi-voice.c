/* SPDX-License-Identifier: GPL-2.0-only */
#include "hotdog-qmi-voice.h"

#include <errno.h>

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
