/* SPDX-License-Identifier: GPL-2.0-only */
#include "hotdog-pdc.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int parse_uint(const char *text, unsigned long maximum, unsigned long *value)
{
	char *end;
	unsigned long parsed;

	errno = 0;
	parsed = strtoul(text, &end, 0);
	if (errno || !*text || *end || parsed > maximum)
		return -EINVAL;
	*value = parsed;
	return 0;
}

static int set_id(struct hotdog_pdc_id *id, const char *text)
{
	size_t length;

	memset(id, 0, sizeof(*id));
	if (!strcmp(text, "-"))
		return 0;
	length = strlen(text);
	if (!length || length > sizeof(id->value))
		return -EINVAL;
	memcpy(id->value, text, length);
	id->length = length;
	return 0;
}

static void print_id(const struct hotdog_pdc_id *id)
{
	if (!id->length) {
		printf("-");
		return;
	}
	printf("%.*s", (int)id->length, (const char *)id->value);
}

static void print_plan(const char *label, int result, const struct hotdog_pdc_plan *plan)
{
	size_t i;

	printf("%s-result=%d operations=%zu\n", label, result,
	       result ? 0 : plan->count);
	if (result)
		return;
	for (i = 0; i < plan->count; i++) {
		const struct hotdog_pdc_operation *operation = &plan->operations[i];

		printf("op%zu=%s,sub%u,expected%u,id=", i,
		       hotdog_pdc_operation_name(operation->type),
		       operation->subscription, operation->expected_indications);
		print_id(&operation->id);
		printf("\n");
	}
}

static int add_config(struct hotdog_pdc_catalog *catalog, char **fields, size_t count,
		      bool loaded)
{
	struct hotdog_pdc_config *config;
	unsigned long version, first, second;

	if (count < 4 || catalog->count >= HOTDOG_PDC_MAX_CONFIGS ||
	    parse_uint(fields[2], UINT32_MAX, &version))
		return -EINVAL;
	config = &catalog->configs[catalog->count];
	memset(config, 0, sizeof(*config));
	if (set_id(&config->id, fields[1]))
		return -EINVAL;
	config->version = (uint32_t)version;
	config->loaded = loaded;
	snprintf(config->metadata.carrier, sizeof(config->metadata.carrier), "%s", fields[1]);
	if (!strcmp(fields[3], "LONG") && count == 5) {
		if (strlen(fields[4]) >= sizeof(config->metadata.long_iins))
			return -EINVAL;
		strcpy(config->metadata.long_iins, fields[4]);
	} else if (!strcmp(fields[3], "IIN") && count == 5) {
		if (parse_uint(fields[4], 999999, &first))
			return -EINVAL;
		config->metadata.iins[0] = (uint32_t)first;
		config->metadata.iin_count = 1;
	} else if (!strcmp(fields[3], "PLMN") && count == 6) {
		if (parse_uint(fields[4], UINT16_MAX, &first) ||
		    parse_uint(fields[5], UINT16_MAX, &second))
			return -EINVAL;
		config->metadata.plmns[0].mcc = (uint16_t)first;
		config->metadata.plmns[0].mnc = (uint16_t)second;
		config->metadata.plmn_count = 1;
	} else if (!strcmp(fields[3], "WILDCARD") && count == 4) {
		config->metadata.wildcard_iin = true;
	} else {
		return -EINVAL;
	}
	catalog->count++;
	return 0;
}

static int add_subscription(struct hotdog_pdc_subscription *subscriptions,
			    size_t *subscription_count, char **fields, size_t count)
{
	struct hotdog_pdc_subscription *subscription;
	unsigned long index, mcc, mnc;

	if (count != 6 || parse_uint(fields[1], HOTDOG_PDC_MAX_SUBSCRIPTIONS - 1, &index) ||
	    parse_uint(fields[3], UINT16_MAX, &mcc) ||
	    parse_uint(fields[4], UINT16_MAX, &mnc) ||
	    strlen(fields[2]) >= HOTDOG_PDC_ICCID_SIZE)
		return -EINVAL;
	subscription = &subscriptions[index];
	memset(subscription, 0, sizeof(*subscription));
	subscription->populated = true;
	strcpy(subscription->iccid, fields[2]);
	subscription->mcc = (uint16_t)mcc;
	subscription->mnc = (uint16_t)mnc;
	if (set_id(&subscription->active, fields[5]))
		return -EINVAL;
	if (*subscription_count <= index)
		*subscription_count = index + 1;
	return 0;
}

