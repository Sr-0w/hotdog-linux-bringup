/* SPDX-License-Identifier: GPL-2.0-only */
#define _POSIX_C_SOURCE 200809L
#include "hotdog-qmi-wds.h"

#include <arpa/inet.h>
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
			leg->bind, (guint8)bearer->mux_id, &error);
	if (success && client_type != QMI_WDS_CLIENT_TYPE_UNDEFINED)
		success = qmi_message_wds_bind_mux_data_port_input_set_client_type(
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
	    (client_type != QMI_WDS_CLIENT_TYPE_TETHERED &&
	     client_type != QMI_WDS_CLIENT_TYPE_UNDEFINED) ||
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

int hotdog_qmi_wds_decode_start(QmiMessageWdsStartNetworkOutput *output,
				uint32_t *packet_handle,
				uint16_t *remote_result)
{
	GError *error = NULL;

	if (!output || !packet_handle || !remote_result)
		return -EINVAL;
	*packet_handle = 0;
	*remote_result = 0;
	if (!qmi_message_wds_start_network_output_get_result(output, &error)) {
		if (error && error->domain == QMI_PROTOCOL_ERROR)
			*remote_result = (uint16_t)error->code;
		g_clear_error(&error);
		return -EREMOTEIO;
	}
	if (!qmi_message_wds_start_network_output_get_packet_data_handle(
		    output, packet_handle, &error) || !*packet_handle) {
		g_clear_error(&error);
		return -ENODATA;
	}
	return 0;
}

int hotdog_qmi_wds_stop_input(uint32_t packet_handle,
			      QmiMessageWdsStopNetworkInput **input)
{
	GError *error = NULL;

	if (!packet_handle || !input)
		return -EINVAL;
	*input = qmi_message_wds_stop_network_input_new();
	if (!qmi_message_wds_stop_network_input_set_packet_data_handle(
		    *input, packet_handle, &error)) {
		g_clear_error(&error);
		qmi_message_wds_stop_network_input_unref(*input);
		*input = NULL;
		return -EINVAL;
	}
	return 0;
}

int hotdog_qmi_wds_current_settings_input(
	QmiMessageWdsGetCurrentSettingsInput **input)
{
	QmiWdsRequestedSettings requested =
		QMI_WDS_REQUESTED_SETTINGS_DNS_ADDRESS |
		QMI_WDS_REQUESTED_SETTINGS_IP_ADDRESS |
		QMI_WDS_REQUESTED_SETTINGS_GATEWAY_INFO |
		QMI_WDS_REQUESTED_SETTINGS_PCSCF_ADDRESS |
		QMI_WDS_REQUESTED_SETTINGS_PCSCF_SERVER_ADDRESS_LIST |
		QMI_WDS_REQUESTED_SETTINGS_PCSCF_DOMAIN_NAME_LIST |
		QMI_WDS_REQUESTED_SETTINGS_MTU |
		QMI_WDS_REQUESTED_SETTINGS_DOMAIN_NAME_LIST |
		QMI_WDS_REQUESTED_SETTINGS_IP_FAMILY;
	GError *error = NULL;

	if (!input)
		return -EINVAL;
	*input = qmi_message_wds_get_current_settings_input_new();
	if (!qmi_message_wds_get_current_settings_input_set_requested_settings(
		    *input, requested, &error)) {
		g_clear_error(&error);
		qmi_message_wds_get_current_settings_input_unref(*input);
		*input = NULL;
		return -EINVAL;
	}
	return 0;
}

static int ipv4_string(guint32 address, char *target, size_t size)
{
	struct in_addr value = { .s_addr = GUINT32_TO_BE(address) };

	return inet_ntop(AF_INET, &value, target, (socklen_t)size) ? 0 : -EINVAL;
}

int hotdog_qmi_wds_ipv4_prefix(guint32 mask, unsigned int *prefix)
{
	guint32 value = GUINT32_TO_BE(mask);
	const unsigned char *bytes = (const unsigned char *)&value;
	bool zero_seen = false;
	unsigned int bits = 0, byte, bit;

	if (!prefix)
		return -EINVAL;
	for (byte = 0; byte < sizeof(value); byte++) {
		for (bit = 0; bit < 8; bit++) {
			bool set = bytes[byte] & (1U << (7 - bit));

			if (zero_seen && set)
				return -EPROTO;
			if (set)
				bits++;
			else
				zero_seen = true;
		}
	}
	if (!bits)
		return -EPROTO;
	*prefix = bits;
	return 0;
}

static int ipv6_string(GArray *array, char *target, size_t size)
{
	struct in6_addr value = { 0 };
	size_t index;

	if (!array || array->len != 8)
		return -EPROTO;
	for (index = 0; index < 8; index++) {
		guint16 word = GUINT16_TO_BE(g_array_index(array, guint16, index));

		memcpy(&value.s6_addr[index * sizeof(word)], &word, sizeof(word));
	}
	return inet_ntop(AF_INET6, &value, target, (socklen_t)size) ? 0 : -EINVAL;
}

static bool contains_domain(char values[][HOTDOG_NETWORK_DOMAIN_SIZE],
			    size_t count, const char *candidate)
{
	size_t index;

	for (index = 0; index < count; index++)
		if (!strcmp(values[index], candidate))
			return true;
	return false;
}

static int decode_pcscf(QmiMessageWdsGetCurrentSettingsOutput *output,
			struct hotdog_bearer_runtime *runtime)
{
	GArray *array = NULL;
	size_t index;

	if (qmi_message_wds_get_current_settings_output_get_pcscf_server_address_list(
		    output, &array, NULL) && array) {
		if (array->len > HOTDOG_NETWORK_MAX_PCSCF)
			return -EOVERFLOW;
		for (index = 0; index < array->len; index++) {
			char address[HOTDOG_NETWORK_ADDRESS_SIZE];
			guint32 value = g_array_index(array, guint32, index);
			size_t previous;
			int result = ipv4_string(value, address, sizeof(address));

			if (result)
				return result;
			for (previous = 0; previous < runtime->pcscf_address_count; previous++)
				if (!strcmp(runtime->pcscf_addresses[previous], address))
					break;
			if (previous < runtime->pcscf_address_count)
				continue;
			if (runtime->pcscf_address_count == HOTDOG_NETWORK_MAX_PCSCF)
				return -EOVERFLOW;
			memcpy(runtime->pcscf_addresses[runtime->pcscf_address_count++],
			       address, strlen(address) + 1);
		}
	}
	array = NULL;
	if (qmi_message_wds_get_current_settings_output_get_pcscf_domain_name_list(
		    output, &array, NULL) && array) {
		if (array->len > HOTDOG_NETWORK_MAX_PCSCF)
			return -EOVERFLOW;
		for (index = 0; index < array->len; index++) {
			const char *domain = g_array_index(array, gchar *, index);
			size_t length;

			if (!domain)
				return -EPROTO;
			length = strnlen(domain, HOTDOG_NETWORK_DOMAIN_SIZE);
			if (!length || length >= HOTDOG_NETWORK_DOMAIN_SIZE)
				return -EPROTO;
			if (contains_domain(runtime->pcscf_domains,
					    runtime->pcscf_domain_count, domain))
				continue;
			if (runtime->pcscf_domain_count == HOTDOG_NETWORK_MAX_PCSCF)
				return -EOVERFLOW;
			memcpy(runtime->pcscf_domains[runtime->pcscf_domain_count++],
			       domain, length + 1);
		}
	}
	return 0;
}

int hotdog_qmi_wds_decode_current_settings(
	QmiMessageWdsGetCurrentSettingsOutput *output, QmiWdsIpFamily family,
	struct hotdog_bearer_runtime *runtime, uint16_t *remote_result)
{
	GError *error = NULL;
	GArray *array = NULL;
	guint32 address, mtu;
	guint8 prefix;
	int result;

	if (!output || !runtime || !remote_result ||
	    (family != QMI_WDS_IP_FAMILY_IPV4 && family != QMI_WDS_IP_FAMILY_IPV6))
		return -EINVAL;
	*remote_result = 0;
	if (!qmi_message_wds_get_current_settings_output_get_result(output, &error)) {
		if (error && error->domain == QMI_PROTOCOL_ERROR)
			*remote_result = (uint16_t)error->code;
		g_clear_error(&error);
		return -EREMOTEIO;
	}
	if (qmi_message_wds_get_current_settings_output_get_mtu(output, &mtu, NULL)) {
		if (mtu < 576 || mtu > 65535 || (runtime->mtu && runtime->mtu != mtu))
			return -EPROTO;
		runtime->mtu = mtu;
	}
	result = decode_pcscf(output, runtime);
	if (result)
		return result;
	if (family == QMI_WDS_IP_FAMILY_IPV4) {
		guint32 mask;

		if (!qmi_message_wds_get_current_settings_output_get_ipv4_address(
			    output, &address, NULL))
			return -ENODATA;
		result = ipv4_string(address, runtime->ipv4, sizeof(runtime->ipv4));
		runtime->ipv4_prefix = 32;
		if (!result &&
		    qmi_message_wds_get_current_settings_output_get_ipv4_gateway_subnet_mask(
			    output, &mask, NULL))
			result = hotdog_qmi_wds_ipv4_prefix(mask, &runtime->ipv4_prefix);
		if (!result && qmi_message_wds_get_current_settings_output_get_ipv4_gateway_address(
				 output, &address, NULL))
			result = ipv4_string(address, runtime->ipv4_gateway,
					     sizeof(runtime->ipv4_gateway));
		if (!result && qmi_message_wds_get_current_settings_output_get_primary_ipv4_dns_address(
				 output, &address, NULL))
			result = ipv4_string(address, runtime->ipv4_dns1,
					     sizeof(runtime->ipv4_dns1));
		if (!result && qmi_message_wds_get_current_settings_output_get_secondary_ipv4_dns_address(
				 output, &address, NULL))
			result = ipv4_string(address, runtime->ipv4_dns2,
					     sizeof(runtime->ipv4_dns2));
		if (!runtime->dns1[0] && runtime->ipv4_dns1[0])
			memcpy(runtime->dns1, runtime->ipv4_dns1,
			       strlen(runtime->ipv4_dns1) + 1);
		if (!runtime->dns2[0] && runtime->ipv4_dns2[0])
			memcpy(runtime->dns2, runtime->ipv4_dns2,
			       strlen(runtime->ipv4_dns2) + 1);
		return result;
	}
	if (!qmi_message_wds_get_current_settings_output_get_ipv6_address(
		    output, &array, &prefix, NULL))
		return -ENODATA;
	result = ipv6_string(array, runtime->ipv6, sizeof(runtime->ipv6));
	runtime->ipv6_prefix = prefix;
	if (!result && qmi_message_wds_get_current_settings_output_get_ipv6_gateway_address(
			 output, &array, &prefix, NULL))
		result = ipv6_string(array, runtime->ipv6_gateway,
				     sizeof(runtime->ipv6_gateway));
	if (!result && qmi_message_wds_get_current_settings_output_get_ipv6_primary_dns_address(
			 output, &array, NULL))
		result = ipv6_string(array, runtime->ipv6_dns1,
				     sizeof(runtime->ipv6_dns1));
	if (!result && qmi_message_wds_get_current_settings_output_get_ipv6_secondary_dns_address(
			 output, &array, NULL))
		result = ipv6_string(array, runtime->ipv6_dns2,
				     sizeof(runtime->ipv6_dns2));
	if (!runtime->dns1[0] && runtime->ipv6_dns1[0])
		memcpy(runtime->dns1, runtime->ipv6_dns1,
		       strlen(runtime->ipv6_dns1) + 1);
	if (!runtime->dns2[0] && runtime->ipv6_dns2[0])
		memcpy(runtime->dns2, runtime->ipv6_dns2,
		       strlen(runtime->ipv6_dns2) + 1);
	return result;
}
