/* SPDX-License-Identifier: GPL-2.0-only */
#include "hotdog-mbn.h"

#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv)
{
	struct hotdog_mbn_metadata metadata;
	enum hotdog_mbn_match match = HOTDOG_MBN_MATCH_NONE;
	int result;
	size_t i;

	if (argc != 2 && argc != 5) {
		fprintf(stderr, "usage: %s MCFG_MBN [ICCID MCC MNC]\n", argv[0]);
		return 2;
	}
	result = hotdog_mbn_read(argv[1], &metadata);
	if (result) {
		fprintf(stderr, "failed to parse MBN: %d\n", result);
		return 1;
	}
	if (argc == 5)
		match = hotdog_mbn_match(&metadata, argv[2],
					 (uint16_t)strtoul(argv[3], NULL, 10),
					 (uint16_t)strtoul(argv[4], NULL, 10));
	printf("carrier=%s\n", metadata.carrier);
	printf("qc_version=0x%08x\n", metadata.qc_version);
	printf("oem_version=0x%08x\n", metadata.oem_version);
	printf("capability=0x%08x\n", metadata.capability);
	printf("wildcard_iin=%u\n", metadata.wildcard_iin);
	printf("wildcard_plmn=%u\n", metadata.wildcard_plmn);
	for (i = 0; i < metadata.iin_count; i++)
		printf("iin[%zu]=%06u\n", i, metadata.iins[i]);
	for (i = 0; i < metadata.plmn_count; i++)
		printf("plmn[%zu]=%03u-%u\n", i, metadata.plmns[i].mcc, metadata.plmns[i].mnc);
	if (metadata.long_iins[0])
		printf("long_iins=%s\n", metadata.long_iins);
	if (argc == 5)
		printf("match=%s\n", hotdog_mbn_match_name(match));
	return 0;
}
