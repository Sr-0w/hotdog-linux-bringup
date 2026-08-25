/* SPDX-License-Identifier: GPL-2.0-only */
#define _POSIX_C_SOURCE 200809L
#include "hotdog-network.h"

#include <arpa/inet.h>
#include <errno.h>
#include <string.h>

static bool registered(const struct hotdog_nas_subscription *subscription)
{
	return subscription->registration == HOTDOG_NAS_HOME ||
	       subscription->registration == HOTDOG_NAS_ROAMING;
}

static struct hotdog_bearer *find_bearer(struct hotdog_network *network,
					 unsigned int bearer_id)
{
	size_t i;

	for (i = 0; i < HOTDOG_NETWORK_MAX_BEARERS; i++)
		if (network->bearers[i].id == bearer_id &&
		    network->bearers[i].state != HOTDOG_BEARER_IDLE)
			return &network->bearers[i];
	return NULL;
}

const struct hotdog_bearer *hotdog_network_find_bearer(const struct hotdog_network *network,
						       unsigned int bearer_id)
{
	return find_bearer((struct hotdog_network *)network, bearer_id);
}

void hotdog_network_init(struct hotdog_network *network)
{
	memset(network, 0, sizeof(*network));
	network->next_bearer_id = 1;
}

int hotdog_network_set_subscription(struct hotdog_network *network,
				    unsigned int subscription, bool populated)
{
	if (!network || subscription >= HOTDOG_NETWORK_MAX_SUBSCRIPTIONS)
		return -EINVAL;
	memset(&network->subscriptions[subscription], 0,
	       sizeof(network->subscriptions[subscription]));
	network->subscriptions[subscription].populated = populated;
	return 0;
}

int hotdog_network_nas_update(struct hotdog_network *network, unsigned int subscription,
			      enum hotdog_nas_registration registration,
			      uint16_t mcc, uint16_t mnc, enum hotdog_nas_rat rat,
			      bool ps_attached, bool cs_attached)
{
	struct hotdog_nas_subscription *state;

	if (!network || subscription >= HOTDOG_NETWORK_MAX_SUBSCRIPTIONS ||
	    registration > HOTDOG_NAS_EMERGENCY || rat > HOTDOG_RAT_CDMA)
		return -EINVAL;
	state = &network->subscriptions[subscription];
	if (!state->populated)
		return -ENODEV;
	state->registration = registration;
	state->rat = rat;
	state->mcc = mcc;
	state->mnc = mnc;
	state->ps_attached = ps_attached;
	state->cs_attached = cs_attached;
	return 0;
}

int hotdog_network_set_default_data(struct hotdog_network *network,
				    unsigned int subscription, bool force)
{
	size_t i;

	if (!network || subscription >= HOTDOG_NETWORK_MAX_SUBSCRIPTIONS)
		return -EINVAL;
	if (!network->subscriptions[subscription].populated)
		return -ENODEV;
	if (network->default_data_subscription == subscription)
		return 0;
	for (i = 0; i < HOTDOG_NETWORK_MAX_BEARERS; i++) {
		struct hotdog_bearer *bearer = &network->bearers[i];

		if (bearer->state != HOTDOG_BEARER_STARTING &&
		    bearer->state != HOTDOG_BEARER_CONNECTED)
			continue;
		if (!force || bearer->packet_handle_v4 || bearer->packet_handle_v6)
			return -EBUSY;
	}
	for (i = 0; i < HOTDOG_NETWORK_MAX_BEARERS; i++) {
		struct hotdog_bearer *bearer = &network->bearers[i];

		if (bearer->state != HOTDOG_BEARER_STARTING &&
		    bearer->state != HOTDOG_BEARER_CONNECTED)
			continue;
		bearer->state = HOTDOG_BEARER_FAILED;
		bearer->error = ECANCELED;
		memset(&bearer->runtime, 0, sizeof(bearer->runtime));
	}
	network->default_data_subscription = subscription;
	return 0;
}

