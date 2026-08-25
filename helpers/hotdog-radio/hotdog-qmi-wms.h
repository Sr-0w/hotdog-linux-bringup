/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef HOTDOG_QMI_WMS_H
#define HOTDOG_QMI_WMS_H

#include "hotdog-telephony.h"

#include <libqmi-glib.h>

struct hotdog_wms_incoming {
	uint32_t transaction_id;
	size_t pdu_size;
	enum hotdog_transport transport;
	bool ack_required;
};

int hotdog_qmi_wms_raw_send_input(
	const struct hotdog_sms *message, const unsigned char *pdu, size_t pdu_size,
	QmiMessageWmsRawSendInput **input);
int hotdog_qmi_wms_decode_raw_send(
	QmiMessageWmsRawSendOutput *output, uint16_t *message_reference,
	uint16_t *remote_result, uint16_t *network_error);
int hotdog_qmi_wms_decode_event(
	QmiIndicationWmsEventReportOutput *output, unsigned char *pdu,
	size_t capacity, struct hotdog_wms_incoming *incoming);
int hotdog_qmi_wms_ack_input(
	const struct hotdog_wms_incoming *incoming, bool success,
	QmiWmsGsmUmtsRpCause rp_cause, QmiWmsGsmUmtsTpCause tp_cause,
	QmiMessageWmsSendAckInput **input);

#endif
