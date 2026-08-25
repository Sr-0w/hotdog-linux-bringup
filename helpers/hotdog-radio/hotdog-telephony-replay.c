/* SPDX-License-Identifier: GPL-2.0-only */
#include "hotdog-telephony.h"

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

static enum hotdog_transport transport(const char *name)
{
	if (!strcmp(name, "cs")) return HOTDOG_TRANSPORT_CS;
	if (!strcmp(name, "ims")) return HOTDOG_TRANSPORT_IMS;
	return HOTDOG_TRANSPORT_AUTO;
}

static enum hotdog_ims_registration ims_registration(const char *name)
{
	if (!strcmp(name, "registering")) return HOTDOG_IMS_REGISTERING;
	if (!strcmp(name, "registered")) return HOTDOG_IMS_REGISTERED;
	if (!strcmp(name, "blocked")) return HOTDOG_IMS_BLOCKED;
	return HOTDOG_IMS_NONE;
}

static enum hotdog_ims_rat ims_rat(const char *name)
{
	if (!strcmp(name, "lte")) return HOTDOG_IMS_RAT_LTE;
	if (!strcmp(name, "wlan")) return HOTDOG_IMS_RAT_WLAN;
	if (!strcmp(name, "nr5g")) return HOTDOG_IMS_RAT_NR5G;
	return HOTDOG_IMS_RAT_UNKNOWN;
}

static enum hotdog_sms_state sms_state(const char *name)
{
	if (!strcmp(name, "submitted")) return HOTDOG_SMS_SUBMITTED;
	if (!strcmp(name, "sent")) return HOTDOG_SMS_SENT;
	if (!strcmp(name, "delivered")) return HOTDOG_SMS_DELIVERED;
	if (!strcmp(name, "received")) return HOTDOG_SMS_RECEIVED;
	if (!strcmp(name, "failed")) return HOTDOG_SMS_FAILED;
	return HOTDOG_SMS_QUEUED;
}

static enum hotdog_sms_storage sms_storage(const char *name)
{
	if (!strcmp(name, "sim")) return HOTDOG_SMS_STORAGE_SIM;
	if (!strcmp(name, "modem")) return HOTDOG_SMS_STORAGE_MODEM;
	return HOTDOG_SMS_STORAGE_NONE;
}

static enum hotdog_call_state call_state(const char *name)
{
	if (!strcmp(name, "alerting")) return HOTDOG_CALL_ALERTING;
	if (!strcmp(name, "incoming")) return HOTDOG_CALL_INCOMING;
	if (!strcmp(name, "active")) return HOTDOG_CALL_ACTIVE;
	if (!strcmp(name, "held")) return HOTDOG_CALL_HELD;
	if (!strcmp(name, "disconnecting")) return HOTDOG_CALL_DISCONNECTING;
	if (!strcmp(name, "ended")) return HOTDOG_CALL_ENDED;
	return HOTDOG_CALL_DIALING;
}

static void status(const struct hotdog_telephony *telephony)
{
	size_t i;

	printf("status generation=%u\n", telephony->generation);
	for (i = 0; i < HOTDOG_TELEPHONY_MAX_SUBSCRIPTIONS; i++) {
		const struct hotdog_telephony_subscription *sub = &telephony->subscriptions[i];

		if (!sub->populated)
			continue;
		printf("sub%zu=cs%u,emergency%u,ims-%s,rat%u,caps0x%x,sip%u,cw%u,clip%u,clir%u\n",
		       i, sub->cs_registered, sub->emergency_available,
		       hotdog_ims_registration_name(sub->ims.registration), sub->ims.rat,
		       sub->ims.capabilities, sub->ims.sip_code,
		       sub->supplementary.call_waiting, sub->supplementary.clip,
		       sub->supplementary.clir_mode);
	}
	for (i = 0; i < HOTDOG_TELEPHONY_MAX_SMS; i++) {
		const struct hotdog_sms *message = &telephony->messages[i];

		if (!message->id)
			continue;
		printf("sms%u=%s,%s,sub%u,gen%u,bytes%u,ref%u,error%u,concat%u/%u/%u\n",
		       message->id, hotdog_sms_state_name(message->state),
		       hotdog_transport_name(message->transport), message->subscription,
		       message->generation, message->pdu_bytes, message->message_reference,
		       message->error, message->concat_reference, message->concat_part,
		       message->concat_total);
	}
	for (i = 0; i < HOTDOG_TELEPHONY_MAX_CALLS; i++) {
		const struct hotdog_call *call = &telephony->calls[i];

		if (!call->id)
			continue;
		printf("call%u=%s,%s,sub%u,gen%u,remote%u,emergency%u,video%u,audio%u,number=%s\n",
		       call->id, hotdog_call_state_name(call->state),
		       hotdog_transport_name(call->transport), call->subscription,
		       call->generation, call->remote_id, call->emergency, call->video,
		       call->audio_ready,
		       call->number);
	}
}

