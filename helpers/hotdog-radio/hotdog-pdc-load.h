/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef HOTDOG_PDC_LOAD_H
#define HOTDOG_PDC_LOAD_H

#include "hotdog-pdc.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define HOTDOG_PDC_LOAD_CHUNK_SIZE 0x400

struct hotdog_pdc_load {
	struct hotdog_pdc_id id;
	uint32_t total_size;
	uint32_t offset;
	uint32_t sent_offset;
	uint32_t sent_size;
	uint32_t expected_token;
	bool awaiting;
	bool complete;
	bool cleanup_required;
};

int hotdog_pdc_load_init(struct hotdog_pdc_load *load,
			 const struct hotdog_pdc_id *id, uint32_t total_size);
int hotdog_pdc_load_next(struct hotdog_pdc_load *load, uint32_t token,
			 uint32_t *offset, uint32_t *size);
int hotdog_pdc_load_ack(struct hotdog_pdc_load *load, uint32_t token,
			uint16_t remote_result, bool frame_reset,
			uint32_t remaining_size);
void hotdog_pdc_load_abort(struct hotdog_pdc_load *load);

#endif
