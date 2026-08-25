/* SPDX-License-Identifier: GPL-2.0-only */
#include "hotdog-qmi-imsa.h"

#include <errno.h>

static int map_registration(QmiImsaImsRegistrationStatus status,
			    enum hotdog_ims_registration *registration)
{
	switch (status) {
	case QMI_IMSA_IMS_NOT_REGISTERED: *registration = HOTDOG_IMS_NONE; return 0;
	case QMI_IMSA_IMS_REGISTERING: *registration = HOTDOG_IMS_REGISTERING; return 0;
	case QMI_IMSA_IMS_REGISTERED: *registration = HOTDOG_IMS_REGISTERED; return 0;
	case QMI_IMSA_IMS_LIMITED_REGISTERED: *registration = HOTDOG_IMS_BLOCKED; return 0;
	}
	return -EPROTO;
}

static int map_technology(QmiImsaRegistrationTechnology technology,
			  enum hotdog_ims_rat *rat)
{
	switch (technology) {
	case QMI_IMSA_REGISTERED_WLAN:
	case QMI_IMSA_REGISTERED_INTERWORKING_WLAN:
		*rat = HOTDOG_IMS_RAT_WLAN;
		return 0;
	case QMI_IMSA_REGISTERED_WWAN:
		*rat = HOTDOG_IMS_RAT_LTE;
		return 0;
	}
	return -EPROTO;
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

int hotdog_qmi_imsa_update_registration(
	QmiImsaImsRegistrationStatus registration,
	bool technology_valid, QmiImsaRegistrationTechnology technology,
	unsigned int sip_code, struct hotdog_ims_state *state)
{
	enum hotdog_ims_registration mapped;
	enum hotdog_ims_rat rat = HOTDOG_IMS_RAT_UNKNOWN;
	int result;

	if (!state || sip_code > UINT16_MAX)
		return -EINVAL;
	result = map_registration(registration, &mapped);
	if (result)
		return result;
	if (technology_valid) {
		result = map_technology(technology, &rat);
		if (result)
			return result;
	} else if (mapped == HOTDOG_IMS_REGISTERED) {
		return -ENODATA;
	}
	state->registration = mapped;
	state->rat = rat;
	state->sip_code = sip_code;
	if (mapped != HOTDOG_IMS_REGISTERED) {
		state->capabilities = 0;
		state->limited_capabilities = 0;
		state->voice_rat = HOTDOG_IMS_RAT_UNKNOWN;
		state->video_rat = HOTDOG_IMS_RAT_UNKNOWN;
		state->sms_rat = HOTDOG_IMS_RAT_UNKNOWN;
	}
	return 0;
}

static int update_service(bool valid, QmiImsaServiceStatus status,
			  bool technology_valid,
			  QmiImsaRegistrationTechnology technology,
			  enum hotdog_ims_rat fallback_rat,
			  uint32_t capability, uint32_t *available,
			  uint32_t *limited, enum hotdog_ims_rat *rat)
{
	enum hotdog_ims_rat mapped = HOTDOG_IMS_RAT_UNKNOWN;
	int result;

	if (!valid)
		return 0;
	if (status != QMI_IMSA_SERVICE_UNAVAILABLE &&
	    status != QMI_IMSA_SERVICE_LIMITED &&
	    status != QMI_IMSA_SERVICE_AVAILABLE)
		return -EPROTO;
	if (status != QMI_IMSA_SERVICE_UNAVAILABLE) {
		if (technology_valid) {
			result = map_technology(technology, &mapped);
			if (result)
				return result;
		} else if (fallback_rat != HOTDOG_IMS_RAT_UNKNOWN) {
			mapped = fallback_rat;
		} else {
			return -ENODATA;
		}
	}
	*available &= ~capability;
	*limited &= ~capability;
	if (status == QMI_IMSA_SERVICE_AVAILABLE)
		*available |= capability;
	else if (status == QMI_IMSA_SERVICE_LIMITED)
		*limited |= capability;
	*rat = mapped;
	return 0;
}

int hotdog_qmi_imsa_update_services(
	bool voice_valid, QmiImsaServiceStatus voice, bool voice_technology_valid,
	QmiImsaRegistrationTechnology voice_technology,
	bool video_valid, QmiImsaServiceStatus video, bool video_technology_valid,
	QmiImsaRegistrationTechnology video_technology,
	bool sms_valid, QmiImsaServiceStatus sms, bool sms_technology_valid,
	QmiImsaRegistrationTechnology sms_technology,
	struct hotdog_ims_state *state)
{
	struct hotdog_ims_state candidate;
	uint32_t available, limited;
	int result;

