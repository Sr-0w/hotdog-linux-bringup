/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef HOTDOG_MBN_H
#define HOTDOG_MBN_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define HOTDOG_MBN_MAX_IINS 64
#define HOTDOG_MBN_MAX_PLMNS 64
#define HOTDOG_MBN_MAX_NAME 96
#define HOTDOG_MBN_MAX_LONG_IIN 512

struct hotdog_mbn_plmn {
	uint16_t mcc;
	uint16_t mnc;
};

struct hotdog_mbn_metadata {
	char carrier[HOTDOG_MBN_MAX_NAME];
	char long_iins[HOTDOG_MBN_MAX_LONG_IIN];
	uint32_t iins[HOTDOG_MBN_MAX_IINS];
	struct hotdog_mbn_plmn plmns[HOTDOG_MBN_MAX_PLMNS];
	size_t iin_count;
	size_t plmn_count;
	uint32_t qc_version;
	uint32_t oem_version;
	uint32_t capability;
	bool wildcard_iin;
	bool wildcard_plmn;
};

enum hotdog_mbn_match {
	HOTDOG_MBN_MATCH_NONE,
	HOTDOG_MBN_MATCH_WILDCARD,
	HOTDOG_MBN_MATCH_PLMN,
	HOTDOG_MBN_MATCH_IIN,
	HOTDOG_MBN_MATCH_LONG_IIN,
};

int hotdog_mbn_read(const char *path, struct hotdog_mbn_metadata *metadata);
enum hotdog_mbn_match hotdog_mbn_match(const struct hotdog_mbn_metadata *metadata,
				       const char *iccid, uint16_t mcc, uint16_t mnc);
const char *hotdog_mbn_match_name(enum hotdog_mbn_match match);

#endif
