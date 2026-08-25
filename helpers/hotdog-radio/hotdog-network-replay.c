/* SPDX-License-Identifier: GPL-2.0-only */
#include "hotdog-network.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int number(const char *text, unsigned long maximum, unsigned long *value)
{
	char *end;

	errno = 0;
	*value = strtoul(text, &end, 0);
	return errno || !*text || *end || *value > maximum ? -EINVAL : 0;
}

static enum hotdog_nas_registration registration(const char *name)
{
	if (!strcmp(name, "searching")) return HOTDOG_NAS_SEARCHING;
	if (!strcmp(name, "home")) return HOTDOG_NAS_HOME;
	if (!strcmp(name, "roaming")) return HOTDOG_NAS_ROAMING;
	if (!strcmp(name, "denied")) return HOTDOG_NAS_DENIED;
	if (!strcmp(name, "emergency")) return HOTDOG_NAS_EMERGENCY;
	return HOTDOG_NAS_NONE;
}

static enum hotdog_nas_rat rat(const char *name)
{
	if (!strcmp(name, "gsm")) return HOTDOG_RAT_GSM;
	if (!strcmp(name, "umts")) return HOTDOG_RAT_UMTS;
	if (!strcmp(name, "lte")) return HOTDOG_RAT_LTE;
	if (!strcmp(name, "nr5g")) return HOTDOG_RAT_NR5G;
	if (!strcmp(name, "cdma")) return HOTDOG_RAT_CDMA;
	return HOTDOG_RAT_UNKNOWN;
}

static enum hotdog_ip_family family(const char *name)
{
	if (!strcmp(name, "ipv6")) return HOTDOG_IP_V6;
	if (!strcmp(name, "ipv4v6")) return HOTDOG_IP_V4V6;
	return HOTDOG_IP_V4;
}

static enum hotdog_data_auth auth(const char *name)
{
	if (!strcmp(name, "pap")) return HOTDOG_AUTH_PAP;
	if (!strcmp(name, "chap")) return HOTDOG_AUTH_CHAP;
	if (!strcmp(name, "papchap")) return HOTDOG_AUTH_PAP_CHAP;
	return HOTDOG_AUTH_NONE;
}

static void copy_address(char *target, const char *source)
{
	if (strcmp(source, "-"))
		snprintf(target, HOTDOG_NETWORK_ADDRESS_SIZE, "%s", source);
}

static void status(const struct hotdog_network *network)
{
	size_t i;

	printf("status generation=%u dds=%u\n", network->generation,
	       network->default_data_subscription);
	for (i = 0; i < HOTDOG_NETWORK_MAX_SUBSCRIPTIONS; i++) {
		const struct hotdog_nas_subscription *sub = &network->subscriptions[i];

		if (!sub->populated)
			continue;
		printf("sub%zu=%s,%s,%u-%u,ps%u,cs%u\n", i,
		       hotdog_nas_registration_name(sub->registration),
		       hotdog_nas_rat_name(sub->rat), sub->mcc, sub->mnc,
		       sub->ps_attached, sub->cs_attached);
	}
	for (i = 0; i < HOTDOG_NETWORK_MAX_BEARERS; i++) {
		const struct hotdog_bearer *bearer = &network->bearers[i];

		if (bearer->state == HOTDOG_BEARER_IDLE)
			continue;
		printf("bearer%u=%s,sub%u,mux%u,%s,gen%u,h4=%u,h6=%u,error%u,mtu%u,v4=%s,v6=%s\n",
		       bearer->id, hotdog_bearer_state_name(bearer->state),
		       bearer->subscription, bearer->mux_id,
		       hotdog_ip_family_name(bearer->family), bearer->generation,
		       bearer->packet_handle_v4, bearer->packet_handle_v6, bearer->error,
		       bearer->runtime.mtu, bearer->runtime.ipv4[0] ? bearer->runtime.ipv4 : "-",
		       bearer->runtime.ipv6[0] ? bearer->runtime.ipv6 : "-");
	}
}

