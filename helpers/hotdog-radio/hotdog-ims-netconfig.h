/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef HOTDOG_IMS_NETCONFIG_H
#define HOTDOG_IMS_NETCONFIG_H

#include "hotdog-network.h"

#define HOTDOG_IMS_NETCONFIG_MAX_STEPS 12
#define HOTDOG_IMS_NETCONFIG_MAX_ARGS 12
#define HOTDOG_IMS_NETCONFIG_ARG_SIZE 64
#define HOTDOG_IMS_ROUTE_TABLE_BASE 12000
#define HOTDOG_IMS_RULE_PRIORITY_BASE 12000
#define HOTDOG_IMS_FWMARK_BASE 0x494d5300U

struct hotdog_ims_netconfig_command {
	unsigned int argc;
	char argv[HOTDOG_IMS_NETCONFIG_MAX_ARGS][HOTDOG_IMS_NETCONFIG_ARG_SIZE];
};

struct hotdog_ims_netconfig_step {
	struct hotdog_ims_netconfig_command apply;
	struct hotdog_ims_netconfig_command rollback;
	bool applied;
};

struct hotdog_ims_netconfig_plan {
	struct hotdog_ims_netconfig_step steps[HOTDOG_IMS_NETCONFIG_MAX_STEPS];
	size_t count;
	unsigned int subscription;
	unsigned int table;
	unsigned int priority;
	uint32_t fwmark;
	unsigned int apply_error;
	unsigned int rollback_error;
	bool residue;
};

typedef int (*hotdog_ims_netconfig_runner)(
	const struct hotdog_ims_netconfig_command *command, void *user_data);

int hotdog_ims_netconfig_plan_build(
	const char *ip_path, const char *base_ifname, bool base_was_up,
	const char *ifname, unsigned int subscription, enum hotdog_ip_family family,
	const struct hotdog_bearer_runtime *runtime,
	struct hotdog_ims_netconfig_plan *plan);
int hotdog_ims_netconfig_apply(
	struct hotdog_ims_netconfig_plan *plan,
	hotdog_ims_netconfig_runner runner, void *user_data);
int hotdog_ims_netconfig_rollback(
	struct hotdog_ims_netconfig_plan *plan,
	hotdog_ims_netconfig_runner runner, void *user_data);
int hotdog_ims_netconfig_spawn(
	const struct hotdog_ims_netconfig_command *command, void *user_data);

#endif
