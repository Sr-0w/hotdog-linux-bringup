/* SPDX-License-Identifier: GPL-2.0-only */
#define _POSIX_C_SOURCE 200809L
#include "hotdog-qmi-wds-profile.h"

#include <errno.h>
#include <string.h>

static int decode_result(bool success, GError *error, uint16_t *remote_result)
{
	*remote_result = 0;
	if (success) {
		g_clear_error(&error);
		return 0;
	}
	if (error && error->domain == QMI_PROTOCOL_ERROR)
		*remote_result = (uint16_t)error->code;
	g_clear_error(&error);
	return -EREMOTEIO;
}

#if QMI_CHECK_VERSION(1, 37, 0)
static QmiSubscriptionType subscription_type(unsigned int subscription)
{
	static const QmiSubscriptionType types[] = {
		QMI_SUBSCRIPTION_TYPE_PRIMARY,
		QMI_SUBSCRIPTION_TYPE_SECONDARY,
		QMI_SUBSCRIPTION_TYPE_TERITIARY,
	};

	return subscription < G_N_ELEMENTS(types) ? types[subscription] :
		QMI_SUBSCRIPTION_TYPE_ANY;
}

int hotdog_qmi_wds_bind_subscription_input(
	unsigned int subscription, QmiMessageWdsBindSubscriptionInput **input)
{
	GError *error = NULL;

	if (!input || subscription >= HOTDOG_NETWORK_MAX_SUBSCRIPTIONS)
		return -EINVAL;
	*input = qmi_message_wds_bind_subscription_input_new();
	if (!qmi_message_wds_bind_subscription_input_set_subscription_id(
		    *input, subscription_type(subscription), &error)) {
		g_clear_error(&error);
		qmi_message_wds_bind_subscription_input_unref(*input);
		*input = NULL;
		return -EINVAL;
	}
	return 0;
}

int hotdog_qmi_wds_decode_bind_subscription(
	QmiMessageWdsBindSubscriptionOutput *output, uint16_t *remote_result)
{
	GError *error = NULL;
	bool success;

	if (!output || !remote_result)
		return -EINVAL;
	success = qmi_message_wds_bind_subscription_output_get_result(output, &error);
	return decode_result(success, error, remote_result);
}
#endif

int hotdog_qmi_wds_profile_list_input(QmiMessageWdsGetProfileListInput **input)
{
	GError *error = NULL;

	if (!input)
		return -EINVAL;
	*input = qmi_message_wds_get_profile_list_input_new();
	if (!qmi_message_wds_get_profile_list_input_set_profile_type(
		    *input, QMI_WDS_PROFILE_TYPE_3GPP, &error)) {
		g_clear_error(&error);
		qmi_message_wds_get_profile_list_input_unref(*input);
		*input = NULL;
		return -EINVAL;
	}
	return 0;
}

int hotdog_qmi_wds_decode_profile_list(
	QmiMessageWdsGetProfileListOutput *output,
	struct hotdog_wds_profile_ref *profiles, size_t capacity, size_t *count,
	uint16_t *remote_result)
{
	GArray *items = NULL;
	GError *error = NULL;
	size_t index, previous;
	bool success;
	int result;

	if (!output || !profiles || !capacity || !count || !remote_result)
		return -EINVAL;
	*count = 0;
	success = qmi_message_wds_get_profile_list_output_get_result(output, &error);
	result = decode_result(success, error, remote_result);
	if (result)
		return result;
	if (!qmi_message_wds_get_profile_list_output_get_profile_list(
		    output, &items, &error) || !items || !items->len) {
		g_clear_error(&error);
		return -ENODATA;
	}
	if (items->len > capacity)
		return -EOVERFLOW;
	for (index = 0; index < items->len; index++) {
		QmiMessageWdsGetProfileListOutputProfileListProfile *item;

		item = &g_array_index(items,
			QmiMessageWdsGetProfileListOutputProfileListProfile, index);
		if (item->profile_type != QMI_WDS_PROFILE_TYPE_3GPP ||
		    !item->profile_index)
			return -EPROTO;
		for (previous = 0; previous < index; previous++)
			if (profiles[previous].index == item->profile_index)
				return -ENOTUNIQ;
		profiles[index].index = item->profile_index;
	}
	*count = items->len;
	return 0;
}

