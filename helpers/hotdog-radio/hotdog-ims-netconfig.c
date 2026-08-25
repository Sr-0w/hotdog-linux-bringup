/* SPDX-License-Identifier: GPL-2.0-only */
#define _POSIX_C_SOURCE 200809L
#include "hotdog-ims-netconfig.h"

#include <arpa/inet.h>
#include <errno.h>
#include <gio/gio.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

static bool valid_ifname(const char *name)
{
	size_t index, length;

	if (!name)
		return false;
	length = strnlen(name, 16);
	if (!length || length >= 16 || name[0] == '-')
		return false;
	for (index = 0; index < length; index++)
		if (!((name[index] >= 'a' && name[index] <= 'z') ||
		      (name[index] >= 'A' && name[index] <= 'Z') ||
		      (name[index] >= '0' && name[index] <= '9') ||
		      name[index] == '_' || name[index] == '-'))
			return false;
	return true;
}

static bool valid_path(const char *path)
{
	size_t index, length;

	if (!path || path[0] != '/')
		return false;
	length = strnlen(path, HOTDOG_IMS_NETCONFIG_ARG_SIZE);
	if (length < 2 || length >= HOTDOG_IMS_NETCONFIG_ARG_SIZE)
		return false;
	for (index = 1; index < length; index++)
		if (!((path[index] >= 'a' && path[index] <= 'z') ||
		      (path[index] >= 'A' && path[index] <= 'Z') ||
		      (path[index] >= '0' && path[index] <= '9') ||
		      path[index] == '/' || path[index] == '_' || path[index] == '-'))
			return false;
	return true;
}

static int command_set(struct hotdog_ims_netconfig_command *command,
		       unsigned int argc, ...)
{
	va_list arguments;
	unsigned int index;

	if (!command || !argc || argc > HOTDOG_IMS_NETCONFIG_MAX_ARGS)
		return -EINVAL;
	memset(command, 0, sizeof(*command));
	command->argc = argc;
	va_start(arguments, argc);
	for (index = 0; index < argc; index++) {
		const char *value = va_arg(arguments, const char *);

		if (!value || !value[0] ||
		    strnlen(value, HOTDOG_IMS_NETCONFIG_ARG_SIZE) >=
			HOTDOG_IMS_NETCONFIG_ARG_SIZE) {
			va_end(arguments);
			memset(command, 0, sizeof(*command));
			return -EINVAL;
		}
		memcpy(command->argv[index], value, strlen(value) + 1);
	}
	va_end(arguments);
	return 0;
}

static int add_step(struct hotdog_ims_netconfig_plan *plan,
		    const struct hotdog_ims_netconfig_command *apply,
		    const struct hotdog_ims_netconfig_command *rollback)
{
	if (plan->count == HOTDOG_IMS_NETCONFIG_MAX_STEPS)
		return -EOVERFLOW;
	plan->steps[plan->count].apply = *apply;
	plan->steps[plan->count].rollback = *rollback;
	plan->count++;
	return 0;
}

static int link_step(struct hotdog_ims_netconfig_plan *plan, const char *ip,
		     const char *ifname, const char *mtu)
{
	struct hotdog_ims_netconfig_command apply, rollback;
	int result;

	if (mtu)
		result = command_set(&apply, 8, ip, "link", "set", "dev", ifname,
				     "mtu", mtu, "up");
	else
		result = command_set(&apply, 6, ip, "link", "set", "dev", ifname, "up");
	if (!result)
		result = command_set(&rollback, 6, ip, "link", "set", "dev", ifname,
				     "down");
	return result ? result : add_step(plan, &apply, &rollback);
}

static int add_address_step(struct hotdog_ims_netconfig_plan *plan, const char *ip,
			    const char *family, const char *address,
			    const char *ifname)
{
	struct hotdog_ims_netconfig_command apply, rollback;
	int result;

	if (!strcmp(family, "-6"))
		result = command_set(&apply, 8, ip, family, "address", "add", address,
				     "dev", ifname, "nodad");
	else
		result = command_set(&apply, 7, ip, family, "address", "add", address,
				     "dev", ifname);
	if (!result)
		result = command_set(&rollback, 7, ip, family, "address", "del", address,
				     "dev", ifname);
	return result ? result : add_step(plan, &apply, &rollback);
}

