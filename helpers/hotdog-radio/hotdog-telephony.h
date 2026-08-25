/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef HOTDOG_TELEPHONY_H
#define HOTDOG_TELEPHONY_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define HOTDOG_TELEPHONY_MAX_SUBSCRIPTIONS 3
#define HOTDOG_TELEPHONY_MAX_SMS 16
#define HOTDOG_TELEPHONY_MAX_CALLS 8
#define HOTDOG_TELEPHONY_MAX_CALL_CHANGES (HOTDOG_TELEPHONY_MAX_CALLS * 2)
#define HOTDOG_TELEPHONY_NUMBER_SIZE 48

enum hotdog_ims_registration {
	HOTDOG_IMS_NONE,
	HOTDOG_IMS_REGISTERING,
	HOTDOG_IMS_REGISTERED,
	HOTDOG_IMS_BLOCKED,
};

enum hotdog_ims_rat {
	HOTDOG_IMS_RAT_UNKNOWN,
	HOTDOG_IMS_RAT_LTE,
	HOTDOG_IMS_RAT_WLAN,
	HOTDOG_IMS_RAT_NR5G,
};

enum hotdog_ims_capability {
	HOTDOG_IMS_CAP_VOICE = 1U << 0,
	HOTDOG_IMS_CAP_VIDEO = 1U << 1,
	HOTDOG_IMS_CAP_SMS = 1U << 2,
	HOTDOG_IMS_CAP_UT = 1U << 3,
	HOTDOG_IMS_CAP_RCS = 1U << 4,
};

enum hotdog_transport {
	HOTDOG_TRANSPORT_AUTO,
	HOTDOG_TRANSPORT_CS,
	HOTDOG_TRANSPORT_IMS,
};

enum hotdog_sms_direction {
	HOTDOG_SMS_MO,
	HOTDOG_SMS_MT,
};

enum hotdog_sms_state {
	HOTDOG_SMS_QUEUED,
	HOTDOG_SMS_SUBMITTED,
	HOTDOG_SMS_SENT,
	HOTDOG_SMS_DELIVERED,
	HOTDOG_SMS_RECEIVED,
	HOTDOG_SMS_FAILED,
};

enum hotdog_sms_storage {
	HOTDOG_SMS_STORAGE_NONE,
	HOTDOG_SMS_STORAGE_SIM,
	HOTDOG_SMS_STORAGE_MODEM,
};

enum hotdog_call_direction {
	HOTDOG_CALL_MO,
	HOTDOG_CALL_MT,
};

enum hotdog_call_state {
	HOTDOG_CALL_DIALING,
	HOTDOG_CALL_ALERTING,
	HOTDOG_CALL_INCOMING,
	HOTDOG_CALL_ACTIVE,
	HOTDOG_CALL_HELD,
	HOTDOG_CALL_DISCONNECTING,
	HOTDOG_CALL_ENDED,
};

enum hotdog_call_change_type {
	HOTDOG_CALL_ADDED,
	HOTDOG_CALL_UPDATED,
	HOTDOG_CALL_ENDED_CHANGE,
};

struct hotdog_ims_state {
	enum hotdog_ims_registration registration;
	enum hotdog_ims_rat rat;
	uint32_t capabilities;
	uint32_t limited_capabilities;
	unsigned int sip_code;
	enum hotdog_ims_rat voice_rat;
	enum hotdog_ims_rat video_rat;
	enum hotdog_ims_rat sms_rat;
};

struct hotdog_supplementary {
	bool call_waiting;
	bool clip;
	unsigned int clir_mode;
};

struct hotdog_telephony_subscription {
	bool populated;
	bool cs_registered;
	bool emergency_available;
	struct hotdog_ims_state ims;
	struct hotdog_supplementary supplementary;
};

struct hotdog_sms {
	unsigned int id;
	unsigned int subscription;
	unsigned int generation;
	unsigned int pdu_bytes;
	unsigned int message_reference;
	unsigned int error;
	unsigned int concat_reference;
	unsigned int concat_part;
	unsigned int concat_total;
	bool delivery_report;
	enum hotdog_transport transport;
	enum hotdog_sms_direction direction;
	enum hotdog_sms_state state;
	enum hotdog_sms_storage storage;
};

