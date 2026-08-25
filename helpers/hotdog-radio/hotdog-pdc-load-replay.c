/* SPDX-License-Identifier: GPL-2.0-only */
#include "hotdog-pdc-load.h"

#include <stdio.h>
#include <string.h>

static int hex_id(const char *text, struct hotdog_pdc_id *id)
{
	size_t index;

	if (strlen(text) != HOTDOG_PDC_ID_SIZE * 2)
		return -1;
	for (index = 0; index < HOTDOG_PDC_ID_SIZE; index++) {
		unsigned int byte;

		if (sscanf(&text[index * 2], "%2x", &byte) != 1)
			return -1;
		id->value[index] = (unsigned char)byte;
	}
	id->length = HOTDOG_PDC_ID_SIZE;
	return 0;
}

static void print_state(const struct hotdog_pdc_load *load)
{
	printf("state=offset:%u total:%u awaiting:%u complete:%u cleanup:%u\n",
	       load->offset, load->total_size, load->awaiting, load->complete,
	       load->cleanup_required);
}

int main(void)
{
	struct hotdog_pdc_load load = { 0 };
	char command[16];

	while (scanf("%15s", command) == 1) {
		if (!strcmp(command, "INIT")) {
			struct hotdog_pdc_id id = { 0 };
			char text[HOTDOG_PDC_ID_SIZE * 2 + 1];
			unsigned int total;
			int result;

			if (scanf("%u %40s", &total, text) != 2 || hex_id(text, &id))
				return 2;
			result = hotdog_pdc_load_init(&load, &id, total);
			printf("init=%d\n", result);
		} else if (!strcmp(command, "NEXT")) {
			unsigned int token, offset = 0, size = 0;
			int result;

			if (scanf("%u", &token) != 1)
				return 2;
			result = hotdog_pdc_load_next(&load, token, &offset, &size);
			printf("next=%d token:%u offset:%u size:%u\n", result, token, offset, size);
		} else if (!strcmp(command, "ACK")) {
			unsigned int token, remote, reset, remaining;
			int result;

			if (scanf("%u %u %u %u", &token, &remote, &reset, &remaining) != 4)
				return 2;
			result = hotdog_pdc_load_ack(&load, token, (uint16_t)remote,
						     reset != 0, remaining);
			printf("ack=%d token:%u\n", result, token);
		} else if (!strcmp(command, "ABORT")) {
			hotdog_pdc_load_abort(&load);
			printf("abort=0\n");
		} else if (!strcmp(command, "STATE")) {
			print_state(&load);
		} else {
			return 2;
		}
	}
	return 0;
}