int hotdog_network_bearer_start(struct hotdog_network *network, unsigned int subscription,
				unsigned int profile, unsigned int mux_id,
				enum hotdog_ip_family family, enum hotdog_data_auth auth,
				const char *apn, unsigned int *bearer_id)
{
	struct hotdog_nas_subscription *nas;
	struct hotdog_bearer *available = NULL;
	size_t i;

	if (!network || !apn || !bearer_id ||
	    subscription >= HOTDOG_NETWORK_MAX_SUBSCRIPTIONS || family > HOTDOG_IP_V4V6 ||
	    auth > HOTDOG_AUTH_PAP_CHAP || !mux_id ||
	    !strnlen(apn, HOTDOG_NETWORK_APN_SIZE) ||
	    strnlen(apn, HOTDOG_NETWORK_APN_SIZE) >= HOTDOG_NETWORK_APN_SIZE)
		return -EINVAL;
	*bearer_id = 0;
	nas = &network->subscriptions[subscription];
	if (!nas->populated)
		return -ENODEV;
	if (network->default_data_subscription != subscription)
		return -EACCES;
	if (!registered(nas) || !nas->ps_attached)
		return -ENETDOWN;
	for (i = 0; i < HOTDOG_NETWORK_MAX_BEARERS; i++) {
		struct hotdog_bearer *bearer = &network->bearers[i];

		if (bearer->state == HOTDOG_BEARER_IDLE || bearer->state == HOTDOG_BEARER_FAILED) {
			if (!available)
				available = bearer;
			continue;
		}
		if (bearer->mux_id == mux_id)
			return -EADDRINUSE;
	}
	if (!available)
		return -ENOSPC;
	memset(available, 0, sizeof(*available));
	available->id = network->next_bearer_id++;
	available->subscription = subscription;
	available->profile = profile;
	available->mux_id = mux_id;
	available->generation = network->generation;
	available->family = family;
	available->auth = auth;
	available->state = HOTDOG_BEARER_STARTING;
	strcpy(available->apn, apn);
	*bearer_id = available->id;
	return 0;
}

static bool address_terminated(const char *address)
{
	return memchr(address, '\0', HOTDOG_NETWORK_ADDRESS_SIZE) != NULL;
}

static bool valid_address(const char *address, int family, bool required)
{
	unsigned char binary[sizeof(struct in6_addr)];

	if (!address_terminated(address))
		return false;
	if (!address[0])
		return !required;
	return inet_pton(family, address, binary) == 1;
}

static bool valid_dns(const char *address)
{
	return valid_address(address, AF_INET, false) ||
	       valid_address(address, AF_INET6, false);
}

static bool valid_runtime(const struct hotdog_bearer *bearer,
			  const struct hotdog_bearer_runtime *runtime)
{
	bool need_v4 = bearer->family == HOTDOG_IP_V4 ||
		bearer->family == HOTDOG_IP_V4V6;
	bool need_v6 = bearer->family == HOTDOG_IP_V6 ||
		bearer->family == HOTDOG_IP_V4V6;

	return runtime->mtu >= 576 && runtime->mtu <= 65535 &&
	       runtime->ipv6_prefix <= 128 &&
	       valid_address(runtime->ipv4, AF_INET, need_v4) &&
	       valid_address(runtime->ipv4_gateway, AF_INET, false) &&
	       valid_address(runtime->ipv4_dns1, AF_INET, false) &&
	       valid_address(runtime->ipv4_dns2, AF_INET, false) &&
	       valid_address(runtime->ipv6, AF_INET6, need_v6) &&
	       valid_address(runtime->ipv6_gateway, AF_INET6, false) &&
	       valid_address(runtime->ipv6_dns1, AF_INET6, false) &&
	       valid_address(runtime->ipv6_dns2, AF_INET6, false) &&
	       valid_dns(runtime->dns1) && valid_dns(runtime->dns2);
}