int main(void)
{
	struct hotdog_network network;
	char line[1024];
	unsigned int line_number = 0;

	hotdog_network_init(&network);
	while (fgets(line, sizeof(line), stdin)) {
		char *field[12] = { 0 };
		char *token;
		size_t count = 0;
		unsigned long a, b, c, d, e;
		int result;

		line_number++;
		if (line[0] == '#' || line[0] == '\n')
			continue;
		for (token = strtok(line, " \t\r\n"); token && count < 12;
		     token = strtok(NULL, " \t\r\n"))
			field[count++] = token;
		if (!count)
			continue;
		if (!strcmp(field[0], "SUB") && count == 3 &&
		    !number(field[1], 2, &a) && !number(field[2], 1, &b)) {
			printf("sub-result=%d\n", hotdog_network_set_subscription(&network, a, b));
			continue;
		}
		if (!strcmp(field[0], "NAS") && count == 8 &&
		    !number(field[1], 2, &a) && !number(field[3], UINT16_MAX, &b) &&
		    !number(field[4], UINT16_MAX, &c) && !number(field[6], 1, &d) &&
		    !number(field[7], 1, &e)) {
			struct hotdog_network_teardown teardown;

			result = hotdog_network_nas_reconcile(
				&network, a, registration(field[2]), b, c,
				rat(field[5]), d, e, &teardown);
			printf("nas-result=%d teardown=%zu\n", result,
			       result ? 0 : teardown.count);
			continue;
		}
		if (!strcmp(field[0], "DDS") && count == 3 &&
		    !number(field[1], 2, &a) && !number(field[2], 1, &b)) {
			printf("dds-result=%d\n", hotdog_network_set_default_data(&network, a, b));
			continue;
		}
		if (!strcmp(field[0], "START") && count == 7 &&
		    !number(field[1], 2, &a) && !number(field[2], UINT32_MAX, &b) &&
		    !number(field[3], UINT32_MAX, &c)) {
			unsigned int bearer_id = 0;

			result = hotdog_network_bearer_start(&network, a, b, c,
						      family(field[4]), auth(field[5]),
						      field[6], &bearer_id);
			printf("start-result=%d bearer=%u\n", result, bearer_id);
			continue;
		}
		if (!strcmp(field[0], "UP") && count == 7 &&
		    !number(field[1], UINT32_MAX, &a) && !number(field[2], 65535, &b)) {
			struct hotdog_bearer_runtime runtime = { .mtu = (unsigned int)b };

			copy_address(runtime.ipv4, field[3]);
			copy_address(runtime.ipv6, field[4]);
			copy_address(runtime.dns1, field[5]);
			copy_address(runtime.dns2, field[6]);
			printf("up-result=%d\n", hotdog_network_bearer_connected(&network, a, &runtime));
			continue;
		}
		if (!strcmp(field[0], "LEG_UP") && count == 4 &&
		    !number(field[1], UINT32_MAX, &a) &&
		    !number(field[3], UINT32_MAX, &b)) {
			printf("leg-up-result=%d\n", hotdog_network_bearer_leg_started(
				&network, a, family(field[2]), b));
			continue;
		}
		if (!strcmp(field[0], "STOP_BEGIN") && count == 2 &&
		    !number(field[1], UINT32_MAX, &a)) {
			struct hotdog_bearer_stop_plan plan;
			size_t index;

			result = hotdog_network_bearer_disconnect(&network, a, &plan);
			printf("stop-begin-result=%d legs=%zu", result,
			       result ? 0 : plan.count);
			if (!result)
				for (index = 0; index < plan.count; index++)
					printf(",%s:%u", hotdog_ip_family_name(plan.legs[index].family),
					       plan.legs[index].packet_handle);
			printf("\n");
			continue;
		}
		if (!strcmp(field[0], "FAIL") && count == 3 &&
		    !number(field[1], UINT32_MAX, &a) &&
		    !number(field[2], UINT32_MAX, &b)) {
			struct hotdog_bearer_stop_plan plan;

			result = hotdog_network_bearer_fail(&network, a, b, &plan);
			printf("fail-result=%d legs=%zu\n", result,
			       result ? 0 : plan.count);
			continue;
		}
		if (!strcmp(field[0], "LEG_DOWN") && count == 4 &&
		    !number(field[1], UINT32_MAX, &a) &&
		    !number(field[3], UINT32_MAX, &b)) {
			printf("leg-down-result=%d\n", hotdog_network_bearer_leg_stopped(
				&network, a, family(field[2]), b));
			continue;
		}
		if (!strcmp(field[0], "DOWN") && count == 2 &&
		    !number(field[1], UINT32_MAX, &a)) {
			printf("down-result=%d\n", hotdog_network_bearer_stop(&network, a));
			continue;
		}
		if (!strcmp(field[0], "SSR") && count == 1) {
			hotdog_network_ssr(&network);
			printf("ssr-generation=%u\n", network.generation);
			continue;
		}
		if (!strcmp(field[0], "STATUS") && count == 1) {
			status(&network);
			continue;
		}
		fprintf(stderr, "invalid network replay input at line %u\n", line_number);
		return 2;
	}
	return 0;
}
