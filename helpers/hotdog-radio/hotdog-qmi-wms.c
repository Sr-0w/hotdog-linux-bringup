/* SPDX-License-Identifier: GPL-2.0-only */
#include "hotdog-qmi-wms.h"

#include <errno.h>
#include <string.h>

int hotdog_wms_classify_3gpp(const unsigned char *pdu, size_t pdu_size,
			     enum hotdog_wms_mt_kind *kind,
			     uint8_t *message_reference,
			     uint8_t *delivery_status)
{
	size_t address_bytes, status_offset, tpdu;
	uint8_t mti;

	if (!pdu || !pdu_size || !kind || !message_reference || !delivery_status)
		return -EINVAL;
	*message_reference = 0;
	*delivery_status = 0;
	if ((size_t)pdu[0] + 1 >= pdu_size)
		return -EPROTO;
	tpdu = (size_t)pdu[0] + 1;
	mti = pdu[tpdu] & 0x03;
	if (mti == 0) {
		*kind = HOTDOG_WMS_MT_DELIVER;
		return 0;
	}
	if (mti != 2)
		return -EOPNOTSUPP;
	if (pdu_size - tpdu < 4 || !pdu[tpdu + 2])
		return -EPROTO;
	address_bytes = ((size_t)pdu[tpdu + 2] + 1) / 2;
	if (address_bytes > pdu_size || tpdu + 4 > pdu_size - address_bytes)
		return -EPROTO;
	status_offset = tpdu + 4 + address_bytes + 14;
	if (status_offset >= pdu_size || pdu[status_offset] > 0x7f)
		return -EPROTO;
	*kind = HOTDOG_WMS_MT_STATUS_REPORT;
	*message_reference = pdu[tpdu + 1];
	*delivery_status = pdu[status_offset];
	return 0;
}

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

int hotdog_qmi_wms_decode_event(
	QmiIndicationWmsEventReportOutput *output, unsigned char *pdu,
	size_t capacity, struct hotdog_wms_incoming *incoming)
{
	QmiWmsAckIndicator ack;
	QmiWmsMessageFormat format;
	QmiWmsMessageMode mode;
	GArray *raw = NULL;
	GError *error = NULL;
	gboolean ims = FALSE;
	guint32 transaction;
	int result;

	if (!output || !pdu || !capacity || !incoming)
		return -EINVAL;
	memset(incoming, 0, sizeof(*incoming));
	if (!qmi_indication_wms_event_report_output_get_transfer_route_mt_message(
		    output, &ack, &transaction, &format, &raw, &error)) {
		g_clear_error(&error);
		return -ENODATA;
	}
	if (format != QMI_WMS_MESSAGE_FORMAT_GSM_WCDMA_POINT_TO_POINT || !raw ||
	    !raw->len || raw->len > capacity)
		return raw && raw->len > capacity ? -EOVERFLOW : -EPROTO;
	if (qmi_indication_wms_event_report_output_get_message_mode(output, &mode, NULL) &&
	    mode != QMI_WMS_MESSAGE_MODE_GSM_WCDMA)
		return -EPROTO;
	result = hotdog_wms_classify_3gpp(
		(const unsigned char *)raw->data, raw->len, &incoming->kind,
		&incoming->message_reference, &incoming->delivery_status);
	if (result)
		return result;
	qmi_indication_wms_event_report_output_get_sms_on_ims(output, &ims, NULL);
	memcpy(pdu, raw->data, raw->len);
	incoming->transaction_id = transaction;
	incoming->pdu_size = raw->len;
	incoming->transport = ims ? HOTDOG_TRANSPORT_IMS : HOTDOG_TRANSPORT_CS;
	incoming->ack_required = ack == QMI_WMS_ACK_INDICATOR_SEND;
	return 0;
}

int hotdog_qmi_wms_ack_input(
	const struct hotdog_wms_incoming *incoming, bool success,
	QmiWmsGsmUmtsRpCause rp_cause, QmiWmsGsmUmtsTpCause tp_cause,
	QmiMessageWmsSendAckInput **input)
{
	GError *error = NULL;
	bool built;

	if (!incoming || !input || !incoming->ack_required || !incoming->transaction_id ||
	    (incoming->transport != HOTDOG_TRANSPORT_CS &&
	     incoming->transport != HOTDOG_TRANSPORT_IMS))
		return -EINVAL;
	*input = qmi_message_wms_send_ack_input_new();
	built = qmi_message_wms_send_ack_input_set_information(
		*input, incoming->transaction_id, QMI_WMS_MESSAGE_PROTOCOL_WCDMA,
		success, &error) &&
		qmi_message_wms_send_ack_input_set_sms_on_ims(
			*input, incoming->transport == HOTDOG_TRANSPORT_IMS, &error);
	if (built && !success)
		built = qmi_message_wms_send_ack_input_set_3gpp_failure_information(
			*input, rp_cause, tp_cause, &error);
	g_clear_error(&error);
	if (!built) {
		qmi_message_wms_send_ack_input_unref(*input);
		*input = NULL;
		return -EINVAL;
	}
	return 0;
}
