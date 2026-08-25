/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef HOTDOG_NETWORK_H
#define HOTDOG_NETWORK_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define HOTDOG_NETWORK_MAX_SUBSCRIPTIONS 3
#define HOTDOG_NETWORK_MAX_BEARERS 8
#define HOTDOG_NETWORK_APN_SIZE 101
#define HOTDOG_NETWORK_ADDRESS_SIZE 48

enum hotdog_nas_registration {
	HOTDOG_NAS_NONE,
	HOTDOG_NAS_SEARCHING,
	HOTDOG_NAS_HOME,
	HOTDOG_NAS_ROAMING,
	HOTDOG_NAS_DENIED,
	HOTDOG_NAS_EMERGENCY,
};

enum hotdog_nas_rat {
	HOTDOG_RAT_UNKNOWN,
	HOTDOG_RAT_GSM,
	HOTDOG_RAT_UMTS,
	HOTDOG_RAT_LTE,
	HOTDOG_RAT_NR5G,
	HOTDOG_RAT_CDMA,
};

enum hotdog_ip_family {
	HOTDOG_IP_V4,
	HOTDOG_IP_V6,
	HOTDOG_IP_V4V6,
};

enum hotdog_data_auth {
	HOTDOG_AUTH_NONE,
	HOTDOG_AUTH_PAP,
	HOTDOG_AUTH_CHAP,
	HOTDOG_AUTH_PAP_CHAP,
};

enum hotdog_bearer_state {
	HOTDOG_BEARER_IDLE,
	HOTDOG_BEARER_STARTING,
	HOTDOG_BEARER_CONNECTED,
	HOTDOG_BEARER_STOPPING,
	HOTDOG_BEARER_FAILED,
};

struct hotdog_nas_subscription {
	bool populated;
	enum hotdog_nas_registration registration;
	enum hotdog_nas_rat rat;
	uint16_t mcc;
	uint16_t mnc;
	bool ps_attached;
	bool cs_attached;
};

struct hotdog_bearer_runtime {
	char ipv4[HOTDOG_NETWORK_ADDRESS_SIZE];
	char ipv4_gateway[HOTDOG_NETWORK_ADDRESS_SIZE];
	char ipv4_dns1[HOTDOG_NETWORK_ADDRESS_SIZE];
	char ipv4_dns2[HOTDOG_NETWORK_ADDRESS_SIZE];
	char ipv6[HOTDOG_NETWORK_ADDRESS_SIZE];
	char ipv6_gateway[HOTDOG_NETWORK_ADDRESS_SIZE];
	char ipv6_dns1[HOTDOG_NETWORK_ADDRESS_SIZE];
	char ipv6_dns2[HOTDOG_NETWORK_ADDRESS_SIZE];
	unsigned int ipv6_prefix;
	char dns1[HOTDOG_NETWORK_ADDRESS_SIZE];
	char dns2[HOTDOG_NETWORK_ADDRESS_SIZE];
	unsigned int mtu;
};

struct hotdog_bearer {
	unsigned int id;
	unsigned int subscription;
	unsigned int profile;
	unsigned int mux_id;
	unsigned int generation;
	enum hotdog_ip_family family;
	enum hotdog_data_auth auth;
	enum hotdog_bearer_state state;
	uint32_t packet_handle_v4;
	uint32_t packet_handle_v6;
	unsigned int error;
	char apn[HOTDOG_NETWORK_APN_SIZE];
	struct hotdog_bearer_runtime runtime;
};

struct hotdog_bearer_stop_leg {
	enum hotdog_ip_family family;
	uint32_t packet_handle;
};

struct hotdog_bearer_stop_plan {
	size_t count;
	struct hotdog_bearer_stop_leg legs[2];
};

struct hotdog_network_teardown_item {
	unsigned int bearer_id;
	struct hotdog_bearer_stop_plan plan;
};

struct hotdog_network_teardown {
	size_t count;
	struct hotdog_network_teardown_item items[HOTDOG_NETWORK_MAX_BEARERS];
};

struct hotdog_network {
	struct hotdog_nas_subscription subscriptions[HOTDOG_NETWORK_MAX_SUBSCRIPTIONS];
	struct hotdog_bearer bearers[HOTDOG_NETWORK_MAX_BEARERS];
	unsigned int default_data_subscription;
	unsigned int next_bearer_id;
	unsigned int generation;
};

void hotdog_network_init(struct hotdog_network *network);
int hotdog_network_set_subscription(struct hotdog_network *network,
				    unsigned int subscription, bool populated);
int hotdog_network_nas_update(struct hotdog_network *network, unsigned int subscription,
			      enum hotdog_nas_registration registration,
			      uint16_t mcc, uint16_t mnc, enum hotdog_nas_rat rat,
			      bool ps_attached, bool cs_attached);
int hotdog_network_nas_reconcile(
	struct hotdog_network *network, unsigned int subscription,
	enum hotdog_nas_registration registration, uint16_t mcc, uint16_t mnc,
	enum hotdog_nas_rat rat, bool ps_attached, bool cs_attached,
	struct hotdog_network_teardown *teardown);
int hotdog_network_set_default_data(struct hotdog_network *network,
				    unsigned int subscription, bool force);
int hotdog_network_bearer_start(struct hotdog_network *network, unsigned int subscription,
				unsigned int profile, unsigned int mux_id,
				enum hotdog_ip_family family, enum hotdog_data_auth auth,
				const char *apn, unsigned int *bearer_id);
int hotdog_network_bearer_connected(struct hotdog_network *network, unsigned int bearer_id,
				    const struct hotdog_bearer_runtime *runtime);
int hotdog_network_bearer_leg_started(struct hotdog_network *network,
				      unsigned int bearer_id,
				      enum hotdog_ip_family family,
				      uint32_t packet_handle);
int hotdog_network_bearer_disconnect(struct hotdog_network *network,
				     unsigned int bearer_id,
				     struct hotdog_bearer_stop_plan *plan);
int hotdog_network_bearer_fail(struct hotdog_network *network,
			       unsigned int bearer_id, unsigned int error,
			       struct hotdog_bearer_stop_plan *plan);
int hotdog_network_bearer_leg_stopped(struct hotdog_network *network,
				      unsigned int bearer_id,
				      enum hotdog_ip_family family,
				      uint32_t packet_handle);
int hotdog_network_bearer_stop(struct hotdog_network *network, unsigned int bearer_id);
void hotdog_network_ssr(struct hotdog_network *network);
const struct hotdog_bearer *hotdog_network_find_bearer(const struct hotdog_network *network,
						       unsigned int bearer_id);
const char *hotdog_nas_registration_name(enum hotdog_nas_registration registration);
const char *hotdog_nas_rat_name(enum hotdog_nas_rat rat);
const char *hotdog_ip_family_name(enum hotdog_ip_family family);
const char *hotdog_bearer_state_name(enum hotdog_bearer_state state);

#endif
