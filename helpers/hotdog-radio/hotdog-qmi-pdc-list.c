/* SPDX-License-Identifier: GPL-2.0-only */
#include "hotdog-qmi-pdc-list.h"

#include <errno.h>
#include <string.h>

int hotdog_qmi_pdc_list_input(uint32_t token, QmiMessagePdcListConfigsInput **input)
{
	GError *error = NULL;
	bool success;

	if (!token || !input)
		return -EINVAL;
	*input = qmi_message_pdc_list_configs_input_new();
	success = qmi_message_pdc_list_configs_input_set_token(*input, token, &error) &&
		qmi_message_pdc_list_configs_input_set_config_type(
			*input, QMI_PDC_CONFIGURATION_TYPE_SOFTWARE, &error);
	g_clear_error(&error);
	if (!success) {
		qmi_message_pdc_list_configs_input_unref(*input);
		*input = NULL;
		return -EINVAL;
	}
	return 0;
}

int hotdog_qmi_pdc_decode_list(QmiIndicationPdcListConfigsOutput *output,
			       uint32_t expected_token,
			       struct hotdog_pdc_loaded_catalog *loaded,
			       uint16_t *remote_result)
{
	GArray *configs = NULL;
	GError *error = NULL;
	guint32 token;
	guint16 remote;
	size_t index, previous;

	if (!output || !loaded || !remote_result)
		return -EINVAL;
	memset(loaded, 0, sizeof(*loaded));
	*remote_result = 0;
	if (!qmi_indication_pdc_list_configs_output_get_token(output, &token, &error) ||
	    !qmi_indication_pdc_list_configs_output_get_indication_result(
		    output, &remote, &error)) {
		g_clear_error(&error);
		return -ENODATA;
	}
	if (token != expected_token)
		return -ESTALE;
	if (remote) {
		*remote_result = remote;
		return -EREMOTEIO;
	}
	if (!qmi_indication_pdc_list_configs_output_get_configs(output, &configs, &error)) {
		g_clear_error(&error);
		return -ENODATA;
	}
	if (configs->len > HOTDOG_PDC_MAX_CONFIGS)
		return -EOVERFLOW;
	for (index = 0; index < configs->len; index++) {
		QmiIndicationPdcListConfigsOutputConfigsElement *element = &g_array_index(
			configs, QmiIndicationPdcListConfigsOutputConfigsElement, index);
		struct hotdog_pdc_id *id = &loaded->ids[loaded->count];

		if (element->config_type != QMI_PDC_CONFIGURATION_TYPE_SOFTWARE ||
		    !element->id || !element->id->len ||
		    element->id->len > HOTDOG_PDC_ID_SIZE)
			return -EPROTO;
		memcpy(id->value, element->id->data, element->id->len);
		id->length = element->id->len;
		for (previous = 0; previous < loaded->count; previous++)
			if (hotdog_pdc_id_equal(&loaded->ids[previous], id))
				return -EEXIST;
		loaded->count++;
	}
	return 0;
}