	if (!state)
		return -EINVAL;
	candidate = *state;
	available = candidate.capabilities;
	limited = candidate.limited_capabilities;
	result = update_service(voice_valid, voice, voice_technology_valid,
				voice_technology, candidate.rat, HOTDOG_IMS_CAP_VOICE,
				&available, &limited, &candidate.voice_rat);
	if (!result)
		result = update_service(video_valid, video, video_technology_valid,
					video_technology, candidate.rat, HOTDOG_IMS_CAP_VIDEO,
					&available, &limited, &candidate.video_rat);
	if (!result)
		result = update_service(sms_valid, sms, sms_technology_valid,
					sms_technology, candidate.rat, HOTDOG_IMS_CAP_SMS,
					&available, &limited, &candidate.sms_rat);
	if (result)
		return result;
	candidate.limited_capabilities = limited;
	candidate.capabilities = available;
	*state = candidate;
	return 0;
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
	QmiImsaRegistrationTechnology technology = QMI_IMSA_REGISTERED_WWAN;
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
	success = qmi_message_imsa_get_ims_registration_status_output_get_ims_registration_technology(
		output, &technology, NULL);
	if (qmi_message_imsa_get_ims_registration_status_output_get_ims_registration_error_code(
		    output, &sip_code, NULL))
		return hotdog_qmi_imsa_update_registration(
			registration, success, technology, sip_code, state);
	return hotdog_qmi_imsa_update_registration(
		registration, success, technology, 0, state);
}

int hotdog_qmi_imsa_decode_services(
	QmiMessageImsaGetImsServicesStatusOutput *output,
	struct hotdog_ims_state *state, uint16_t *remote_result)
{
	QmiImsaServiceStatus voice = QMI_IMSA_SERVICE_UNAVAILABLE;
	QmiImsaServiceStatus video = QMI_IMSA_SERVICE_UNAVAILABLE;
	QmiImsaServiceStatus sms = QMI_IMSA_SERVICE_UNAVAILABLE;
	QmiImsaRegistrationTechnology voice_technology = QMI_IMSA_REGISTERED_WWAN;
	QmiImsaRegistrationTechnology video_technology = QMI_IMSA_REGISTERED_WWAN;
	QmiImsaRegistrationTechnology sms_technology = QMI_IMSA_REGISTERED_WWAN;
	GError *error = NULL;
	gboolean success;
	bool voice_valid, video_valid, sms_valid;
	bool voice_technology_valid, video_technology_valid, sms_technology_valid;
	int result;

