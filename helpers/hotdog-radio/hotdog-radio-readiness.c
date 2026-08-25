/* SPDX-License-Identifier: GPL-2.0-only */
#define _POSIX_C_SOURCE 200809L
#include "hotdog-radio-readiness.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#define READINESS_BASE_KEYS 6
#define READINESS_SUB_KEYS 8

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

static int parse_uint(const char *value, unsigned int maximum, unsigned int *output)
{
	char *end;
	unsigned long parsed;

	errno = 0;
	parsed = strtoul(value, &end, 10);
	if (errno || !*value || *end || parsed > maximum)
		return -EINVAL;
	*output = (unsigned int)parsed;
	return 0;
}

static int parse_id(const char *value, struct hotdog_pdc_id *id)
{
	size_t index;

	memset(id, 0, sizeof(*id));
	if (!strcmp(value, "-"))
		return 0;
	if (strlen(value) != HOTDOG_PDC_ID_SIZE * 2)
		return -EINVAL;
	for (index = 0; index < HOTDOG_PDC_ID_SIZE; index++) {
		unsigned int high, low;
		char high_character = value[index * 2];
		char low_character = value[index * 2 + 1];

		if (high_character >= '0' && high_character <= '9')
			high = (unsigned int)(high_character - '0');
		else if (high_character >= 'a' && high_character <= 'f')
			high = (unsigned int)(high_character - 'a' + 10);
		else if (high_character >= 'A' && high_character <= 'F')
			high = (unsigned int)(high_character - 'A' + 10);
		else
			return -EINVAL;
		if (low_character >= '0' && low_character <= '9')
			low = (unsigned int)(low_character - '0');
		else if (low_character >= 'a' && low_character <= 'f')
			low = (unsigned int)(low_character - 'a' + 10);
		else if (low_character >= 'A' && low_character <= 'F')
			low = (unsigned int)(low_character - 'A' + 10);
		else
			return -EINVAL;
		id->value[index] = (unsigned char)((high << 4) | low);
	}
	id->length = HOTDOG_PDC_ID_SIZE;
	return 0;
}

static int parse_phase(const char *value, enum hotdog_readiness_phase *phase)
{
	if (!strcmp(value, "locked"))
		*phase = HOTDOG_READINESS_LOCKED;
	else if (!strcmp(value, "registering"))
		*phase = HOTDOG_READINESS_REGISTERING;
	else if (!strcmp(value, "ready"))
		*phase = HOTDOG_READINESS_READY;
	else
		return -EINVAL;
	return 0;
}

static int parse_app_state(const char *value, enum hotdog_uim_app_state *state)
{
	if (!strcmp(value, "none") || !strcmp(value, "detected"))
		*state = HOTDOG_UIM_APP_DETECTED;
	else if (!strcmp(value, "pin-required"))
		*state = HOTDOG_UIM_APP_PIN_REQUIRED;
	else if (!strcmp(value, "puk-required"))
		*state = HOTDOG_UIM_APP_PUK_REQUIRED;
	else if (!strcmp(value, "ready"))
		*state = HOTDOG_UIM_APP_READY;
	else if (!strcmp(value, "blocked"))
		*state = HOTDOG_UIM_APP_BLOCKED;
	else
		return -EINVAL;
	return 0;
}

int hotdog_radio_readiness_read(const char *path,
				 struct hotdog_radio_readiness *readiness)
{
	bool seen_base[READINESS_BASE_KEYS] = { false };
	bool seen_sub[HOTDOG_PDC_MAX_SUBSCRIPTIONS][READINESS_SUB_KEYS] = { { false } };
	char line[256];
	struct stat status;
	FILE *stream;
	int descriptor, result = 0;

