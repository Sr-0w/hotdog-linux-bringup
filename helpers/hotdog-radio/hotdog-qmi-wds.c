/* SPDX-License-Identifier: GPL-2.0-only */
#include "hotdog-qmi-wds.h"

#include <errno.h>
#include <string.h>

static QmiWdsAuthentication map_auth(enum hotdog_data_auth auth)
{
	switch (auth) {
	case HOTDOG_AUTH_NONE: return QMI_WDS_AUTHENTICATION_NONE;
	case HOTDOG_AUTH_PAP: return QMI_WDS_AUTHENTICATION_PAP;
	case HOTDOG_AUTH_CHAP: return QMI_WDS_AUTHENTICATION_CHAP;
	case HOTDOG_AUTH_PAP_CHAP:
		return QMI_WDS_AUTHENTICATION_PAP | QMI_WDS_AUTHENTICATION_CHAP;
	}
	return QMI_WDS_AUTHENTICATION_NONE;
}

static bool terminated(const char *value, size_t size)
{
	return memchr(value, '\0', size) != NULL;
}

static int build_leg(const struct hotdog_bearer *bearer,
		     const struct hotdog_wds_credentials *credentials,
		     QmiDataEndpointType endpoint_type, uint32_t endpoint_interface,
		     QmiWdsClientType client_type, QmiWdsIpFamily family,
		     struct hotdog_qmi_wds_leg *leg)
{
	GError *error = NULL;
	QmiWdsAuthentication auth = map_auth(bearer->auth);
	bool success;

	leg->family = family;
	leg->bind = qmi_message_wds_bind_mux_data_port_input_new();
	success = qmi_message_wds_bind_mux_data_port_input_set_endpoint_info(
		leg->bind, endpoint_type, endpoint_interface, &error) &&
		qmi_message_wds_bind_mux_data_port_input_set_mux_id(
			leg->bind, (guint8)bearer->mux_id, &error) &&
		qmi_message_wds_bind_mux_data_port_input_set_client_type(
			leg->bind, client_type, &error);
	g_clear_error(&error);
	if (!success)
		return -EINVAL;
	leg->start = qmi_message_wds_start_network_input_new();
	success = qmi_message_wds_start_network_input_set_apn(
		leg->start, bearer->apn, &error) &&
		qmi_message_wds_start_network_input_set_ip_family_preference(
			leg->start, family, &error);
	if (success && bearer->profile)
		success = qmi_message_wds_start_network_input_set_profile_index_3gpp(
			leg->start, (guint8)bearer->profile, &error);
	if (success && bearer->auth != HOTDOG_AUTH_NONE)
		success = qmi_message_wds_start_network_input_set_authentication_preference(
			leg->start, auth, &error);
	if (success && credentials && credentials->username[0])
		success = qmi_message_wds_start_network_input_set_username(
			leg->start, credentials->username, &error);
	if (success && credentials && credentials->password[0])
		success = qmi_message_wds_start_network_input_set_password(
			leg->start, credentials->password, &error);
	g_clear_error(&error);
	return success ? 0 : -EINVAL;
}

int hotdog_qmi_wds_plan_build(
	const struct hotdog_bearer *bearer,
	const struct hotdog_wds_credentials *credentials,
	QmiDataEndpointType endpoint_type, uint32_t endpoint_interface,
	QmiWdsClientType client_type, struct hotdog_qmi_wds_plan *plan)
{
	QmiWdsIpFamily families[2];
	size_t count, index;
	int result;

	if (!bearer || !plan || bearer->state != HOTDOG_BEARER_STARTING ||
	    !bearer->mux_id || bearer->mux_id > UINT8_MAX ||
	    bearer->profile > UINT8_MAX || !bearer->apn[0] ||
	    bearer->family > HOTDOG_IP_V4V6 || bearer->auth > HOTDOG_AUTH_PAP_CHAP ||
	    (credentials &&
	     (!terminated(credentials->username, sizeof(credentials->username)) ||
	      !terminated(credentials->password, sizeof(credentials->password)))))
		return -EINVAL;
	memset(plan, 0, sizeof(*plan));
	if (bearer->auth == HOTDOG_AUTH_NONE && credentials &&
	    (credentials->username[0] || credentials->password[0]))
		return -EINVAL;
	if (credentials && (!!credentials->username[0] != !!credentials->password[0]))
		return -EINVAL;
	if (bearer->family == HOTDOG_IP_V4) {
		families[0] = QMI_WDS_IP_FAMILY_IPV4;
		count = 1;
	} else if (bearer->family == HOTDOG_IP_V6) {
		families[0] = QMI_WDS_IP_FAMILY_IPV6;
		count = 1;
	} else {
		families[0] = QMI_WDS_IP_FAMILY_IPV4;
		families[1] = QMI_WDS_IP_FAMILY_IPV6;
		count = 2;
	}
	for (index = 0; index < count; index++) {
		result = build_leg(bearer, credentials, endpoint_type,
				   endpoint_interface, client_type, families[index],
				   &plan->legs[index]);
		if (result) {
			hotdog_qmi_wds_plan_clear(plan);
			return result;
		}
		plan->count++;
	}
	return 0;
}

void hotdog_qmi_wds_plan_clear(struct hotdog_qmi_wds_plan *plan)
{
	size_t index;

	if (!plan)
		return;
	for (index = 0; index < 2; index++) {
		if (plan->legs[index].bind)
			qmi_message_wds_bind_mux_data_port_input_unref(plan->legs[index].bind);
		if (plan->legs[index].start)
			qmi_message_wds_start_network_input_unref(plan->legs[index].start);
	}
	memset(plan, 0, sizeof(*plan));
}