int hotdog_qmi_wds_profile_settings_input(
	unsigned int index, QmiMessageWdsGetProfileSettingsInput **input)
{
	GError *error = NULL;

	if (!input || !index || index > UINT8_MAX)
		return -EINVAL;
	*input = qmi_message_wds_get_profile_settings_input_new();
	if (!qmi_message_wds_get_profile_settings_input_set_profile_id(
		    *input, QMI_WDS_PROFILE_TYPE_3GPP, (guint8)index, &error)) {
		g_clear_error(&error);
		qmi_message_wds_get_profile_settings_input_unref(*input);
		*input = NULL;
		return -EINVAL;
	}
	return 0;
}

static int map_pdp_type(QmiWdsPdpType source, enum hotdog_profile_pdp_type *target)
{
	switch (source) {
	case QMI_WDS_PDP_TYPE_IPV4:
		*target = HOTDOG_PROFILE_PDP_IPV4;
		return 0;
	case QMI_WDS_PDP_TYPE_PPP:
		*target = HOTDOG_PROFILE_PDP_PPP;
		return 0;
	case QMI_WDS_PDP_TYPE_IPV6:
		*target = HOTDOG_PROFILE_PDP_IPV6;
		return 0;
	case QMI_WDS_PDP_TYPE_IPV4_OR_IPV6:
		*target = HOTDOG_PROFILE_PDP_IPV4V6;
		return 0;
	default:
		return -EPROTO;
	}
}

int hotdog_qmi_wds_decode_profile_settings(
	QmiMessageWdsGetProfileSettingsOutput *output,
	unsigned int subscription, unsigned int index,
	struct hotdog_ims_profile *profile, uint16_t *remote_result)
{
	QmiWdsApnTypeMask mask;
	QmiWdsPdpType pdp;
	const char *apn = NULL;
	GError *error = NULL;
	gboolean disabled = false, pcscf = false;
	bool success;
	int result;

	if (!output || !profile || !remote_result ||
	    subscription >= HOTDOG_NETWORK_MAX_SUBSCRIPTIONS ||
	    !index || index > UINT8_MAX)
		return -EINVAL;
	memset(profile, 0, sizeof(*profile));
	success = qmi_message_wds_get_profile_settings_output_get_result(output, &error);
	result = decode_result(success, error, remote_result);
	if (result)
		return result;
	if (!qmi_message_wds_get_profile_settings_output_get_apn_name(
		    output, &apn, NULL) || !apn || !apn[0] ||
	    strnlen(apn, sizeof(profile->apn)) >= sizeof(profile->apn) ||
	    !qmi_message_wds_get_profile_settings_output_get_pdp_type(
		    output, &pdp, NULL) ||
	    !qmi_message_wds_get_profile_settings_output_get_apn_type_mask(
		    output, &mask, NULL))
		return -ENODATA;
	result = map_pdp_type(pdp, &profile->pdp_type);
	if (result)
		return result;
	qmi_message_wds_get_profile_settings_output_get_apn_disabled_flag(
		output, &disabled, NULL);
	qmi_message_wds_get_profile_settings_output_get_pcscf_address_using_pco(
		output, &pcscf, NULL);
	profile->subscription = subscription;
	profile->index = index;
	profile->is_3gpp = true;
	profile->enabled = !disabled;
	profile->pcscf_via_pco = pcscf;
	profile->apn_type_mask = mask;
	memcpy(profile->apn, apn, strlen(apn) + 1);
	return 0;
}
