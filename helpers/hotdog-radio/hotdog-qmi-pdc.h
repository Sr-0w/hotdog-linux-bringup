/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef HOTDOG_QMI_PDC_H
#define HOTDOG_QMI_PDC_H

#include "hotdog-pdc.h"

#include <libqmi-glib.h>

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

#endif
