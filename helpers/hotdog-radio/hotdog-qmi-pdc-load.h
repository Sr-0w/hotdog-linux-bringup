/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef HOTDOG_QMI_PDC_LOAD_H
#define HOTDOG_QMI_PDC_LOAD_H

#include "hotdog-pdc-load.h"

#include <libqmi-glib.h>

int hotdog_qmi_pdc_load_input(uint32_t token, const struct hotdog_pdc_id *id,
			      uint32_t total_size, const unsigned char *chunk,
			      size_t chunk_size,
			      QmiMessagePdcLoadConfigInput **input);
int hotdog_qmi_pdc_delete_input(uint32_t token, const struct hotdog_pdc_id *id,
				QmiMessagePdcDeleteConfigInput **input);
int hotdog_qmi_pdc_decode_load(QmiIndicationPdcLoadConfigOutput *output,
			       struct hotdog_pdc_load *load,
			       uint16_t *remote_result);

#endif
