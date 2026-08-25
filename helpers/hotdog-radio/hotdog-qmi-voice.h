/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef HOTDOG_QMI_VOICE_H
#define HOTDOG_QMI_VOICE_H

#include "hotdog-telephony.h"

#include <libqmi-glib.h>

int hotdog_qmi_voice_dial_input(const struct hotdog_call *call,
				QmiMessageVoiceDialCallInput **input);
int hotdog_qmi_voice_decode_dial(QmiMessageVoiceDialCallOutput *output,
				 uint8_t *qmi_call_id, uint16_t *remote_result);
int hotdog_qmi_voice_answer_input(uint8_t qmi_call_id,
				  QmiMessageVoiceAnswerCallInput **input);
int hotdog_qmi_voice_end_input(uint8_t qmi_call_id,
			       QmiMessageVoiceEndCallInput **input);
int hotdog_qmi_voice_start_dtmf_input(uint8_t qmi_call_id, char digit,
				      QmiMessageVoiceStartContinuousDtmfInput **input);
int hotdog_qmi_voice_stop_dtmf_input(uint8_t qmi_call_id,
				     QmiMessageVoiceStopContinuousDtmfInput **input);

#endif