int hotdog_network_bearer_connected(struct hotdog_network *network, unsigned int bearer_id,
				    const struct hotdog_bearer_runtime *runtime)
{
	struct hotdog_bearer *bearer;

	if (!network || !runtime)
		return -EINVAL;
	bearer = find_bearer(network, bearer_id);
	if (!bearer)
		return -ENOENT;
	if (bearer->state != HOTDOG_BEARER_STARTING ||
	    bearer->generation != network->generation)
		return -EPROTO;
	if (!valid_runtime(bearer, runtime))
		return -EINVAL;
	if ((bearer->family == HOTDOG_IP_V4 || bearer->family == HOTDOG_IP_V4V6) &&
	    !bearer->packet_handle_v4)
		return -EINPROGRESS;
	if ((bearer->family == HOTDOG_IP_V6 || bearer->family == HOTDOG_IP_V4V6) &&
	    !bearer->packet_handle_v6)
		return -EINPROGRESS;
	bearer->runtime = *runtime;
	bearer->state = HOTDOG_BEARER_CONNECTED;
	return 0;
}

int hotdog_network_bearer_leg_started(struct hotdog_network *network,
				      unsigned int bearer_id,
				      enum hotdog_ip_family family,
				      uint32_t packet_handle)
{
	struct hotdog_bearer *bearer;
	uint32_t *target;

	if (!network || !packet_handle ||
	    (family != HOTDOG_IP_V4 && family != HOTDOG_IP_V6))
		return -EINVAL;
	bearer = find_bearer(network, bearer_id);
	if (!bearer)
		return -ENOENT;
	if (bearer->state != HOTDOG_BEARER_STARTING ||
	    bearer->generation != network->generation ||
	    (family == HOTDOG_IP_V4 && bearer->family == HOTDOG_IP_V6) ||
	    (family == HOTDOG_IP_V6 && bearer->family == HOTDOG_IP_V4))
		return -EPROTO;
	target = family == HOTDOG_IP_V4 ?
		&bearer->packet_handle_v4 : &bearer->packet_handle_v6;
	if (*target)
		return *target == packet_handle ? -EALREADY : -EBUSY;
	*target = packet_handle;
	return 0;
}

static void build_stop_plan(const struct hotdog_bearer *bearer,
			    struct hotdog_bearer_stop_plan *plan)
{
	memset(plan, 0, sizeof(*plan));
	if (bearer->packet_handle_v4) {
		plan->legs[plan->count].family = HOTDOG_IP_V4;
		plan->legs[plan->count++].packet_handle = bearer->packet_handle_v4;
	}
	if (bearer->packet_handle_v6) {
		plan->legs[plan->count].family = HOTDOG_IP_V6;
		plan->legs[plan->count++].packet_handle = bearer->packet_handle_v6;
	}
}

int hotdog_network_bearer_disconnect(struct hotdog_network *network,
				     unsigned int bearer_id,
				     struct hotdog_bearer_stop_plan *plan)
{
	struct hotdog_bearer *bearer;

	if (!network || !plan)
		return -EINVAL;
	bearer = find_bearer(network, bearer_id);
	if (!bearer)
		return -ENOENT;
	if (bearer->generation != network->generation ||
	    (bearer->state != HOTDOG_BEARER_STARTING &&
	     bearer->state != HOTDOG_BEARER_CONNECTED &&
	     bearer->state != HOTDOG_BEARER_FAILED))
		return -EPROTO;
	build_stop_plan(bearer, plan);
	bearer->error = 0;
	memset(&bearer->runtime, 0, sizeof(bearer->runtime));
	if (!plan->count)
		memset(bearer, 0, sizeof(*bearer));
	else
		bearer->state = HOTDOG_BEARER_STOPPING;
	return 0;
}

int hotdog_network_bearer_fail(struct hotdog_network *network,
			       unsigned int bearer_id, unsigned int error,
			       struct hotdog_bearer_stop_plan *plan)
{
	struct hotdog_bearer *bearer;

	if (!network || !error || !plan)
		return -EINVAL;
	bearer = find_bearer(network, bearer_id);
	if (!bearer)
		return -ENOENT;
	if (bearer->generation != network->generation ||
	    (bearer->state != HOTDOG_BEARER_STARTING &&
	     bearer->state != HOTDOG_BEARER_CONNECTED))
		return -EPROTO;
	build_stop_plan(bearer, plan);
	bearer->error = error;
	memset(&bearer->runtime, 0, sizeof(bearer->runtime));
	bearer->state = plan->count ? HOTDOG_BEARER_STOPPING : HOTDOG_BEARER_FAILED;
	return 0;
}

