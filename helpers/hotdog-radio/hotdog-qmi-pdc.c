/* SPDX-License-Identifier: GPL-2.0-only */
#include "hotdog-qmi-pdc.h"

#include <errno.h>
#include <string.h>

static int validate_subscription(unsigned int subscription)
{
	return subscription < HOTDOG_PDC_MAX_SUBSCRIPTIONS ? 0 : -EINVAL;
}

static int set_common_get(QmiMessagePdcGetSelectedConfigInput *input,
			  unsigned int subscription, uint32_t token)
{
	GError *error = NULL;
	bool success;

	success = qmi_message_pdc_get_selected_config_input_set_config_type(
		input, QMI_PDC_CONFIGURATION_TYPE_SOFTWARE, &error) &&
		qmi_message_pdc_get_selected_config_input_set_token(input, token, &error) &&
		qmi_message_pdc_get_selected_config_input_set_subscription_id(
			input, subscription, &error);
	g_clear_error(&error);
	return success ? 0 : -EINVAL;
}

int hotdog_qmi_pdc_get_selected_input(unsigned int subscription, uint32_t token,
				      QmiMessagePdcGetSelectedConfigInput **input)
{
	if (!input || validate_subscription(subscription))
		return -EINVAL;
	*input = qmi_message_pdc_get_selected_config_input_new();
	if (set_common_get(*input, subscription, token)) {
		qmi_message_pdc_get_selected_config_input_unref(*input);
		*input = NULL;
		return -EINVAL;
	}
	return 0;
}

int hotdog_qmi_pdc_set_selected_input(unsigned int subscription, uint32_t token,
				      const struct hotdog_pdc_id *id,
				      QmiMessagePdcSetSelectedConfigInput **input)
{
	GArray *array;
	GError *error = NULL;
	bool success;

	if (!input || !id || !id->length || id->length > HOTDOG_PDC_ID_SIZE ||
	    validate_subscription(subscription))
		return -EINVAL;
	array = g_array_sized_new(FALSE, FALSE, sizeof(guint8), id->length);
	g_array_append_vals(array, id->value, id->length);
	*input = qmi_message_pdc_set_selected_config_input_new();
	success = qmi_message_pdc_set_selected_config_input_set_type_with_id_v2(
		*input, QMI_PDC_CONFIGURATION_TYPE_SOFTWARE, array, &error) &&
		qmi_message_pdc_set_selected_config_input_set_token(*input, token, &error) &&
		qmi_message_pdc_set_selected_config_input_set_subscription_id(
			*input, subscription, &error);
	g_array_unref(array);
	g_clear_error(&error);
	if (!success) {
		qmi_message_pdc_set_selected_config_input_unref(*input);
		*input = NULL;
		return -EINVAL;
	}
	return 0;
}

int hotdog_qmi_pdc_activate_input(unsigned int subscription, uint32_t token,
				  QmiMessagePdcActivateConfigInput **input)
{
	GError *error = NULL;
	bool success;

	if (!input || validate_subscription(subscription))
		return -EINVAL;
	*input = qmi_message_pdc_activate_config_input_new();
	success = qmi_message_pdc_activate_config_input_set_config_type(
		*input, QMI_PDC_CONFIGURATION_TYPE_SOFTWARE, &error) &&
		qmi_message_pdc_activate_config_input_set_token(*input, token, &error) &&
		qmi_message_pdc_activate_config_input_set_subscription_id(
			*input, subscription, &error);
	g_clear_error(&error);
	if (!success) {
		qmi_message_pdc_activate_config_input_unref(*input);
		*input = NULL;
		return -EINVAL;
	}
	return 0;
}

int hotdog_qmi_pdc_deactivate_input(unsigned int subscription, uint32_t token,
				    QmiMessagePdcDeactivateConfigInput **input)
{
	GError *error = NULL;
	bool success;

	if (!input || validate_subscription(subscription))
		return -EINVAL;
	*input = qmi_message_pdc_deactivate_config_input_new();
	success = qmi_message_pdc_deactivate_config_input_set_config_type(
		*input, QMI_PDC_CONFIGURATION_TYPE_SOFTWARE, &error) &&
		qmi_message_pdc_deactivate_config_input_set_token(*input, token, &error) &&
		qmi_message_pdc_deactivate_config_input_set_subscription_id(
			*input, subscription, &error);
	g_clear_error(&error);
	if (!success) {
		qmi_message_pdc_deactivate_config_input_unref(*input);
		*input = NULL;
		return -EINVAL;
	}
	return 0;
}

static int copy_id(GArray *source, struct hotdog_pdc_id *destination)
{
	memset(destination, 0, sizeof(*destination));
	if (!source)
		return 0;
	if (source->len > sizeof(destination->value))
		return -EOVERFLOW;
	memcpy(destination->value, source->data, source->len);
	destination->length = source->len;
	return 0;
}

int hotdog_qmi_pdc_decode_selected(QmiIndicationPdcGetSelectedConfigOutput *output,
				   uint32_t expected_token,
				   struct hotdog_pdc_id *active,
				   struct hotdog_pdc_id *pending,
				   uint16_t *remote_result)
{
	GArray *active_array = NULL, *pending_array = NULL;
	GError *error = NULL;
	guint32 token;
	guint16 indication_result;
	int result;

	if (!output || !active || !pending || !remote_result)
		return -EINVAL;
	*remote_result = 0;
	if (!qmi_indication_pdc_get_selected_config_output_get_token(output, &token, &error) ||
	    !qmi_indication_pdc_get_selected_config_output_get_indication_result(
		    output, &indication_result, &error)) {
		g_clear_error(&error);
		return -ENODATA;
	}
	if (token != expected_token)
		return -ESTALE;
	if (indication_result == QMI_PROTOCOL_ERROR_NOT_PROVISIONED) {
		*remote_result = indication_result;
		memset(active, 0, sizeof(*active));
		memset(pending, 0, sizeof(*pending));
		return 0;
	}
	if (indication_result) {
		*remote_result = indication_result;
		return -EREMOTEIO;
	}
	qmi_indication_pdc_get_selected_config_output_get_active_id(
		output, &active_array, NULL);
	qmi_indication_pdc_get_selected_config_output_get_pending_id(
		output, &pending_array, NULL);
	result = copy_id(active_array, active);
	if (!result)
		result = copy_id(pending_array, pending);
	return result;
}
