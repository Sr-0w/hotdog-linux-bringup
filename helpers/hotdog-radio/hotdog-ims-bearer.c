/* SPDX-License-Identifier: GPL-2.0-only */
#define _POSIX_C_SOURCE 200809L
#include "hotdog-ims-bearer.h"

#include <errno.h>
#include <string.h>

static int purpose_mask(enum hotdog_bearer_purpose purpose, uint64_t *mask)
{
	switch (purpose) {
	case HOTDOG_BEARER_IMS:
		*mask = HOTDOG_APN_TYPE_IMS;
		return 0;
	case HOTDOG_BEARER_EMERGENCY:
		*mask = HOTDOG_APN_TYPE_EMERGENCY;
		return 0;
	case HOTDOG_BEARER_UT:
		*mask = HOTDOG_APN_TYPE_UT;
		return 0;
	case HOTDOG_BEARER_DEFAULT:
	case HOTDOG_BEARER_RCS:
		return -EOPNOTSUPP;
	}
	return -EINVAL;
}

static int profile_family(enum hotdog_profile_pdp_type pdp,
			  enum hotdog_ip_family *family)
{
	switch (pdp) {
	case HOTDOG_PROFILE_PDP_IPV4:
		*family = HOTDOG_IP_V4;
		return 0;
	case HOTDOG_PROFILE_PDP_IPV6:
		*family = HOTDOG_IP_V6;
		return 0;
	case HOTDOG_PROFILE_PDP_IPV4V6:
		*family = HOTDOG_IP_V4V6;
		return 0;
	case HOTDOG_PROFILE_PDP_PPP:
		return -EAFNOSUPPORT;
	}
	return -EINVAL;
}

static bool valid_apn(const char *apn)
{
	size_t length;

	if (!apn)
		return false;
	length = strnlen(apn, HOTDOG_NETWORK_APN_SIZE);
	return length > 0 && length < HOTDOG_NETWORK_APN_SIZE;
}

static bool matches(const struct hotdog_ims_profile *profile,
		    unsigned int subscription, uint64_t mask,
		    enum hotdog_bearer_purpose purpose, const char *expected_apn,
		    bool exact)
{
	if (!profile->is_3gpp || !profile->enabled || !profile->index ||
	    profile->index > UINT8_MAX || profile->subscription != subscription ||
	    !valid_apn(profile->apn) || !(profile->apn_type_mask & mask) ||
	    (exact && profile->apn_type_mask != mask) ||
	    (expected_apn && strcmp(profile->apn, expected_apn)))
		return false;
	if (purpose == HOTDOG_BEARER_IMS && !profile->pcscf_via_pco)
		return false;
	return true;
}

int hotdog_ims_profile_select(
	const struct hotdog_ims_profile *profiles, size_t count,
	unsigned int subscription, enum hotdog_bearer_purpose purpose,
	const char *expected_apn, struct hotdog_ims_profile_selection *selection)
{
	const struct hotdog_ims_profile *candidate = NULL;
	uint64_t mask;
	bool exact;
	size_t index;
	int result;

	if (!profiles || !selection || !count || count > HOTDOG_IMS_MAX_PROFILES ||
	    subscription >= HOTDOG_NETWORK_MAX_SUBSCRIPTIONS ||
	    (expected_apn && !valid_apn(expected_apn)))
		return -EINVAL;
	result = purpose_mask(purpose, &mask);
	if (result)
		return result;
	memset(selection, 0, sizeof(*selection));
	for (exact = true;; exact = false) {
		for (index = 0; index < count; index++) {
			if (!matches(&profiles[index], subscription, mask, purpose,
				     expected_apn, exact))
				continue;
			if (candidate)
				return -ENOTUNIQ;
			candidate = &profiles[index];
		}
		if (candidate || !exact)
			break;
	}
	if (!candidate)
		return -ENOENT;
	result = profile_family(candidate->pdp_type, &selection->family);
	if (result)
		return result;
	selection->subscription = subscription;
	selection->index = candidate->index;
	selection->apn_type_mask = candidate->apn_type_mask;
	selection->purpose = purpose;
	memcpy(selection->apn, candidate->apn, strlen(candidate->apn) + 1);
	return 0;
}