int main(void)
{
	struct hotdog_telephony telephony;
	char line[1024];
	unsigned int line_number = 0;

	hotdog_telephony_init(&telephony);
	while (fgets(line, sizeof(line), stdin)) {
		char *field[12] = { 0 };
		char *token;
		size_t count = 0;
		unsigned long a, b, c, d, e, f;
		int result;

		line_number++;
		if (line[0] == '#' || line[0] == '\n')
			continue;
		for (token = strtok(line, " \t\r\n"); token && count < 12;
		     token = strtok(NULL, " \t\r\n"))
			field[count++] = token;
		if (!count)
			continue;
		if (!strcmp(field[0], "SUB") && count == 5 && !number(field[1], 2, &a) &&
		    !number(field[2], 1, &b) && !number(field[3], 1, &c) &&
		    !number(field[4], 1, &d)) {
			printf("sub-result=%d\n", hotdog_telephony_set_subscription(&telephony,
									  a, b, c, d));
			continue;
		}
		if (!strcmp(field[0], "IMS") && count == 6 && !number(field[1], 2, &a) &&
		    !number(field[4], UINT32_MAX, &b) && !number(field[5], 999, &c)) {
			printf("ims-result=%d\n", hotdog_telephony_set_ims(&telephony, a,
								ims_registration(field[2]),
								ims_rat(field[3]), b, c));
			continue;
		}
		if (!strcmp(field[0], "SUPP") && count == 5 && !number(field[1], 2, &a) &&
		    !number(field[2], 1, &b) && !number(field[3], 1, &c) &&
		    !number(field[4], 2, &d)) {
			printf("supp-result=%d\n", hotdog_telephony_set_supplementary(&telephony,
									       a, b, c, d));
			continue;
		}
		if (!strcmp(field[0], "SMS") && count == 8 && !number(field[1], 2, &a) &&
		    !number(field[3], UINT16_MAX, &b) && !number(field[4], 1, &c) &&
		    !number(field[5], UINT32_MAX, &d) && !number(field[6], UINT16_MAX, &e) &&
		    !number(field[7], UINT16_MAX, &f)) {
			unsigned int id = 0;

			result = hotdog_sms_submit(&telephony, a, transport(field[2]), b, c,
						   d, e, f, &id);
			printf("sms-result=%d id=%u\n", result, id);
			continue;
		}
		if (!strcmp(field[0], "SMS_STATE") && count == 5 &&
		    !number(field[1], UINT32_MAX, &a) && !number(field[3], UINT32_MAX, &b) &&
		    !number(field[4], UINT32_MAX, &c)) {
			printf("sms-state-result=%d\n", hotdog_sms_update(&telephony, a,
								      sms_state(field[2]), b, c));
			continue;
		}
		if (!strcmp(field[0], "SMS_IN") && count == 6 && !number(field[1], 2, &a) &&
		    !number(field[3], UINT16_MAX, &b) && !number(field[5], UINT32_MAX, &c)) {
			unsigned int id = 0;

			result = hotdog_sms_receive(&telephony, a, transport(field[2]), b,
						    sms_storage(field[4]), c, &id);
			printf("sms-in-result=%d id=%u\n", result, id);
			continue;
		}
		if (!strcmp(field[0], "SMS_REPORT") && count == 5 &&
		    !number(field[1], 2, &a) && !number(field[3], UINT8_MAX, &b) &&
		    !number(field[4], 0x7f, &c)) {
			unsigned int id = 0;

			result = hotdog_sms_delivery_report(
				&telephony, a, transport(field[2]), b, c, &id);
			printf("sms-report-result=%d id=%u\n", result, id);
			continue;
		}
		if (!strcmp(field[0], "DIAL") && count == 6 && !number(field[1], 2, &a) &&
		    !number(field[3], 1, &b) && !number(field[4], 1, &c)) {
			unsigned int id = 0;

			result = hotdog_call_dial(&telephony, a, transport(field[2]), field[5],
						   b, c, &id);
			printf("dial-result=%d id=%u\n", result, id);
			continue;
		}
		if (!strcmp(field[0], "INCOMING") && count == 5 &&
		    !number(field[1], 2, &a) && !number(field[3], 1, &b)) {
			unsigned int id = 0;

			result = hotdog_call_incoming(&telephony, a, transport(field[2]),
						       field[4], b, &id);
			printf("incoming-result=%d id=%u\n", result, id);
			continue;
		}
		if (!strcmp(field[0], "CALL_STATE") && count == 3 &&
		    !number(field[1], UINT32_MAX, &a)) {
			printf("call-state-result=%d\n", hotdog_call_transition(&telephony, a,
									 call_state(field[2])));
			continue;
		}
		if (!strcmp(field[0], "BIND") && count == 3 &&
		    !number(field[1], UINT32_MAX, &a) &&
		    !number(field[2], UINT32_MAX, &b)) {
			printf("bind-result=%d\n",
			       hotdog_call_bind_remote(&telephony, a, b));
			continue;
		}
		if (!strcmp(field[0], "AUDIO") && count == 3 &&
		    !number(field[1], UINT32_MAX, &a) && !number(field[2], 1, &b)) {
			printf("audio-result=%d\n", hotdog_call_set_audio(&telephony, a, b));
			continue;
		}
		if (!strcmp(field[0], "DTMF") && count == 3 &&
		    !number(field[1], UINT32_MAX, &a) && strlen(field[2]) == 1) {
			printf("dtmf-result=%d\n", hotdog_call_dtmf(&telephony, a, field[2][0]));
			continue;
		}
		if (!strcmp(field[0], "SSR") && count == 1) {
			hotdog_telephony_ssr(&telephony);
			printf("ssr-generation=%u\n", telephony.generation);
			continue;
		}
		if (!strcmp(field[0], "STATUS") && count == 1) {
			status(&telephony);
			continue;
		}
		fprintf(stderr, "invalid telephony replay input at line %u\n", line_number);
		return 2;
	}
	return 0;
}
