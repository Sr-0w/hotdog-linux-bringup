/* SPDX-License-Identifier: GPL-2.0-only */
#include "hotdog-qmi-pdc-load.h"

#include <errno.h>

static GArray *id_array(const struct hotdog_pdc_id *id)
{
	GArray *array;

	if (!id || id->length != HOTDOG_PDC_ID_SIZE)
		return NULL;
	array = g_array_sized_new(FALSE, FALSE, sizeof(guint8), id->length);
	g_array_append_vals(array, id->value, id->length);
	return array;
}

int hotdog_qmi_pdc_load_input(uint32_t token, const struct hotdog_pdc_id *id,
			      uint32_t total_size, const unsigned char *chunk,
			      size_t chunk_size,
			      QmiMessagePdcLoadConfigInput **input)
{
	GArray *id_value, *chunk_value;
	GError *error = NULL;
	bool success;

	if (!token || !total_size || !chunk || !chunk_size ||
	    chunk_size > HOTDOG_PDC_LOAD_CHUNK_SIZE || chunk_size > total_size || !input)
		return -EINVAL;
	id_value = id_array(id);
	if (!id_value)
		return -EINVAL;
	chunk_value = g_array_sized_new(FALSE, FALSE, sizeof(guint8), chunk_size);
	g_array_append_vals(chunk_value, chunk, chunk_size);
	*input = qmi_message_pdc_load_config_input_new();
	success = qmi_message_pdc_load_config_input_set_token(*input, token, &error) &&
		qmi_message_pdc_load_config_input_set_config_chunk(
			*input, QMI_PDC_CONFIGURATION_TYPE_SOFTWARE, id_value,
			total_size, chunk_value, &error);
	g_array_unref(chunk_value);
	g_array_unref(id_value);
	g_clear_error(&error);
	if (!success) {
		qmi_message_pdc_load_config_input_unref(*input);
		*input = NULL;
		return -EINVAL;
	}
	return 0;
}

int hotdog_qmi_pdc_delete_input(uint32_t token, const struct hotdog_pdc_id *id,
				QmiMessagePdcDeleteConfigInput **input)
{
	GArray *id_value;
	GError *error = NULL;
	bool success;

	if (!token || !input)
		return -EINVAL;
	id_value = id_array(id);
	if (!id_value)
		return -EINVAL;
	*input = qmi_message_pdc_delete_config_input_new();
	success = qmi_message_pdc_delete_config_input_set_id(*input, id_value, &error) &&
		qmi_message_pdc_delete_config_input_set_token(*input, token, &error) &&
		qmi_message_pdc_delete_config_input_set_config_type(
			*input, QMI_PDC_CONFIGURATION_TYPE_SOFTWARE, &error);
	g_array_unref(id_value);
	g_clear_error(&error);
	if (!success) {
		qmi_message_pdc_delete_config_input_unref(*input);
		*input = NULL;
		return -EINVAL;
	}
	return 0;
}

int hotdog_qmi_pdc_decode_load(QmiIndicationPdcLoadConfigOutput *output,
			       struct hotdog_pdc_load *load,
			       uint16_t *remote_result)
{
	GError *error = NULL;
	guint32 token, remaining, received;
	guint16 remote;
	gboolean frame_reset = FALSE;
	int result;

	if (!output || !load || !remote_result)
		return -EINVAL;
	*remote_result = 0;
	if (!qmi_indication_pdc_load_config_output_get_token(output, &token, &error) ||
	    !qmi_indication_pdc_load_config_output_get_indication_result(
		    output, &remote, &error)) {
		g_clear_error(&error);
		hotdog_pdc_load_abort(load);
		return -ENODATA;
	}
	if (token != load->expected_token)
		return -ESTALE;
	*remote_result = remote;
	if (remote)
		return hotdog_pdc_load_ack(load, token, remote, false, 0);
	qmi_indication_pdc_load_config_output_get_frame_reset(output, &frame_reset, NULL);
	if (!qmi_indication_pdc_load_config_output_get_remaining_size(
		    output, &remaining, &error)) {
		g_clear_error(&error);
		hotdog_pdc_load_abort(load);
		return -ENODATA;
	}
	if (qmi_indication_pdc_load_config_output_get_received(output, &received, NULL) &&
	    received > load->total_size) {
		hotdog_pdc_load_abort(load);
		return -EPROTO;
	}
	result = hotdog_pdc_load_ack(load, token, 0, frame_reset, remaining);
	return result;
}
