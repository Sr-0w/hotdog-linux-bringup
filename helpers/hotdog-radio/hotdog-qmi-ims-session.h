/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef HOTDOG_QMI_IMS_SESSION_H
#define HOTDOG_QMI_IMS_SESSION_H

#include "hotdog-ims-bearer.h"
#include "hotdog-ims-executor.h"
#include "hotdog-qmi-rmnet.h"
#include "hotdog-qmi-wds.h"

#include <gio/gio.h>
#include <libqmi-glib.h>

enum hotdog_qmi_ims_session_event {
	HOTDOG_QMI_IMS_SESSION_CONFIGURE_REQUIRED,
	HOTDOG_QMI_IMS_SESSION_UP,
	HOTDOG_QMI_IMS_SESSION_DOWN,
	HOTDOG_QMI_IMS_SESSION_BLOCKED,
};

struct hotdog_qmi_ims_session;

typedef void (*hotdog_qmi_ims_session_callback)(
	struct hotdog_qmi_ims_session *session,
	enum hotdog_qmi_ims_session_event event, unsigned int error,
	void *user_data);

struct hotdog_qmi_ims_session_config {
	QmiDevice *device;
	struct hotdog_qmi_rmnet_plan rmnet;
	struct hotdog_ims_profile_selection profile;
};

struct hotdog_qmi_ims_session {
	struct hotdog_ims_executor executor;
	struct hotdog_qmi_ims_session_config config;
	struct hotdog_bearer bearer;
	struct hotdog_bearer_runtime runtime;
	struct hotdog_qmi_wds_plan wds;
	QmiClientWds *clients[HOTDOG_IMS_EXECUTOR_MAX_LEGS];
	GCancellable *cancellable;
	hotdog_qmi_ims_session_callback callback;
	void *user_data;
	unsigned int generation;
	unsigned int pending_leg;
	unsigned int release_leg;
	bool initialized;
};

void hotdog_qmi_ims_session_init(struct hotdog_qmi_ims_session *session);
int hotdog_qmi_ims_session_start(
	struct hotdog_qmi_ims_session *session,
	const struct hotdog_qmi_ims_session_config *config,
	hotdog_qmi_ims_session_callback callback, void *user_data);
int hotdog_qmi_ims_session_configured(struct hotdog_qmi_ims_session *session);
int hotdog_qmi_ims_session_stop(struct hotdog_qmi_ims_session *session);
int hotdog_qmi_ims_session_ssr(struct hotdog_qmi_ims_session *session);
int hotdog_qmi_ims_session_clear(struct hotdog_qmi_ims_session *session);
const struct hotdog_bearer_runtime *hotdog_qmi_ims_session_runtime(
	const struct hotdog_qmi_ims_session *session);

#endif
