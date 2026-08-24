/* SPDX-License-Identifier: GPL-2.0-only */
#include "hotdog-qmi-uim.h"

#include <errno.h>
#include <string.h>

static enum hotdog_uim_card_state map_card_state(QmiUimCardState state)
{
	switch (state) {
	case QMI_UIM_CARD_STATE_PRESENT: return HOTDOG_UIM_CARD_PRESENT;
	case QMI_UIM_CARD_STATE_ERROR: return HOTDOG_UIM_CARD_ERROR;
	case QMI_UIM_CARD_STATE_ABSENT: return HOTDOG_UIM_CARD_ABSENT;
	}
	return HOTDOG_UIM_CARD_ERROR;
}

static enum hotdog_uim_app_type map_app_type(QmiUimCardApplicationType type)
{
	switch (type) {
	case QMI_UIM_CARD_APPLICATION_TYPE_SIM: return HOTDOG_UIM_APP_SIM;
	case QMI_UIM_CARD_APPLICATION_TYPE_USIM: return HOTDOG_UIM_APP_USIM;
	case QMI_UIM_CARD_APPLICATION_TYPE_CSIM: return HOTDOG_UIM_APP_CSIM;
	case QMI_UIM_CARD_APPLICATION_TYPE_ISIM: return HOTDOG_UIM_APP_ISIM;
	case QMI_UIM_CARD_APPLICATION_TYPE_RUIM:
	case QMI_UIM_CARD_APPLICATION_TYPE_UNKNOWN:
		return HOTDOG_UIM_APP_UNKNOWN;
	}
	return HOTDOG_UIM_APP_UNKNOWN;
}

static enum hotdog_uim_app_state map_app_state(QmiUimCardApplicationState state)
{
	switch (state) {
	case QMI_UIM_CARD_APPLICATION_STATE_PIN1_OR_UPIN_PIN_REQUIRED:
		return HOTDOG_UIM_APP_PIN_REQUIRED;
	case QMI_UIM_CARD_APPLICATION_STATE_PUK1_OR_UPIN_PUK_REQUIRED:
		return HOTDOG_UIM_APP_PUK_REQUIRED;
	case QMI_UIM_CARD_APPLICATION_STATE_READY:
		return HOTDOG_UIM_APP_READY;
	case QMI_UIM_CARD_APPLICATION_STATE_PIN1_BLOCKED:
	case QMI_UIM_CARD_APPLICATION_STATE_ILLEGAL:
		return HOTDOG_UIM_APP_BLOCKED;
	case QMI_UIM_CARD_APPLICATION_STATE_UNKNOWN:
	case QMI_UIM_CARD_APPLICATION_STATE_DETECTED:
	case QMI_UIM_CARD_APPLICATION_STATE_CHECK_PERSONALIZATION_STATE:
		return HOTDOG_UIM_APP_DETECTED;
	}
	return HOTDOG_UIM_APP_DETECTED;
}

int hotdog_qmi_uim_decode(QmiMessageUimGetCardStatusOutput *output,
			  struct hotdog_uim_inventory *inventory)
{
	GArray *cards = NULL;
	GError *error = NULL;
	size_t i;

	if (!output || !inventory)
		return -EINVAL;
	if (!qmi_message_uim_get_card_status_output_get_result(output, &error)) {
		g_clear_error(&error);
		return -EIO;
	}
	if (!qmi_message_uim_get_card_status_output_get_card_status(
		    output, NULL, NULL, NULL, NULL, &cards, &error)) {
		g_clear_error(&error);
		return -ENODATA;
	}
	hotdog_uim_inventory_init(inventory, cards->len);
	for (i = 0; i < cards->len && i < inventory->slot_count; i++) {
		QmiMessageUimGetCardStatusOutputCardStatusCardsElement *card;
		size_t j;

		card = &g_array_index(cards,
				      QmiMessageUimGetCardStatusOutputCardStatusCardsElement, i);
		inventory->slots[i].state = map_card_state(card->card_state);
		inventory->slots[i].card_error = card->error_code;
		for (j = 0; j < card->applications->len; j++) {
			QmiMessageUimGetCardStatusOutputCardStatusCardsElementApplicationsElementV2 *source;
			struct hotdog_uim_app app = { 0 };

			source = &g_array_index(card->applications,
				QmiMessageUimGetCardStatusOutputCardStatusCardsElementApplicationsElementV2, j);
			app.type = map_app_type(source->type);
			app.state = map_app_state(source->state);
			app.retries.pin1 = source->pin1_retries;
			app.retries.puk1 = source->puk1_retries;
			app.retries.pin2 = source->pin2_retries;
			app.retries.puk2 = source->puk2_retries;
			if (source->application_identifier_value) {
				app.aid_length = source->application_identifier_value->len;
				if (app.aid_length > HOTDOG_UIM_MAX_AID)
					return -EOVERFLOW;
				memcpy(app.aid, source->application_identifier_value->data, app.aid_length);
			}
			if (hotdog_uim_add_app(inventory, (unsigned int)i + 1, &app))
				return -ENOSPC;
		}
	}
	return hotdog_uim_select_sessions(inventory);
}