int hotdog_network_bearer_leg_stopped(struct hotdog_network *network,
				      unsigned int bearer_id,
				      enum hotdog_ip_family family,
				      uint32_t packet_handle)
{
	struct hotdog_bearer *bearer;
	uint32_t *target;

	if (!network || !packet_handle ||
	    (family != HOTDOG_IP_V4 && family != HOTDOG_IP_V6))
		return -EINVAL;
	bearer = find_bearer(network, bearer_id);
	if (!bearer)
		return -ENOENT;
	if (bearer->state != HOTDOG_BEARER_STOPPING ||
	    bearer->generation != network->generation)
		return -EPROTO;
	target = family == HOTDOG_IP_V4 ?
		&bearer->packet_handle_v4 : &bearer->packet_handle_v6;
	if (*target != packet_handle)
		return -ESTALE;
	*target = 0;
	if (!bearer->packet_handle_v4 && !bearer->packet_handle_v6) {
		if (bearer->error)
			bearer->state = HOTDOG_BEARER_FAILED;
		else
			memset(bearer, 0, sizeof(*bearer));
	}
	return 0;
}

int hotdog_network_bearer_stop(struct hotdog_network *network, unsigned int bearer_id)
{
	struct hotdog_bearer *bearer;

	if (!network)
		return -EINVAL;
	bearer = find_bearer(network, bearer_id);
	if (!bearer)
		return -ENOENT;
	if (bearer->state != HOTDOG_BEARER_STARTING &&
	    bearer->state != HOTDOG_BEARER_CONNECTED &&
	    bearer->state != HOTDOG_BEARER_STOPPING)
		return -EPROTO;
	if (bearer->packet_handle_v4 || bearer->packet_handle_v6)
		return -EBUSY;
	memset(bearer, 0, sizeof(*bearer));
	return 0;
}

void hotdog_network_ssr(struct hotdog_network *network)
{
	size_t i;

	if (!network)
		return;
	network->generation++;
	for (i = 0; i < HOTDOG_NETWORK_MAX_SUBSCRIPTIONS; i++) {
		bool populated = network->subscriptions[i].populated;

		memset(&network->subscriptions[i], 0, sizeof(network->subscriptions[i]));
		network->subscriptions[i].populated = populated;
	}
	for (i = 0; i < HOTDOG_NETWORK_MAX_BEARERS; i++) {
		if (network->bearers[i].state == HOTDOG_BEARER_IDLE)
			continue;
		network->bearers[i].state = HOTDOG_BEARER_FAILED;
		network->bearers[i].packet_handle_v4 = 0;
		network->bearers[i].packet_handle_v6 = 0;
		network->bearers[i].error = ENETRESET;
		memset(&network->bearers[i].runtime, 0, sizeof(network->bearers[i].runtime));
	}
}

const char *hotdog_nas_registration_name(enum hotdog_nas_registration registration)
{
	static const char *const names[] = {
		"none", "searching", "home", "roaming", "denied", "emergency",
	};
	return registration <= HOTDOG_NAS_EMERGENCY ? names[registration] : "invalid";
}

const char *hotdog_nas_rat_name(enum hotdog_nas_rat rat)
{
	static const char *const names[] = { "unknown", "gsm", "umts", "lte", "nr5g", "cdma" };
	return rat <= HOTDOG_RAT_CDMA ? names[rat] : "invalid";
}

const char *hotdog_ip_family_name(enum hotdog_ip_family family)
{
	static const char *const names[] = { "ipv4", "ipv6", "ipv4v6" };
	return family <= HOTDOG_IP_V4V6 ? names[family] : "invalid";
}

const char *hotdog_bearer_state_name(enum hotdog_bearer_state state)
{
	static const char *const names[] = { "idle", "starting", "connected", "stopping", "failed" };
	return state <= HOTDOG_BEARER_FAILED ? names[state] : "invalid";
}
