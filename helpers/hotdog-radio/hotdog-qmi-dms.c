/* SPDX-License-Identifier: GPL-2.0-only */
#include "hotdog-qmi-dms.h"

#include <errno.h>
#include <stdbool.h>

int hotdog_qmi_dms_decode_operating_mode(QmiMessageDmsGetOperatingModeOutput *output,
					 QmiDmsOperatingMode *mode)
{
	GError *error = NULL;

	if (!output || !mode)
		return -EINVAL;
	if (!qmi_message_dms_get_operating_mode_output_get_result(output, &error)) {
		g_clear_error(&error);
		return -EIO;
	}
	if (!qmi_message_dms_get_operating_mode_output_get_mode(output, mode, &error)) {
		g_clear_error(&error);
		return -ENODATA;
	}
	return 0;
}

int hotdog_qmi_dms_set_online_input(QmiMessageDmsSetOperatingModeInput **input)
{
	GError *error = NULL;
	bool success;

	if (!input)
		return -EINVAL;
	*input = qmi_message_dms_set_operating_mode_input_new();
	success = qmi_message_dms_set_operating_mode_input_set_mode(
		*input, QMI_DMS_OPERATING_MODE_ONLINE, &error);
	g_clear_error(&error);
	if (!success) {
		qmi_message_dms_set_operating_mode_input_unref(*input);
		*input = NULL;
		return -EINVAL;
	}
	return 0;
}

const char *hotdog_qmi_dms_mode_name(QmiDmsOperatingMode mode)
{
	switch (mode) {
	case QMI_DMS_OPERATING_MODE_ONLINE: return "online";
	case QMI_DMS_OPERATING_MODE_LOW_POWER: return "low-power";
	case QMI_DMS_OPERATING_MODE_FACTORY_TEST: return "factory-test";
	case QMI_DMS_OPERATING_MODE_OFFLINE: return "offline";
	case QMI_DMS_OPERATING_MODE_RESET: return "reset";
	case QMI_DMS_OPERATING_MODE_SHUTTING_DOWN: return "shutting-down";
	case QMI_DMS_OPERATING_MODE_PERSISTENT_LOW_POWER: return "persistent-low-power";
	case QMI_DMS_OPERATING_MODE_MODE_ONLY_LOW_POWER: return "mode-only-low-power";
	case QMI_DMS_OPERATING_MODE_UNKNOWN: return "unknown";
	}
	return "invalid";
}
