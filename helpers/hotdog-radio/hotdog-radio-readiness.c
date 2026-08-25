/* SPDX-License-Identifier: GPL-2.0-only */
#define _POSIX_C_SOURCE 200809L
#include "hotdog-radio-readiness.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

static bool valid_hex(const char *value, size_t length)
{
	size_t index;

	if (strlen(value) != length)
		return false;
	for (index = 0; index < length; index++)
		if (!((value[index] >= '0' && value[index] <= '9') ||
		      (value[index] >= 'a' && value[index] <= 'f') ||
		      (value[index] >= 'A' && value[index] <= 'F')))
			return false;
	return true;
}

static bool valid_boot_id(const char *value)
{
	static const size_t hyphens[] = { 8, 13, 18, 23 };
	size_t index, hyphen = 0;

	if (strlen(value) != HOTDOG_READINESS_BOOT_ID_SIZE - 1)
		return false;
	for (index = 0; index < HOTDOG_READINESS_BOOT_ID_SIZE - 1; index++) {
		if (hyphen < 4 && index == hyphens[hyphen]) {
			if (value[index] != '-') return false;
			hyphen++;
		} else if (!((value[index] >= '0' && value[index] <= '9') ||
			     (value[index] >= 'a' && value[index] <= 'f') ||
			     (value[index] >= 'A' && value[index] <= 'F'))) return false;
	}
	return true;
}

int hotdog_radio_readiness_validate(const struct hotdog_radio_readiness *readiness)
{
	size_t index, populated = 0, locked = 0;

	if (!readiness || !valid_boot_id(readiness->boot_id) ||
	    !valid_hex(readiness->modem_sha256, 64) ||
	    !valid_hex(readiness->mcfg_sha256, 64) || !readiness->dms_online ||
	    readiness->phase > HOTDOG_READINESS_READY)
		return -EINVAL;
	for (index = 0; index < HOTDOG_PDC_MAX_SUBSCRIPTIONS; index++) {
		const struct hotdog_readiness_subscription *subscription =
			&readiness->subscriptions[index];

		if (!subscription->populated) {
			if (subscription->selected.length || subscription->active.length ||
			    subscription->pending.length || subscription->physical_slot)
				return -EPROTO;
			continue;
		}
		populated++;
		if (!subscription->physical_slot ||
		    subscription->physical_slot > HOTDOG_UIM_MAX_SLOTS ||
		    subscription->selected.length != HOTDOG_PDC_ID_SIZE ||
		    !hotdog_pdc_id_equal(&subscription->selected, &subscription->active) ||
		    subscription->pending.length)
			return -EPROTO;
		if (subscription->app_state != HOTDOG_UIM_APP_READY)
			locked++;
	}
	if (!populated)
		return -ENODEV;
	if ((readiness->phase == HOTDOG_READINESS_LOCKED) != (locked != 0))
		return -EPROTO;
	if (readiness->phase != HOTDOG_READINESS_LOCKED && locked)
		return -EPROTO;
	return 0;
}

static void print_id(FILE *stream, const struct hotdog_pdc_id *id)
{
	size_t index;

	if (!id->length) {
		fputc('-', stream);
		return;
	}
	for (index = 0; index < id->length; index++)
		fprintf(stream, "%02x", id->value[index]);
}

const char *hotdog_readiness_phase_name(enum hotdog_readiness_phase phase)
{
	switch (phase) {
	case HOTDOG_READINESS_LOCKED: return "locked";
	case HOTDOG_READINESS_REGISTERING: return "registering";
	case HOTDOG_READINESS_READY: return "ready";
	}
	return "invalid";
}

int hotdog_radio_readiness_write(const char *path,
				  const struct hotdog_radio_readiness *readiness)
{
	char temporary[512];
	char directory_path[512];
	char *separator;
	FILE *stream;
	struct stat directory_status;
	int descriptor, directory, result, written;
	size_t index;

	result = hotdog_radio_readiness_validate(readiness);
	if (result || !path)
		return result ? result : -EINVAL;
	if (strlen(path) >= sizeof(directory_path))
		return -ENAMETOOLONG;
	memcpy(directory_path, path, strlen(path) + 1);
	separator = strrchr(directory_path, '/');
	if (!separator)
		memcpy(directory_path, ".", 2);
	else if (separator == directory_path)
		directory_path[1] = '\0';
	else
		*separator = '\0';
	directory = open(directory_path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
	if (directory < 0)
		return -errno;
	if (fstat(directory, &directory_status)) {
		result = -errno;
		close(directory);
		return result;
	}
	if (!S_ISDIR(directory_status.st_mode) ||
	    (directory_status.st_mode & (S_IWGRP | S_IWOTH))) {
		result = -EPERM;
		close(directory);
		return result;
	}
	written = snprintf(temporary, sizeof(temporary), "%s.new.%ld", path, (long)getpid());
	if (written < 0 || (size_t)written >= sizeof(temporary))
		result = -ENAMETOOLONG;
	else
		result = 0;
	if (result) {
		close(directory);
		return result;
	}
	descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
			  0644);
	if (descriptor < 0) {
		result = -errno;
		close(directory);
		return result;
	}
	stream = fdopen(descriptor, "w");
	if (!stream) {
		result = -errno;
		close(descriptor);
		unlink(temporary);
		close(directory);
		return result;
	}
	fprintf(stream, "schema=2\nboot-id=%s\nphase=%s\ndms=online\n",
		readiness->boot_id, hotdog_readiness_phase_name(readiness->phase));
	fprintf(stream, "modem-sha256=%s\nmcfg-archive-sha256=%s\n",
		readiness->modem_sha256, readiness->mcfg_sha256);
	for (index = 0; index < HOTDOG_PDC_MAX_SUBSCRIPTIONS; index++) {
		const struct hotdog_readiness_subscription *subscription =
			&readiness->subscriptions[index];

		fprintf(stream, "sub%zu-populated=%u\nsub%zu-slot=%u\nsub%zu-app-state=%s\n",
			index, subscription->populated, index, subscription->physical_slot,
			index, subscription->populated ?
			hotdog_uim_app_state_name(subscription->app_state) : "none");
		fprintf(stream, "sub%zu-pin1-retries=%u\nsub%zu-puk1-retries=%u\n",
			index, subscription->retries.pin1, index, subscription->retries.puk1);
		fprintf(stream, "sub%zu-selected=", index); print_id(stream, &subscription->selected);
		fprintf(stream, "\nsub%zu-active=", index); print_id(stream, &subscription->active);
		fprintf(stream, "\nsub%zu-pending=", index); print_id(stream, &subscription->pending);
		fputc('\n', stream);
	}
	result = 0;
	if (fflush(stream) || fsync(descriptor))
		result = -EIO;
	if (fclose(stream) && !result)
		result = -EIO;
	if (result) {
		unlink(temporary);
		close(directory);
		return result;
	}
	if (rename(temporary, path)) {
		result = -errno;
		unlink(temporary);
		close(directory);
		return result;
	}
	if (fsync(directory)) {
		result = -errno;
		close(directory);
		return result;
	}
	close(directory);
	return 0;
}
