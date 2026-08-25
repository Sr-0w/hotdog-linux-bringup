/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef HOTDOG_QMI_WDS_H
#define HOTDOG_QMI_WDS_H

#include "hotdog-network.h"

#include <libqmi-glib.h>

#define HOTDOG_WDS_CREDENTIAL_SIZE 128

struct hotdog_wds_credentials {
	char username[HOTDOG_WDS_CREDENTIAL_SIZE];
	char password[HOTDOG_WDS_CREDENTIAL_SIZE];
};

struct hotdog_qmi_wds_leg {
	QmiWdsIpFamily family;
	QmiMessageWdsBindMuxDataPortInput *bind;
	QmiMessageWdsStartNetworkInput *start;
};

struct hotdog_qmi_wds_plan {
	struct hotdog_qmi_wds_leg legs[2];
	size_t count;
};

int hotdog_qmi_wds_plan_build(
	const struct hotdog_bearer *bearer,
	const struct hotdog_wds_credentials *credentials,
	QmiDataEndpointType endpoint_type, uint32_t endpoint_interface,
	QmiWdsClientType client_type, struct hotdog_qmi_wds_plan *plan);
void hotdog_qmi_wds_plan_clear(struct hotdog_qmi_wds_plan *plan);
int hotdog_qmi_wds_decode_start(QmiMessageWdsStartNetworkOutput *output,
				uint32_t *packet_handle,
				uint16_t *remote_result);
int hotdog_qmi_wds_stop_input(uint32_t packet_handle,
			      QmiMessageWdsStopNetworkInput **input);
int hotdog_qmi_wds_current_settings_input(
	QmiMessageWdsGetCurrentSettingsInput **input);
int hotdog_qmi_wds_ipv4_prefix(guint32 mask, unsigned int *prefix);
int hotdog_qmi_wds_decode_current_settings(
	QmiMessageWdsGetCurrentSettingsOutput *output, QmiWdsIpFamily family,
	struct hotdog_bearer_runtime *runtime, uint16_t *remote_result);

#endif
