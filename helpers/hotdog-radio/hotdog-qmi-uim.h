/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef HOTDOG_QMI_UIM_H
#define HOTDOG_QMI_UIM_H

#include "hotdog-uim.h"

#include <libqmi-glib.h>

int hotdog_qmi_uim_decode(QmiMessageUimGetCardStatusOutput *output,
			  struct hotdog_uim_inventory *inventory);

#endif
