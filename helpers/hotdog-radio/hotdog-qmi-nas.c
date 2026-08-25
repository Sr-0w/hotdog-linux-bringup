/* SPDX-License-Identifier: GPL-2.0-only */
#include "hotdog-qmi-nas.h"

#include <errno.h>
#include <string.h>

static int copy_interfaces(struct hotdog_nas_snapshot *snapshot, GArray *interfaces)
{
	size_t index;

	if (!interfaces || interfaces->len > HOTDOG_NAS_MAX_INTERFACES)
		return -EOVERFLOW;
	for (index = 0; index < interfaces->len; index++)
		snapshot->interfaces[index] = g_array_index(
			interfaces, QmiNasRadioInterface, index);
	snapshot->interface_count = interfaces->len;
	return 0;
}

int hotdog_qmi_nas_decode_serving_system(
	QmiMessageNasGetServingSystemOutput *output,
	struct hotdog_nas_snapshot *snapshot)
{
	GArray *interfaces = NULL;
	GError *error = NULL;
	int result;

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
	result = copy_interfaces(snapshot, interfaces);
	if (result)
		return result;
	snapshot->roaming_valid =
		qmi_message_nas_get_serving_system_output_get_roaming_indicator(
			output, &snapshot->roaming, NULL);
	snapshot->plmn_valid =
		qmi_message_nas_get_serving_system_output_get_current_plmn(
			output, &snapshot->mcc, &snapshot->mnc, NULL, NULL);
	return 0;
}

int hotdog_qmi_nas_decode_serving_system_indication(
	QmiIndicationNasServingSystemOutput *output,
	struct hotdog_nas_snapshot *snapshot)
{
	GArray *interfaces = NULL;
	GError *error = NULL;
	int result;

	if (!output || !snapshot)
		return -EINVAL;
	memset(snapshot, 0, sizeof(*snapshot));
	if (!qmi_indication_nas_serving_system_output_get_serving_system(
		    output, &snapshot->registration, &snapshot->cs_attach,
		    &snapshot->ps_attach, &snapshot->network, &interfaces, &error)) {
		g_clear_error(&error);
		return -ENODATA;
	}
	result = copy_interfaces(snapshot, interfaces);
	if (result)
		return result;
	snapshot->roaming_valid =
		qmi_indication_nas_serving_system_output_get_roaming_indicator(
			output, &snapshot->roaming, NULL);
	snapshot->plmn_valid =
		qmi_indication_nas_serving_system_output_get_current_plmn(
			output, &snapshot->mcc, &snapshot->mnc, NULL, NULL);
	return 0;
}

static int map_registration(const struct hotdog_nas_snapshot *snapshot,
			    enum hotdog_nas_registration *registration)
{
	switch (snapshot->registration) {
	case QMI_NAS_REGISTRATION_STATE_NOT_REGISTERED:
		*registration = HOTDOG_NAS_NONE;
		return 0;
	case QMI_NAS_REGISTRATION_STATE_NOT_REGISTERED_SEARCHING:
		*registration = HOTDOG_NAS_SEARCHING;
		return 0;
	case QMI_NAS_REGISTRATION_STATE_REGISTRATION_DENIED:
		*registration = HOTDOG_NAS_DENIED;
		return 0;
	case QMI_NAS_REGISTRATION_STATE_REGISTERED:
		if (!snapshot->roaming_valid)
			return -ENODATA;
		if (snapshot->roaming != QMI_NAS_ROAMING_INDICATOR_STATUS_ON &&
		    snapshot->roaming != QMI_NAS_ROAMING_INDICATOR_STATUS_OFF)
			return -EPROTO;
		*registration = snapshot->roaming == QMI_NAS_ROAMING_INDICATOR_STATUS_ON ?
			HOTDOG_NAS_ROAMING : HOTDOG_NAS_HOME;
		return 0;
	case QMI_NAS_REGISTRATION_STATE_UNKNOWN:
		return -EPROTO;
	}
	return -EPROTO;
}

static int map_rat(const struct hotdog_nas_snapshot *snapshot,
		   enum hotdog_nas_rat *rat)
{
	bool cdma = false, gsm = false, lte = false, nr5g = false, umts = false;
	size_t index;

	for (index = 0; index < snapshot->interface_count; index++) {
		switch (snapshot->interfaces[index]) {
		case QMI_NAS_RADIO_INTERFACE_5GNR:
			nr5g = true;
			break;
		case QMI_NAS_RADIO_INTERFACE_LTE:
			lte = true;
			break;
		case QMI_NAS_RADIO_INTERFACE_UMTS:
		case QMI_NAS_RADIO_INTERFACE_TD_SCDMA:
			umts = true;
			break;
		case QMI_NAS_RADIO_INTERFACE_GSM:
			gsm = true;
			break;
		case QMI_NAS_RADIO_INTERFACE_CDMA_1X:
		case QMI_NAS_RADIO_INTERFACE_CDMA_1XEVDO:
			cdma = true;
			break;
		case QMI_NAS_RADIO_INTERFACE_NONE:
			break;
		case QMI_NAS_RADIO_INTERFACE_AMPS:
		case QMI_NAS_RADIO_INTERFACE_UNKNOWN:
		default:
			return -EPROTO;
		}
	}
	*rat = nr5g ? HOTDOG_RAT_NR5G : lte ? HOTDOG_RAT_LTE :
		umts ? HOTDOG_RAT_UMTS : gsm ? HOTDOG_RAT_GSM :
		cdma ? HOTDOG_RAT_CDMA : HOTDOG_RAT_UNKNOWN;
	return 0;
}

int hotdog_qmi_nas_apply_snapshot(
	struct hotdog_network *network, unsigned int subscription,
	const struct hotdog_nas_snapshot *snapshot,
	struct hotdog_network_teardown *teardown)
{
	enum hotdog_nas_registration registration;
	enum hotdog_nas_rat rat;
	bool registered;
	int result;

	if (!network || !snapshot || !teardown ||
	    (snapshot->cs_attach != QMI_NAS_ATTACH_STATE_ATTACHED &&
	     snapshot->cs_attach != QMI_NAS_ATTACH_STATE_DETACHED) ||
	    (snapshot->ps_attach != QMI_NAS_ATTACH_STATE_ATTACHED &&
	     snapshot->ps_attach != QMI_NAS_ATTACH_STATE_DETACHED) ||
	    snapshot->network > QMI_NAS_NETWORK_TYPE_3GPP)
		return -EINVAL;
	result = map_registration(snapshot, &registration);
	if (result)
		return result;
	result = map_rat(snapshot, &rat);
	if (result)
		return result;
	registered = registration == HOTDOG_NAS_HOME ||
		registration == HOTDOG_NAS_ROAMING;
	if (registered && (!snapshot->plmn_valid || !snapshot->mcc ||
			   snapshot->mcc > 999 || snapshot->mnc > 999 ||
			   !snapshot->interface_count))
		return -ENODATA;
	return hotdog_network_nas_reconcile(
		network, subscription, registration,
		registered ? snapshot->mcc : 0, registered ? snapshot->mnc : 0,
		rat, snapshot->ps_attach == QMI_NAS_ATTACH_STATE_ATTACHED,
		snapshot->cs_attach == QMI_NAS_ATTACH_STATE_ATTACHED, teardown);
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
