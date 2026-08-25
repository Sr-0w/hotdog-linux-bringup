/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef HOTDOG_QMI_PDC_DISPATCH_H
#define HOTDOG_QMI_PDC_DISPATCH_H

#include "hotdog-mcfg.h"
#include "hotdog-pdc.h"
#include "hotdog-pdc-load.h"

#include <libqmi-glib.h>

enum hotdog_qmi_pdc_request_type {
	HOTDOG_QMI_PDC_REQUEST_LOCAL,
	HOTDOG_QMI_PDC_REQUEST_LOAD,
	HOTDOG_QMI_PDC_REQUEST_SET,
	HOTDOG_QMI_PDC_REQUEST_ACTIVATE,
	HOTDOG_QMI_PDC_REQUEST_DEACTIVATE,
	HOTDOG_QMI_PDC_REQUEST_DELETE,
	HOTDOG_QMI_PDC_REQUEST_VERIFY,
	HOTDOG_QMI_PDC_REQUEST_SWITCH,
};

struct hotdog_qmi_pdc_request {
	enum hotdog_qmi_pdc_request_type type;
	struct hotdog_pdc_operation operation;
	struct hotdog_mcfg_profile profile;
	struct hotdog_pdc_load load_state;
	uint32_t token;
	union {
		QmiMessagePdcLoadConfigInput *load;
		QmiMessagePdcSetSelectedConfigInput *set;
		QmiMessagePdcActivateConfigInput *activate;
		QmiMessagePdcDeactivateConfigInput *deactivate;
		QmiMessagePdcDeleteConfigInput *delete_config;
		QmiMessagePdcGetSelectedConfigInput *verify;
	} input;
};

int hotdog_qmi_pdc_request_prepare(
	struct hotdog_qmi_pdc_request *request,
	const struct hotdog_pdc_operation *operation,
	const struct hotdog_pdc_catalog *catalog, const char *mcfg_root,
	uint32_t token);
int hotdog_qmi_pdc_request_load_next(struct hotdog_qmi_pdc_request *request,
				     uint32_t token);
void hotdog_qmi_pdc_request_clear(struct hotdog_qmi_pdc_request *request);

#endif