struct hotdog_call {
	unsigned int id;
	unsigned int remote_id;
	unsigned int subscription;
	unsigned int generation;
	enum hotdog_transport transport;
	enum hotdog_call_direction direction;
	enum hotdog_call_state state;
	bool emergency;
	bool audio_ready;
	bool video;
	char number[HOTDOG_TELEPHONY_NUMBER_SIZE];
};

struct hotdog_call_observation {
	unsigned int remote_id;
	unsigned int subscription;
	enum hotdog_transport transport;
	enum hotdog_call_direction direction;
	enum hotdog_call_state state;
	bool emergency;
	bool video;
	bool number_present;
	char number[HOTDOG_TELEPHONY_NUMBER_SIZE];
};

struct hotdog_call_change {
	enum hotdog_call_change_type type;
	unsigned int call_id;
};

struct hotdog_call_changes {
	size_t count;
	struct hotdog_call_change changes[HOTDOG_TELEPHONY_MAX_CALL_CHANGES];
};

struct hotdog_telephony {
	struct hotdog_telephony_subscription subscriptions[HOTDOG_TELEPHONY_MAX_SUBSCRIPTIONS];
	struct hotdog_sms messages[HOTDOG_TELEPHONY_MAX_SMS];
	struct hotdog_call calls[HOTDOG_TELEPHONY_MAX_CALLS];
	unsigned int next_sms_id;
	unsigned int next_call_id;
	unsigned int generation;
};

void hotdog_telephony_init(struct hotdog_telephony *telephony);
int hotdog_telephony_set_subscription(struct hotdog_telephony *telephony,
				      unsigned int subscription, bool populated,
				      bool cs_registered, bool emergency_available);
int hotdog_telephony_set_ims(struct hotdog_telephony *telephony,
			     unsigned int subscription, enum hotdog_ims_registration registration,
			     enum hotdog_ims_rat rat, uint32_t capabilities,
			     unsigned int sip_code);
int hotdog_telephony_set_supplementary(struct hotdog_telephony *telephony,
				       unsigned int subscription, bool call_waiting,
				       bool clip, unsigned int clir_mode);
int hotdog_sms_submit(struct hotdog_telephony *telephony, unsigned int subscription,
		      enum hotdog_transport requested, unsigned int pdu_bytes,
		      bool delivery_report, unsigned int concat_reference,
		      unsigned int concat_part, unsigned int concat_total,
		      unsigned int *message_id);
int hotdog_sms_receive(struct hotdog_telephony *telephony, unsigned int subscription,
		       enum hotdog_transport transport, unsigned int pdu_bytes,
		       enum hotdog_sms_storage storage, unsigned int message_reference,
		       unsigned int *message_id);
int hotdog_sms_update(struct hotdog_telephony *telephony, unsigned int message_id,
		      enum hotdog_sms_state state, unsigned int message_reference,
		      unsigned int error);
int hotdog_sms_delivery_report(struct hotdog_telephony *telephony,
			       unsigned int subscription,
			       enum hotdog_transport transport,
			       unsigned int message_reference,
			       unsigned int delivery_status,
			       unsigned int *message_id);
int hotdog_call_dial(struct hotdog_telephony *telephony, unsigned int subscription,
		     enum hotdog_transport requested, const char *number,
		     bool emergency, bool video, unsigned int *call_id);
int hotdog_call_incoming(struct hotdog_telephony *telephony, unsigned int subscription,
			 enum hotdog_transport transport, const char *number,
			 bool emergency, unsigned int *call_id);
int hotdog_call_transition(struct hotdog_telephony *telephony, unsigned int call_id,
			   enum hotdog_call_state state);
int hotdog_call_bind_remote(struct hotdog_telephony *telephony,
			    unsigned int call_id, unsigned int remote_id);
int hotdog_call_reconcile(struct hotdog_telephony *telephony,
			  unsigned int subscription,
			  const struct hotdog_call_observation *observations,
			  size_t observation_count,
			  struct hotdog_call_changes *changes);
int hotdog_call_set_audio(struct hotdog_telephony *telephony, unsigned int call_id,
			  bool ready);
int hotdog_call_dtmf(const struct hotdog_telephony *telephony, unsigned int call_id,
		     char digit);
void hotdog_telephony_ssr(struct hotdog_telephony *telephony);
const char *hotdog_transport_name(enum hotdog_transport transport);
const char *hotdog_sms_state_name(enum hotdog_sms_state state);
const char *hotdog_call_state_name(enum hotdog_call_state state);
const char *hotdog_ims_registration_name(enum hotdog_ims_registration registration);

#endif
