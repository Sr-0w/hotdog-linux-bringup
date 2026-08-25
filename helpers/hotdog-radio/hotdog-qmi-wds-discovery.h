/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef HOTDOG_QMI_WDS_DISCOVERY_H
#define HOTDOG_QMI_WDS_DISCOVERY_H

#include "hotdog-ims-bearer.h"
#include "hotdog-qmi-wds-profile.h"

#include <gio/gio.h>
#include <libqmi-glib.h>

struct hotdog_qmi_wds_discovery;

typedef void (*hotdog_qmi_wds_discovery_callback)(
	struct hotdog_qmi_wds_discovery *discovery, int result, void *user_data);

struct hotdog_qmi_wds_discovery {
	QmiDevice *device;
	QmiClientWds *client;
	GCancellable *cancellable;
	struct hotdog_wds_profile_ref refs[HOTDOG_IMS_MAX_PROFILES];
	struct hotdog_ims_profile profiles[HOTDOG_IMS_MAX_PROFILES];
	struct hotdog_ims_profile_selection selection;
	hotdog_qmi_wds_discovery_callback callback;
	void *user_data;
	unsigned int subscription;
	unsigned int generation;
	uint16_t remote_result;
	size_t ref_count;
	size_t next_ref;
	size_t profile_count;
	int result;
	bool active;
	bool residue;
	bool initialized;
};

void hotdog_qmi_wds_discovery_init(struct hotdog_qmi_wds_discovery *discovery);
int hotdog_qmi_wds_discovery_start(
	struct hotdog_qmi_wds_discovery *discovery, QmiDevice *device,
	unsigned int subscription, hotdog_qmi_wds_discovery_callback callback,
	void *user_data);
int hotdog_qmi_wds_discovery_abort_ssr(
	struct hotdog_qmi_wds_discovery *discovery);
int hotdog_qmi_wds_discovery_clear(
	struct hotdog_qmi_wds_discovery *discovery);

#endif
