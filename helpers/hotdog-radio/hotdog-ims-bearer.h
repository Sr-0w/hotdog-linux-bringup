/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef HOTDOG_IMS_BEARER_H
#define HOTDOG_IMS_BEARER_H

#include "hotdog-network.h"

#define HOTDOG_IMS_MAX_PROFILES 64

#define HOTDOG_APN_TYPE_IMS       (1ULL << 1)
#define HOTDOG_APN_TYPE_EMERGENCY (1ULL << 9)
#define HOTDOG_APN_TYPE_UT        (1ULL << 10)

enum hotdog_profile_pdp_type {
	HOTDOG_PROFILE_PDP_IPV4,
	HOTDOG_PROFILE_PDP_PPP,
	HOTDOG_PROFILE_PDP_IPV6,
	HOTDOG_PROFILE_PDP_IPV4V6,
};

struct hotdog_ims_profile {
	unsigned int subscription;
	unsigned int index;
	bool is_3gpp;
	bool enabled;
	bool pcscf_via_pco;
	uint64_t apn_type_mask;
	enum hotdog_profile_pdp_type pdp_type;
	char apn[HOTDOG_NETWORK_APN_SIZE];
};

struct hotdog_ims_profile_selection {
	unsigned int subscription;
	unsigned int index;
	uint64_t apn_type_mask;
	enum hotdog_ip_family family;
	enum hotdog_bearer_purpose purpose;
	char apn[HOTDOG_NETWORK_APN_SIZE];
};

int hotdog_ims_profile_select(
	const struct hotdog_ims_profile *profiles, size_t count,
	unsigned int subscription, enum hotdog_bearer_purpose purpose,
	const char *expected_apn, struct hotdog_ims_profile_selection *selection);

#endif
