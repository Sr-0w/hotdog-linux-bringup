/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef HOTDOG_QMI_RMNET_H
#define HOTDOG_QMI_RMNET_H

#include <libqmi-glib.h>
#include <stddef.h>

#define HOTDOG_RMNET_IFNAME_SIZE 16

struct hotdog_qmi_rmnet_plan {
	QmiDataEndpointType endpoint_type;
	unsigned int endpoint_interface;
	QmiDeviceAddLinkFlags flags;
	char base_ifname[HOTDOG_RMNET_IFNAME_SIZE];
	char prefix[HOTDOG_RMNET_IFNAME_SIZE];
};

int hotdog_qmi_rmnet_plan_build(
	const char *driver, unsigned int interface_number,
	const char *base_ifname, const char *prefix,
	const char *tx_offload, const char *rx_offload,
	struct hotdog_qmi_rmnet_plan *plan);
int hotdog_qmi_rmnet_link_validate(
	const struct hotdog_qmi_rmnet_plan *plan,
	const char *ifname, unsigned int mux_id);

#endif
