/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef HOTDOG_QMI_PDC_H
#define HOTDOG_QMI_PDC_H

#include "hotdog-pdc.h"

#include <libqmi-glib.h>

/* These generated setters are carried by the local libqmi patch. Repeating
 * their declarations keeps host-side syntax/unit builds usable with stock
 * libqmi headers; the packaged binary still requires the patched symbols. */
gboolean qmi_message_pdc_get_selected_config_input_set_subscription_id(
	QmiMessagePdcGetSelectedConfigInput *input, guint32 value, GError **error);
gboolean qmi_message_pdc_set_selected_config_input_set_subscription_id(
	QmiMessagePdcSetSelectedConfigInput *input, guint32 value, GError **error);
gboolean qmi_message_pdc_activate_config_input_set_subscription_id(
	QmiMessagePdcActivateConfigInput *input, guint32 value, GError **error);
gboolean qmi_message_pdc_deactivate_config_input_set_subscription_id(
	QmiMessagePdcDeactivateConfigInput *input, guint32 value, GError **error);

int hotdog_qmi_pdc_get_selected_input(unsigned int subscription, uint32_t token,
				      QmiMessagePdcGetSelectedConfigInput **input);
int hotdog_qmi_pdc_set_selected_input(unsigned int subscription, uint32_t token,
				      const struct hotdog_pdc_id *id,
				      QmiMessagePdcSetSelectedConfigInput **input);
int hotdog_qmi_pdc_activate_input(unsigned int subscription, uint32_t token,
				  QmiMessagePdcActivateConfigInput **input);
int hotdog_qmi_pdc_deactivate_input(unsigned int subscription, uint32_t token,
				    QmiMessagePdcDeactivateConfigInput **input);
int hotdog_qmi_pdc_decode_selected(QmiIndicationPdcGetSelectedConfigOutput *output,
				   uint32_t expected_token,
				   struct hotdog_pdc_id *active,
				   struct hotdog_pdc_id *pending,
				   uint16_t *remote_result);
int hotdog_qmi_pdc_decode_set_selected(
	QmiIndicationPdcSetSelectedConfigOutput *output, uint32_t expected_token,
	uint16_t *remote_result);
int hotdog_qmi_pdc_decode_activate(QmiIndicationPdcActivateConfigOutput *output,
				   uint32_t expected_token,
				   uint16_t *remote_result);
int hotdog_qmi_pdc_decode_deactivate(QmiIndicationPdcDeactivateConfigOutput *output,
				     uint32_t expected_token,
				     uint16_t *remote_result);
int hotdog_qmi_pdc_decode_delete(QmiMessagePdcDeleteConfigOutput *output,
				 uint32_t expected_token,
				 uint16_t *remote_result);

#endif
