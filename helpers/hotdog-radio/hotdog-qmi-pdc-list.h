/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef HOTDOG_QMI_PDC_LIST_H
#define HOTDOG_QMI_PDC_LIST_H

#include "hotdog-pdc.h"

#include <libqmi-glib.h>

struct hotdog_pdc_loaded_catalog {
	struct hotdog_pdc_id ids[HOTDOG_PDC_MAX_CONFIGS];
	size_t count;
};

int hotdog_qmi_pdc_list_input(uint32_t token, QmiMessagePdcListConfigsInput **input);
int hotdog_qmi_pdc_decode_list(QmiIndicationPdcListConfigsOutput *output,
			       uint32_t expected_token,
			       struct hotdog_pdc_loaded_catalog *loaded,
			       uint16_t *remote_result);

#endif
