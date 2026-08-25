/* SPDX-License-Identifier: GPL-2.0-only */
#include "hotdog-qmi-wms.h"

#include <errno.h>

int hotdog_qmi_wms_raw_send_input(
	const struct hotdog_sms *message, const unsigned char *pdu, size_t pdu_size,
	QmiMessageWmsRawSendInput **input)
{
	GArray *raw;
	GError *error = NULL;
	bool success;

	if (!message || !pdu || !pdu_size || pdu_size != message->pdu_bytes ||
	    pdu_size > UINT16_MAX || !input || message->direction != HOTDOG_SMS_MO ||
	    message->state != HOTDOG_SMS_QUEUED ||
	    (message->transport != HOTDOG_TRANSPORT_CS &&
	     message->transport != HOTDOG_TRANSPORT_IMS))
		return -EINVAL;
	raw = g_array_sized_new(FALSE, FALSE, sizeof(guint8), pdu_size);
	g_array_append_vals(raw, pdu, pdu_size);
	*input = qmi_message_wms_raw_send_input_new();
	success = qmi_message_wms_raw_send_input_set_raw_message_data(
		*input, QMI_WMS_MESSAGE_FORMAT_GSM_WCDMA_POINT_TO_POINT, raw, &error) &&
		qmi_message_wms_raw_send_input_set_sms_on_ims(
			*input, message->transport == HOTDOG_TRANSPORT_IMS, &error);
	g_array_unref(raw);
	g_clear_error(&error);
	if (!success) {
		qmi_message_wms_raw_send_input_unref(*input);
		*input = NULL;
		return -EINVAL;
	}
	return 0;
}

int hotdog_qmi_wms_decode_raw_send(
	QmiMessageWmsRawSendOutput *output, uint16_t *message_reference,
	uint16_t *remote_result, uint16_t *network_error)
{
	GError *error = NULL;
	QmiWmsGsmUmtsRpCause rp_cause = 0;
	QmiWmsGsmUmtsTpCause tp_cause = 0;

	if (!output || !message_reference || !remote_result || !network_error)
		return -EINVAL;
	*message_reference = 0;
	*remote_result = 0;
	*network_error = 0;
	if (!qmi_message_wms_raw_send_output_get_result(output, &error)) {
		if (error && error->domain == QMI_PROTOCOL_ERROR)
			*remote_result = (uint16_t)error->code;
		qmi_message_wms_raw_send_output_get_gsm_wcdma_cause_info(
			output, &rp_cause, &tp_cause, NULL);
		*network_error = ((uint16_t)rp_cause << 8) | tp_cause;
		g_clear_error(&error);
		return -EREMOTEIO;
	}
	if (!qmi_message_wms_raw_send_output_get_message_id(
		    output, message_reference, &error)) {
		g_clear_error(&error);
		return -ENODATA;
	}
	return 0;
}
