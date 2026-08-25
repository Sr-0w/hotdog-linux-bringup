/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef HOTDOG_QMI_DMS_H
#define HOTDOG_QMI_DMS_H

#include <libqmi-glib.h>

int hotdog_qmi_dms_decode_operating_mode(QmiMessageDmsGetOperatingModeOutput *output,
					 QmiDmsOperatingMode *mode);
int hotdog_qmi_dms_set_online_input(QmiMessageDmsSetOperatingModeInput **input);
int hotdog_qmi_dms_decode_set_online(QmiMessageDmsSetOperatingModeOutput *output,
				     uint16_t *remote_result);
const char *hotdog_qmi_dms_mode_name(QmiDmsOperatingMode mode);

#endif