	if (!path || !readiness)
		return -EINVAL;
	memset(readiness, 0, sizeof(*readiness));
	descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
	if (descriptor < 0)
		return -errno;
	if (fstat(descriptor, &status)) {
		result = -errno;
		close(descriptor);
		return result;
	}
	if (!S_ISREG(status.st_mode) || (status.st_mode & (S_IWGRP | S_IWOTH)))
		result = -EPERM;
	else if (status.st_size <= 0 || status.st_size > 8192)
		result = -EFBIG;
	if (result) {
		close(descriptor);
		return result;
	}
	stream = fdopen(descriptor, "r");
	if (!stream) {
		result = -errno;
		close(descriptor);
		return result;
	}
	while (fgets(line, sizeof(line), stream)) {
		char *separator, *key, *value;
		size_t length = strcspn(line, "\r\n");
		unsigned int subscription, parsed;
		int base = -1, field = -1;

		if (line[length] == '\0' && !feof(stream)) {
			result = -EOVERFLOW;
			break;
		}
		line[length] = '\0';
		if (!length || line[0] == '#')
			continue;
		separator = strchr(line, '=');
		if (!separator || separator == line || !separator[1]) {
			result = -EINVAL;
			break;
		}
		*separator = '\0';
		key = line;
		value = separator + 1;
		if (!strcmp(key, "schema")) {
			base = 0;
			result = strcmp(value, "2") ? -EINVAL : 0;
		} else if (!strcmp(key, "boot-id")) {
			base = 1;
			if (!valid_boot_id(value))
				result = -EINVAL;
			else
				memcpy(readiness->boot_id, value, strlen(value) + 1);
		} else if (!strcmp(key, "phase")) {
			base = 2;
			result = parse_phase(value, &readiness->phase);
		} else if (!strcmp(key, "dms")) {
			base = 3;
			if (strcmp(value, "online"))
				result = -EINVAL;
			else
				readiness->dms_online = true;
		} else if (!strcmp(key, "modem-sha256")) {
			base = 4;
			if (!valid_hex(value, 64))
				result = -EINVAL;
			else
				memcpy(readiness->modem_sha256, value, 65);
		} else if (!strcmp(key, "mcfg-archive-sha256")) {
			base = 5;
			if (!valid_hex(value, 64))
				result = -EINVAL;
			else
				memcpy(readiness->mcfg_sha256, value, 65);
		} else if (sscanf(key, "sub%u-", &subscription) == 1 &&
			   subscription < HOTDOG_PDC_MAX_SUBSCRIPTIONS) {
			struct hotdog_readiness_subscription *current =
				&readiness->subscriptions[subscription];
			char prefix[16];
			const char *name;

			snprintf(prefix, sizeof(prefix), "sub%u-", subscription);
			if (strncmp(key, prefix, strlen(prefix))) {
				result = -EINVAL;
				break;
			}
			name = key + strlen(prefix);
			if (!strcmp(name, "populated")) {
				field = 0;
				result = parse_uint(value, 1, &parsed);
				current->populated = parsed != 0;
			} else if (!strcmp(name, "slot")) {
				field = 1;
				result = parse_uint(value, HOTDOG_UIM_MAX_SLOTS,
						    &current->physical_slot);
			} else if (!strcmp(name, "app-state")) {
				field = 2;
				result = parse_app_state(value, &current->app_state);
			} else if (!strcmp(name, "pin1-retries")) {
				field = 3;
				result = parse_uint(value, 255, &current->retries.pin1);
			} else if (!strcmp(name, "puk1-retries")) {
				field = 4;
				result = parse_uint(value, 255, &current->retries.puk1);
			} else if (!strcmp(name, "selected")) {
				field = 5;
				result = parse_id(value, &current->selected);
			} else if (!strcmp(name, "active")) {
				field = 6;
				result = parse_id(value, &current->active);
			} else if (!strcmp(name, "pending")) {
				field = 7;
				result = parse_id(value, &current->pending);
			} else {
				result = -EINVAL;
			}
			if (field >= 0) {
				if (seen_sub[subscription][field])
					result = -EINVAL;
				seen_sub[subscription][field] = true;
			}
		} else {
			result = -EINVAL;
		}
		if (base >= 0) {
			if (seen_base[base])
				result = -EINVAL;
			seen_base[base] = true;
		}
		if (result)
			break;
	}
	if (!result && ferror(stream))
		result = -EIO;
	fclose(stream);
	if (!result) {
		size_t i, j;

		for (i = 0; i < READINESS_BASE_KEYS; i++)
			if (!seen_base[i])
				return -ENODATA;
		for (i = 0; i < HOTDOG_PDC_MAX_SUBSCRIPTIONS; i++)
			for (j = 0; j < READINESS_SUB_KEYS; j++)
				if (!seen_sub[i][j])
					return -ENODATA;
		result = hotdog_radio_readiness_validate(readiness);
	}
	return result;
}
