/* SPDX-License-Identifier: GPL-2.0-only */
#define _POSIX_C_SOURCE 200809L
#include "hotdog-qmi-rmnet.h"

#include <errno.h>
#include <stdbool.h>
#include <string.h>

enum offload_version {
	OFFLOAD_NONE,
	OFFLOAD_MAPV4,
	OFFLOAD_MAPV5,
};

static int parse_offload(const char *value, enum offload_version *version)
{
	size_t length;

	if (!value || !value[0]) {
		*version = OFFLOAD_NONE;
		return 0;
	}
	length = strcspn(value, "\r\n");
	if (value[length] && value[length] != '\r' && value[length] != '\n')
		return -EPROTO;
	if (length == 5 && !memcmp(value, "MAPv4", 5))
		*version = OFFLOAD_MAPV4;
	else if (length == 5 && !memcmp(value, "MAPv5", 5))
		*version = OFFLOAD_MAPV5;
	else
		return -EPROTO;
	while (value[length]) {
		if (value[length] != '\r' && value[length] != '\n')
			return -EPROTO;
		length++;
	}
	return 0;
}

static int endpoint(const char *driver, unsigned int interface_number,
		    QmiDataEndpointType *type, unsigned int *interface)
{
	if (!strcmp(driver, "ipa")) {
		*type = QMI_DATA_ENDPOINT_TYPE_EMBEDDED;
		*interface = 1;
		return interface_number && interface_number != 1 ? -EINVAL : 0;
	}
	if (!strcmp(driver, "mhi_net")) {
		*type = QMI_DATA_ENDPOINT_TYPE_PCIE;
		*interface = 4;
		return interface_number && interface_number != 4 ? -EINVAL : 0;
	}
	if (!strcmp(driver, "qmi_wwan")) {
		if (!interface_number)
			return -EINVAL;
		*type = QMI_DATA_ENDPOINT_TYPE_HSUSB;
		*interface = interface_number;
		return 0;
	}
	if (!strcmp(driver, "bam-dmux")) {
		*type = QMI_DATA_ENDPOINT_TYPE_BAM_DMUX;
		*interface = 0;
		return interface_number ? -EINVAL : 0;
	}
	return -EOPNOTSUPP;
}

static bool valid_ifname(const char *name)
{
	size_t index, length;

	if (!name)
		return false;
	length = strnlen(name, HOTDOG_RMNET_IFNAME_SIZE);
	if (!length || length >= HOTDOG_RMNET_IFNAME_SIZE || name[0] == '-')
		return false;
	for (index = 0; index < length; index++)
		if (!((name[index] >= 'a' && name[index] <= 'z') ||
		      (name[index] >= 'A' && name[index] <= 'Z') ||
		      (name[index] >= '0' && name[index] <= '9') ||
		      name[index] == '_' || name[index] == '-') )
			return false;
	return true;
}

int hotdog_qmi_rmnet_plan_build(
	const char *driver, unsigned int interface_number,
	const char *base_ifname, const char *prefix,
	const char *tx_offload, const char *rx_offload,
	struct hotdog_qmi_rmnet_plan *plan)
{
	enum offload_version tx, rx;
	int result;

	if (!driver || !valid_ifname(base_ifname) || !valid_ifname(prefix) || !plan)
		return -EINVAL;
	memset(plan, 0, sizeof(*plan));
	result = endpoint(driver, interface_number, &plan->endpoint_type,
			  &plan->endpoint_interface);
	if (!result)
		result = parse_offload(tx_offload, &tx);
	if (!result)
		result = parse_offload(rx_offload, &rx);
	if (result)
		return result;
	if (tx == OFFLOAD_MAPV4)
		plan->flags |= QMI_DEVICE_ADD_LINK_FLAGS_EGRESS_MAP_CKSUMV4;
	else if (tx == OFFLOAD_MAPV5)
		plan->flags |= QMI_DEVICE_ADD_LINK_FLAGS_EGRESS_MAP_CKSUMV5;
	if (rx == OFFLOAD_MAPV4)
		plan->flags |= QMI_DEVICE_ADD_LINK_FLAGS_INGRESS_MAP_CKSUMV4;
	else if (rx == OFFLOAD_MAPV5)
		plan->flags |= QMI_DEVICE_ADD_LINK_FLAGS_INGRESS_MAP_CKSUMV5;
	memcpy(plan->base_ifname, base_ifname, strlen(base_ifname) + 1);
	memcpy(plan->prefix, prefix, strlen(prefix) + 1);
	return 0;
}

int hotdog_qmi_rmnet_link_validate(
	const struct hotdog_qmi_rmnet_plan *plan,
	const char *ifname, unsigned int mux_id)
{
	if (!plan || !valid_ifname(plan->base_ifname) || !valid_ifname(plan->prefix) ||
	    !valid_ifname(ifname) || !strcmp(ifname, plan->base_ifname) ||
	    mux_id < QMI_DEVICE_MUX_ID_MIN || mux_id > QMI_DEVICE_MUX_ID_MAX)
		return -EINVAL;
	return 0;
}
