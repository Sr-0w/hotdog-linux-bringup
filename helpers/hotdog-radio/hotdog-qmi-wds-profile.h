/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef HOTDOG_QMI_WDS_PROFILE_H
#define HOTDOG_QMI_WDS_PROFILE_H

#include "hotdog-ims-bearer.h"

#include <libqmi-glib.h>

struct hotdog_wds_profile_ref {
	unsigned int index;
};

#if QMI_CHECK_VERSION(1, 37, 0)
int hotdog_qmi_wds_bind_subscription_input(
	unsigned int subscription, QmiMessageWdsBindSubscriptionInput **input);
int hotdog_qmi_wds_decode_bind_subscription(
	QmiMessageWdsBindSubscriptionOutput *output, uint16_t *remote_result);
#endif
int hotdog_qmi_wds_profile_list_input(QmiMessageWdsGetProfileListInput **input);
int hotdog_qmi_wds_decode_profile_list(
	QmiMessageWdsGetProfileListOutput *output,
	struct hotdog_wds_profile_ref *profiles, size_t capacity, size_t *count,
	uint16_t *remote_result);
int hotdog_qmi_wds_profile_settings_input(
	unsigned int index, QmiMessageWdsGetProfileSettingsInput **input);
int hotdog_qmi_wds_decode_profile_settings(
	QmiMessageWdsGetProfileSettingsOutput *output,
	unsigned int subscription, unsigned int index,
	struct hotdog_ims_profile *profile, uint16_t *remote_result);

#endif
