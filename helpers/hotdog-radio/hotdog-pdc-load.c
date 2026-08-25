/* SPDX-License-Identifier: GPL-2.0-only */
#include "hotdog-pdc-load.h"

#include <errno.h>
#include <string.h>

int hotdog_pdc_load_init(struct hotdog_pdc_load *load,
			 const struct hotdog_pdc_id *id, uint32_t total_size)
{
	if (!load || !id || id->length != HOTDOG_PDC_ID_SIZE || !total_size)
		return -EINVAL;
	memset(load, 0, sizeof(*load));
	load->id = *id;
	load->total_size = total_size;
	return 0;
}

int hotdog_pdc_load_next(struct hotdog_pdc_load *load, uint32_t token,
			 uint32_t *offset, uint32_t *size)
{
	uint32_t remaining;

	if (!load || !offset || !size || !token)
		return -EINVAL;
	if (load->complete)
		return -EALREADY;
	if (load->awaiting)
		return -EBUSY;
	if (load->cleanup_required)
		return -ECANCELED;
	if (load->offset >= load->total_size)
		return -EPROTO;
	remaining = load->total_size - load->offset;
	load->sent_offset = load->offset;
	load->sent_size = remaining > HOTDOG_PDC_LOAD_CHUNK_SIZE ?
		HOTDOG_PDC_LOAD_CHUNK_SIZE : remaining;
	load->expected_token = token;
	load->awaiting = true;
	*offset = load->sent_offset;
	*size = load->sent_size;
	return 0;
}

int hotdog_pdc_load_ack(struct hotdog_pdc_load *load, uint32_t token,
			uint16_t remote_result, bool frame_reset,
			uint32_t remaining_size)
{
	uint32_t expected_remaining;

	if (!load || !load->awaiting)
		return -EINVAL;
	if (token != load->expected_token)
		return -ESTALE;
	load->awaiting = false;
	if (remote_result) {
		load->cleanup_required = true;
		return -EREMOTEIO;
	}
	if (frame_reset) {
		load->cleanup_required = true;
		return -EPIPE;
	}
	expected_remaining = load->total_size - load->sent_offset - load->sent_size;
	if (remaining_size != expected_remaining) {
		load->cleanup_required = true;
		return -EPROTO;
	}
	load->offset = load->sent_offset + load->sent_size;
	load->sent_size = 0;
	if (!remaining_size)
		load->complete = true;
	return 0;
}

void hotdog_pdc_load_abort(struct hotdog_pdc_load *load)
{
	if (!load || load->complete)
		return;
	if (load->awaiting || load->offset || load->sent_size)
		load->cleanup_required = true;
	load->awaiting = false;
}