static int add_route_step(struct hotdog_ims_netconfig_plan *plan, const char *ip,
			  const char *family, const char *table,
			  const char *gateway, const char *ifname)
{
	struct hotdog_ims_netconfig_command apply, rollback;
	int result;

	if (gateway && gateway[0])
		result = command_set(&apply, 11, ip, family, "route", "add", "table",
				     table, "default", "via", gateway, "dev", ifname);
	else
		result = command_set(&apply, 9, ip, family, "route", "add", "table",
				     table, "default", "dev", ifname);
	if (!result)
		result = command_set(&rollback, 7, ip, family, "route", "del", "table",
				     table, "default");
	return result ? result : add_step(plan, &apply, &rollback);
}

static int add_rule_step(struct hotdog_ims_netconfig_plan *plan, const char *ip,
			 const char *family, const char *priority,
			 const char *mark, const char *table)
{
	struct hotdog_ims_netconfig_command apply, rollback;
	int result = command_set(&apply, 11, ip, family, "rule", "add", "priority",
				 priority, "fwmark", mark, "lookup", table);

	if (!result)
		result = command_set(&rollback, 8, ip, family, "rule", "del", "priority",
				     priority, "fwmark", mark);
	return result ? result : add_step(plan, &apply, &rollback);
}

int hotdog_ims_netconfig_plan_build(
	const char *ip_path, const char *base_ifname, bool base_was_up,
	const char *ifname, unsigned int subscription, enum hotdog_ip_family family,
	const struct hotdog_bearer_runtime *runtime,
	struct hotdog_ims_netconfig_plan *plan)
{
	char mtu[16], table[16], priority[16], mark[16];
	char ipv4[HOTDOG_NETWORK_ADDRESS_SIZE + 8];
	char ipv6[HOTDOG_NETWORK_ADDRESS_SIZE + 8];
	bool need_v4 = family == HOTDOG_IP_V4 || family == HOTDOG_IP_V4V6;
	bool need_v6 = family == HOTDOG_IP_V6 || family == HOTDOG_IP_V4V6;
	unsigned char binary[sizeof(struct in6_addr)];
	int result;

	if (!valid_path(ip_path) || !valid_ifname(base_ifname) || !valid_ifname(ifname) ||
	    !strcmp(base_ifname, ifname) || !runtime || !plan ||
	    subscription >= HOTDOG_NETWORK_MAX_SUBSCRIPTIONS || family > HOTDOG_IP_V4V6 ||
	    runtime->mtu < 576 || runtime->mtu > 65535 ||
	    (need_v4 && (!runtime->ipv4[0] || !runtime->ipv4_prefix ||
			 runtime->ipv4_prefix > 32 ||
			 inet_pton(AF_INET, runtime->ipv4, binary) != 1)) ||
	    (need_v6 && (!runtime->ipv6[0] || !runtime->ipv6_prefix ||
			 runtime->ipv6_prefix > 128 ||
			 inet_pton(AF_INET6, runtime->ipv6, binary) != 1)) ||
	    (runtime->ipv4_gateway[0] &&
	     inet_pton(AF_INET, runtime->ipv4_gateway, binary) != 1) ||
	    (runtime->ipv6_gateway[0] &&
	     inet_pton(AF_INET6, runtime->ipv6_gateway, binary) != 1))
		return -EINVAL;
	memset(plan, 0, sizeof(*plan));
	plan->subscription = subscription;
	plan->table = HOTDOG_IMS_ROUTE_TABLE_BASE + subscription;
	plan->priority = HOTDOG_IMS_RULE_PRIORITY_BASE + subscription;
	plan->fwmark = HOTDOG_IMS_FWMARK_BASE | subscription;
	snprintf(mtu, sizeof(mtu), "%u", runtime->mtu);
	snprintf(table, sizeof(table), "%u", plan->table);
	snprintf(priority, sizeof(priority), "%u", plan->priority);
	snprintf(mark, sizeof(mark), "0x%08x", plan->fwmark);
	snprintf(ipv4, sizeof(ipv4), "%s/%u", runtime->ipv4, runtime->ipv4_prefix);
	snprintf(ipv6, sizeof(ipv6), "%s/%u", runtime->ipv6, runtime->ipv6_prefix);
	if (!base_was_up) {
		result = link_step(plan, ip_path, base_ifname, NULL);
		if (result) return result;
	}
	result = link_step(plan, ip_path, ifname, mtu);
	if (!result && need_v4)
		result = add_address_step(plan, ip_path, "-4", ipv4, ifname);
	if (!result && need_v4)
		result = add_route_step(plan, ip_path, "-4", table,
					runtime->ipv4_gateway, ifname);
	if (!result && need_v4)
		result = add_rule_step(plan, ip_path, "-4", priority, mark, table);
	if (!result && need_v6)
		result = add_address_step(plan, ip_path, "-6", ipv6, ifname);
	if (!result && need_v6)
		result = add_route_step(plan, ip_path, "-6", table,
					runtime->ipv6_gateway, ifname);
	if (!result && need_v6)
		result = add_rule_step(plan, ip_path, "-6", priority, mark, table);
	return result;
}

