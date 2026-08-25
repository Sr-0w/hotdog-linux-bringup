/* SPDX-License-Identifier: GPL-2.0-only */
#include "hotdog-mcfg.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>

static void print_id(const struct hotdog_pdc_id *id)
{
	size_t index;

	for (index = 0; index < id->length; index++)
		printf("%02x", id->value[index]);
}

int main(int argc, char **argv)
{
	struct hotdog_pdc_catalog *catalog;
	struct hotdog_mcfg_report report;
	unsigned long mcc = 0, mnc = 0;
	size_t index, selected;
	int result;

	if (argc != 2 && argc != 5) {
		fprintf(stderr, "usage: %s MCFG_ROOT [ICCID MCC MNC]\n", argv[0]);
		return 2;
	}
	if (argc == 5) {
		char *end;

		mcc = strtoul(argv[3], &end, 10);
		if (*end || mcc > UINT16_MAX)
			return 2;
		mnc = strtoul(argv[4], &end, 10);
		if (*end || mnc > UINT16_MAX)
			return 2;
	}
	catalog = calloc(1, sizeof(*catalog));
	if (!catalog)
		return 2;
	result = hotdog_mcfg_catalog_load(argv[1], catalog, &report);
	if (result) {
		fprintf(stderr, "catalog-error=%d\n", result);
		free(catalog);
		return 1;
	}
	printf("catalog-count=%zu listed=%zu listed-missing=%zu\n",
	       catalog->count, report.listed, report.listed_missing);
	for (index = 0; index < catalog->count; index++) {
		printf("config%zu=path:%s id:", index, catalog->configs[index].path);
		print_id(&catalog->configs[index].id);
		printf(" carrier:%s version:0x%08x\n",
		       catalog->configs[index].metadata.carrier,
		       catalog->configs[index].version);
	}
	if (argc == 5) {
		result = hotdog_pdc_choose(catalog, argv[2], (uint16_t)mcc, (uint16_t)mnc,
					    &selected);
		printf("selection-result=%d", result);
		if (!result) {
			printf(" path:%s id:", catalog->configs[selected].path);
			print_id(&catalog->configs[selected].id);
		}
		printf("\n");
	}
	free(catalog);
	return 0;
}
