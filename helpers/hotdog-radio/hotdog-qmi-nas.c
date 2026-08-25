/* SPDX-License-Identifier: GPL-2.0-only */
#include "hotdog-qmi-nas.h"

#include <errno.h>
#include <string.h>

int hotdog_qmi_nas_decode_serving_system(
	QmiMessageNasGetServingSystemOutput *output,
	struct hotdog_nas_snapshot *snapshot)
{
	GArray *interfaces = NULL;
	GError *error = NULL;
	size_t index;

	if (!output || !snapshot)
		return -EINVAL;
	memset(snapshot, 0, sizeof(*snapshot));
	if (!qmi_message_nas_get_serving_system_output_get_result(output, &error)) {
		g_clear_error(&error);
		return -EIO;
	}
	if (!qmi_message_nas_get_serving_system_output_get_serving_system(
		    output, &snapshot->registration, &snapshot->cs_attach,
		    &snapshot->ps_attach, &snapshot->network, &interfaces, &error)) {
		g_clear_error(&error);
		return -ENODATA;
	}
	if (!interfaces || interfaces->len > HOTDOG_NAS_MAX_INTERFACES)
		return -EOVERFLOW;
	for (index = 0; index < interfaces->len; index++)
		snapshot->interfaces[index] = g_array_index(
			interfaces, QmiNasRadioInterface, index);
	snapshot->interface_count = interfaces->len;
	snapshot->roaming_valid =
		qmi_message_nas_get_serving_system_output_get_roaming_indicator(
			output, &snapshot->roaming, NULL);
	return 0;
}

const char *hotdog_qmi_nas_registration_name(QmiNasRegistrationState state)
{
	const char *name = qmi_nas_registration_state_get_string(state);

	return name ? name : "invalid";
}

const char *hotdog_qmi_nas_attach_name(QmiNasAttachState state)
{
	const char *name = qmi_nas_attach_state_get_string(state);

	return name ? name : "invalid";
}

const char *hotdog_qmi_nas_network_name(QmiNasNetworkType network)
{
	const char *name = qmi_nas_network_type_get_string(network);

	return name ? name : "invalid";
}