int main(void)
{
	struct hotdog_pdc_catalog catalog = { 0 };
	struct hotdog_pdc_subscription subscriptions[HOTDOG_PDC_MAX_SUBSCRIPTIONS] = { 0 };
	struct hotdog_pdc_id resident_ids[HOTDOG_PDC_MAX_CONFIGS] = { 0 };
	struct hotdog_pdc_plan plan;
	size_t subscription_count = 0;
	size_t resident_count = 0;
	char line[1024];
	unsigned int line_number = 0;

	while (fgets(line, sizeof(line), stdin)) {
		char *fields[8] = { 0 };
		char *token;
		size_t count = 0;

		line_number++;
		if (line[0] == '#' || line[0] == '\n')
			continue;
		for (token = strtok(line, " \t\r\n"); token && count < 8;
		     token = strtok(NULL, " \t\r\n"))
			fields[count++] = token;
		if (!count)
			continue;
		if (!strcmp(fields[0], "CONFIG") || !strcmp(fields[0], "CONFIG_UNLOADED")) {
			if (add_config(&catalog, fields, count, !strcmp(fields[0], "CONFIG")))
				goto malformed;
			continue;
		}
		if (!strcmp(fields[0], "SUB")) {
			if (add_subscription(subscriptions, &subscription_count, fields, count))
				goto malformed;
			continue;
		}
		if (!strcmp(fields[0], "PLAN") && count == 1) {
			int result = hotdog_pdc_plan_activation(&catalog, subscriptions,
							 subscription_count, &plan);
			print_plan("plan", result, &plan);
			continue;
		}
		if (!strcmp(fields[0], "ACTIVE") && count == 3) {
			unsigned long index;

			if (parse_uint(fields[1], HOTDOG_PDC_MAX_SUBSCRIPTIONS - 1, &index) ||
			    index >= subscription_count ||
			    set_id(&subscriptions[index].active, fields[2]))
				goto malformed;
			continue;
		}
		if (!strcmp(fields[0], "PENDING") && count == 3) {
			unsigned long index;

			if (parse_uint(fields[1], HOTDOG_PDC_MAX_SUBSCRIPTIONS - 1, &index) ||
			    index >= subscription_count ||
			    set_id(&subscriptions[index].pending, fields[2]))
				goto malformed;
			continue;
		}
		if (!strcmp(fields[0], "RESIDENT") && count == 2) {
			if (resident_count >= HOTDOG_PDC_MAX_CONFIGS ||
			    set_id(&resident_ids[resident_count], fields[1]))
				goto malformed;
			resident_count++;
			continue;
		}
		if (!strcmp(fields[0], "CLEANUP") && count == 1) {
			size_t unmatched = 0;
			int result = hotdog_pdc_plan_cleanup(
				&catalog, resident_ids, resident_count, subscriptions,
				subscription_count, &plan, &unmatched);

			printf("cleanup-unmatched=%zu\n", unmatched);
			print_plan("cleanup", result, &plan);
			continue;
		}
		if (!strcmp(fields[0], "VERIFY") && count == 1) {
			printf("verified=%u\n", hotdog_pdc_plan_verified(subscriptions,
								      subscription_count));
			continue;
		}
		if (!strcmp(fields[0], "ROLLBACK") && count == 1) {
			int result = hotdog_pdc_plan_rollback(subscriptions, subscription_count,
						       &plan);
			print_plan("rollback", result, &plan);
			continue;
		}
malformed:
		fprintf(stderr, "invalid PDC replay input at line %u\n", line_number);
		return 2;
	}
	return 0;
}
