/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef HOTDOG_QMI_IMSA_H
#define HOTDOG_QMI_IMSA_H

#include "hotdog-telephony.h"

#include <libqmi-glib.h>

int hotdog_qmi_imsa_bind_input(unsigned int subscription,
			       QmiMessageImsaBindInput **input);
int hotdog_qmi_imsa_register_input(
	QmiMessageImsaRegisterIndicationsInput **input);
int hotdog_qmi_imsa_decode_registration(
	QmiMessageImsaGetImsRegistrationStatusOutput *output,
	struct hotdog_ims_state *state, uint16_t *remote_result);
int hotdog_qmi_imsa_decode_services(
	QmiMessageImsaGetImsServicesStatusOutput *output,
	struct hotdog_ims_state *state, uint16_t *remote_result);
int hotdog_qmi_imsa_update_registration(
	QmiImsaImsRegistrationStatus registration,
	bool technology_valid, QmiImsaRegistrationTechnology technology,
	unsigned int sip_code, struct hotdog_ims_state *state);
int hotdog_qmi_imsa_update_services(
	bool voice_valid, QmiImsaServiceStatus voice, bool voice_technology_valid,
	QmiImsaRegistrationTechnology voice_technology,
	bool video_valid, QmiImsaServiceStatus video, bool video_technology_valid,
	QmiImsaRegistrationTechnology video_technology,
	bool sms_valid, QmiImsaServiceStatus sms, bool sms_technology_valid,
	QmiImsaRegistrationTechnology sms_technology,
	struct hotdog_ims_state *state);
int hotdog_qmi_imsa_decode_registration_indication(
	QmiIndicationImsaImsRegistrationStatusChangedOutput *output,
	struct hotdog_ims_state *state);
int hotdog_qmi_imsa_decode_services_indication(
	QmiIndicationImsaImsServicesStatusChangedOutput *output,
	struct hotdog_ims_state *state);

#endif
