/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef HOTDOG_QMI_NAS_H
#define HOTDOG_QMI_NAS_H

#include <libqmi-glib.h>

#include <stdbool.h>
#include <stddef.h>

#define HOTDOG_NAS_MAX_INTERFACES 16

struct hotdog_nas_snapshot {
	QmiNasRegistrationState registration;
	QmiNasAttachState cs_attach;
	QmiNasAttachState ps_attach;
	QmiNasNetworkType network;
	QmiNasRadioInterface interfaces[HOTDOG_NAS_MAX_INTERFACES];
	size_t interface_count;
	bool roaming_valid;
	QmiNasRoamingIndicatorStatus roaming;
};

int hotdog_qmi_nas_decode_serving_system(
	QmiMessageNasGetServingSystemOutput *output,
	struct hotdog_nas_snapshot *snapshot);
const char *hotdog_qmi_nas_registration_name(QmiNasRegistrationState state);
const char *hotdog_qmi_nas_attach_name(QmiNasAttachState state);
const char *hotdog_qmi_nas_network_name(QmiNasNetworkType network);

#endif
