/* SPDX-License-Identifier: GPL-2.0-only */
#include "hotdog-qmi-imsa.h"

#include <errno.h>

static enum hotdog_ims_registration map_registration(
	QmiImsaImsRegistrationStatus status)
{
	switch (status) {
	case QMI_IMSA_IMS_NOT_REGISTERED: return HOTDOG_IMS_NONE;
	case QMI_IMSA_IMS_REGISTERING: return HOTDOG_IMS_REGISTERING;
	case QMI_IMSA_IMS_REGISTERED: return HOTDOG_IMS_REGISTERED;
	case QMI_IMSA_IMS_LIMITED_REGISTERED: return HOTDOG_IMS_BLOCKED;
	}
	return HOTDOG_IMS_NONE;
}

static enum hotdog_ims_rat map_technology(QmiImsaRegistrationTechnology technology)
{
	switch (technology) {
	case QMI_IMSA_REGISTERED_WLAN:
	case QMI_IMSA_REGISTERED_INTERWORKING_WLAN:
		return HOTDOG_IMS_RAT_WLAN;
	case QMI_IMSA_REGISTERED_WWAN:
		return HOTDOG_IMS_RAT_LTE;
	}
	return HOTDOG_IMS_RAT_UNKNOWN;
}

static int output_result(gboolean success, GError *error, uint16_t *remote_result)
{
	*remote_result = 0;
	if (success)
		return 0;
	if (error && error->domain == QMI_PROTOCOL_ERROR)
		*remote_result = (uint16_t)error->code;
	return -EREMOTEIO;
}

int hotdog_qmi_imsa_bind_input(unsigned int subscription,
			       QmiMessageImsaBindInput **input)
{
	GError *error = NULL;

	if (subscription >= HOTDOG_TELEPHONY_MAX_SUBSCRIPTIONS || !input)
		return -EINVAL;
	*input = qmi_message_imsa_bind_input_new();
	if (!qmi_message_imsa_bind_input_set_binding(*input, subscription, &error)) {
		g_clear_error(&error);
		qmi_message_imsa_bind_input_unref(*input);
		*input = NULL;
		return -EINVAL;
	}
	return 0;
}

int hotdog_qmi_imsa_register_input(
	QmiMessageImsaRegisterIndicationsInput **input)
{
	GError *error = NULL;
	bool success;

	if (!input)
		return -EINVAL;
	*input = qmi_message_imsa_register_indications_input_new();
	success = qmi_message_imsa_register_indications_input_set_ims_services_status_changed(
		*input, true, &error) &&
		qmi_message_imsa_register_indications_input_set_ims_registration_status_changed(
			*input, true, &error);
	g_clear_error(&error);
	if (!success) {
		qmi_message_imsa_register_indications_input_unref(*input);
		*input = NULL;
		return -EINVAL;
	}
	return 0;
}

int hotdog_qmi_imsa_decode_registration(
	QmiMessageImsaGetImsRegistrationStatusOutput *output,
	struct hotdog_ims_state *state, uint16_t *remote_result)
{
	QmiImsaImsRegistrationStatus registration;
	QmiImsaRegistrationTechnology technology;
	GError *error = NULL;
	gboolean success;
	guint16 sip_code = 0;
	int result;

	if (!output || !state || !remote_result)
		return -EINVAL;
	success = qmi_message_imsa_get_ims_registration_status_output_get_result(
		output, &error);
	result = output_result(success, error, remote_result);
	g_clear_error(&error);
	if (result)
		return result;
	if (!qmi_message_imsa_get_ims_registration_status_output_get_ims_registration_status(
		    output, &registration, &error)) {
		g_clear_error(&error);
		return -ENODATA;
	}
	state->registration = map_registration(registration);
	state->rat = HOTDOG_IMS_RAT_UNKNOWN;
	state->capabilities = 0;
	state->sip_code = 0;
	if (qmi_message_imsa_get_ims_registration_status_output_get_ims_registration_technology(
		    output, &technology, NULL))
		state->rat = map_technology(technology);
	if (qmi_message_imsa_get_ims_registration_status_output_get_ims_registration_error_code(
		    output, &sip_code, NULL))
		state->sip_code = sip_code;
	return 0;
}

int hotdog_qmi_imsa_decode_services(
	QmiMessageImsaGetImsServicesStatusOutput *output,
	struct hotdog_ims_state *state, uint16_t *remote_result)
{
	QmiImsaServiceStatus status;
	GError *error = NULL;
	gboolean success;
	uint32_t capabilities = 0;
	int result;

	if (!output || !state || !remote_result)
		return -EINVAL;
	success = qmi_message_imsa_get_ims_services_status_output_get_result(
		output, &error);
	result = output_result(success, error, remote_result);
	g_clear_error(&error);
	if (result)
		return result;
	if (qmi_message_imsa_get_ims_services_status_output_get_ims_voice_service_status(
		    output, &status, NULL) && status == QMI_IMSA_SERVICE_AVAILABLE)
		capabilities |= HOTDOG_IMS_CAP_VOICE;
	if (qmi_message_imsa_get_ims_services_status_output_get_ims_video_telephony_service_status(
		    output, &status, NULL) && status == QMI_IMSA_SERVICE_AVAILABLE)
		capabilities |= HOTDOG_IMS_CAP_VIDEO;
	if (qmi_message_imsa_get_ims_services_status_output_get_ims_sms_service_status(
		    output, &status, NULL) && status == QMI_IMSA_SERVICE_AVAILABLE)
		capabilities |= HOTDOG_IMS_CAP_SMS;
	state->capabilities = state->registration == HOTDOG_IMS_REGISTERED ?
		capabilities : 0;
	return 0;
}