int hotdog_ims_netconfig_rollback(
	struct hotdog_ims_netconfig_plan *plan,
	hotdog_ims_netconfig_runner runner, void *user_data)
{
	size_t index;
	int result = 0;

	if (!plan || !runner)
		return -EINVAL;
	for (index = plan->count; index > 0; index--) {
		struct hotdog_ims_netconfig_step *step = &plan->steps[index - 1];
		int current;

		if (!step->applied)
			continue;
		current = runner(&step->rollback, user_data);
		if (!current)
			step->applied = false;
		else if (!result)
			result = current;
	}
	plan->residue = result != 0;
	plan->rollback_error = result ? (unsigned int)-result : 0;
	return result;
}

int hotdog_ims_netconfig_apply(
	struct hotdog_ims_netconfig_plan *plan,
	hotdog_ims_netconfig_runner runner, void *user_data)
{
	size_t index;

	if (!plan || !runner || !plan->count || plan->residue)
		return -EINVAL;
	for (index = 0; index < plan->count; index++)
		if (plan->steps[index].applied)
			return -EBUSY;
	for (index = 0; index < plan->count; index++) {
		int result = runner(&plan->steps[index].apply, user_data);

		if (result) {
			int rollback;

			plan->apply_error = (unsigned int)-result;
			rollback = hotdog_ims_netconfig_rollback(plan, runner, user_data);
			return rollback ? -EUCLEAN : result;
		}
		plan->steps[index].applied = true;
	}
	return 0;
}

int hotdog_ims_netconfig_spawn(
	const struct hotdog_ims_netconfig_command *command, void *user_data)
{
	gchar *arguments[HOTDOG_IMS_NETCONFIG_MAX_ARGS + 1] = { NULL };
	GError *error = NULL;
	gint wait_status = 0;
	unsigned int index;

	(void)user_data;
	if (!command || !command->argc || command->argc > HOTDOG_IMS_NETCONFIG_MAX_ARGS)
		return -EINVAL;
	for (index = 0; index < command->argc; index++)
		arguments[index] = (gchar *)command->argv[index];
	if (!g_spawn_sync(NULL, arguments, NULL,
			  G_SPAWN_STDOUT_TO_DEV_NULL | G_SPAWN_STDERR_TO_DEV_NULL,
			  NULL, NULL, NULL, NULL, &wait_status, &error)) {
		g_clear_error(&error);
		return -EIO;
	}
	if (!g_spawn_check_wait_status(wait_status, &error)) {
		g_clear_error(&error);
		return -EREMOTEIO;
	}
	return 0;
}