	if (!output || !state || !remote_result)
		return -EINVAL;
	success = qmi_message_imsa_get_ims_services_status_output_get_result(
		output, &error);
	result = output_result(success, error, remote_result);
	g_clear_error(&error);
	if (result)
		return result;
	voice_valid = qmi_message_imsa_get_ims_services_status_output_get_ims_voice_service_status(
		output, &voice, NULL);
	video_valid = qmi_message_imsa_get_ims_services_status_output_get_ims_video_telephony_service_status(
		output, &video, NULL);
	sms_valid = qmi_message_imsa_get_ims_services_status_output_get_ims_sms_service_status(
		output, &sms, NULL);
	voice_technology_valid =
		qmi_message_imsa_get_ims_services_status_output_get_ims_voice_service_registration_technology(
			output, &voice_technology, NULL);
	video_technology_valid =
		qmi_message_imsa_get_ims_services_status_output_get_ims_video_telephony_service_registration_technology(
			output, &video_technology, NULL);
	sms_technology_valid =
		qmi_message_imsa_get_ims_services_status_output_get_ims_sms_service_registration_technology(
			output, &sms_technology, NULL);
	if (!voice_valid && !video_valid && !sms_valid)
		return -ENODATA;
	return hotdog_qmi_imsa_update_services(
		voice_valid, voice, voice_technology_valid, voice_technology,
		video_valid, video, video_technology_valid, video_technology,
		sms_valid, sms, sms_technology_valid, sms_technology, state);
}

int hotdog_qmi_imsa_decode_registration_indication(
	QmiIndicationImsaImsRegistrationStatusChangedOutput *output,
	struct hotdog_ims_state *state)
{
	QmiImsaImsRegistrationStatus registration;
	QmiImsaRegistrationTechnology technology = QMI_IMSA_REGISTERED_WWAN;
	guint16 sip_code = 0;
	bool technology_valid;
	GError *error = NULL;

	if (!output || !state)
		return -EINVAL;
	if (!qmi_indication_imsa_ims_registration_status_changed_output_get_ims_registration_status(
		    output, &registration, &error)) {
		g_clear_error(&error);
		return -ENODATA;
	}
	technology_valid =
		qmi_indication_imsa_ims_registration_status_changed_output_get_ims_registration_technology(
			output, &technology, NULL);
	qmi_indication_imsa_ims_registration_status_changed_output_get_ims_registration_error_code(
		output, &sip_code, NULL);
	return hotdog_qmi_imsa_update_registration(
		registration, technology_valid, technology, sip_code, state);
}

int hotdog_qmi_imsa_decode_services_indication(
	QmiIndicationImsaImsServicesStatusChangedOutput *output,
	struct hotdog_ims_state *state)
{
	QmiImsaServiceStatus voice = QMI_IMSA_SERVICE_UNAVAILABLE;
	QmiImsaServiceStatus video = QMI_IMSA_SERVICE_UNAVAILABLE;
	QmiImsaServiceStatus sms = QMI_IMSA_SERVICE_UNAVAILABLE;
	QmiImsaRegistrationTechnology voice_technology = QMI_IMSA_REGISTERED_WWAN;
	QmiImsaRegistrationTechnology video_technology = QMI_IMSA_REGISTERED_WWAN;
	QmiImsaRegistrationTechnology sms_technology = QMI_IMSA_REGISTERED_WWAN;
	bool voice_valid, video_valid, sms_valid;
	bool voice_technology_valid, video_technology_valid, sms_technology_valid;

	if (!output || !state)
		return -EINVAL;
	voice_valid =
		qmi_indication_imsa_ims_services_status_changed_output_get_ims_voice_service_status(
			output, &voice, NULL);
	video_valid =
		qmi_indication_imsa_ims_services_status_changed_output_get_ims_video_telephony_service_status(
			output, &video, NULL);
	sms_valid =
		qmi_indication_imsa_ims_services_status_changed_output_get_ims_sms_service_status(
			output, &sms, NULL);
	voice_technology_valid =
		qmi_indication_imsa_ims_services_status_changed_output_get_ims_voice_service_registration_technology(
			output, &voice_technology, NULL);
	video_technology_valid =
		qmi_indication_imsa_ims_services_status_changed_output_get_ims_video_telephony_service_registration_technology(
			output, &video_technology, NULL);
	sms_technology_valid =
		qmi_indication_imsa_ims_services_status_changed_output_get_ims_sms_service_registration_technology(
			output, &sms_technology, NULL);
	if (!voice_valid && !video_valid && !sms_valid)
		return -ENODATA;
	return hotdog_qmi_imsa_update_services(
		voice_valid, voice, voice_technology_valid, voice_technology,
		video_valid, video, video_technology_valid, video_technology,
		sms_valid, sms, sms_technology_valid, sms_technology, state);
}
