/* SPDX-License-Identifier: GPL-2.0-only */
#define _POSIX_C_SOURCE 200809L
#include "hotdog-radio-approval.h"

#include <ctype.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>

static int hex_value(char value)
{
	if (value >= '0' && value <= '9')
		return value - '0';
	if (value >= 'a' && value <= 'f')
		return value - 'a' + 10;
	if (value >= 'A' && value <= 'F')
		return value - 'A' + 10;
	return -1;
}

static bool valid_sha256(const char *value)
{
	size_t index;

	if (strlen(value) != HOTDOG_APPROVAL_SHA256_SIZE - 1)
		return false;
	for (index = 0; index < HOTDOG_APPROVAL_SHA256_SIZE - 1; index++)
		if (hex_value(value[index]) < 0)
			return false;
	return true;
}

static bool valid_boot_id(const char *value)
{
	static const size_t hyphens[] = { 8, 13, 18, 23 };
	size_t index, hyphen = 0;

	if (strlen(value) != HOTDOG_APPROVAL_BOOT_ID_SIZE - 1)
		return false;
	for (index = 0; index < HOTDOG_APPROVAL_BOOT_ID_SIZE - 1; index++) {
		if (hyphen < sizeof(hyphens) / sizeof(hyphens[0]) &&
		    index == hyphens[hyphen]) {
			if (value[index] != '-')
				return false;
			hyphen++;
		} else if (hex_value(value[index]) < 0) {
			return false;
		}
	}
	return true;
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
		int high = hex_value(value[index * 2]);
		int low = hex_value(value[index * 2 + 1]);

		if (high < 0 || low < 0)
			return -EINVAL;
		id->value[index] = (unsigned char)((high << 4) | low);
	}
	id->length = HOTDOG_PDC_ID_SIZE;
	return 0;
}

int hotdog_radio_approval_read(const char *path,
			       struct hotdog_radio_approval *approval)
{
	bool seen_schema = false, seen_boot = false, seen_modem = false, seen_mcfg = false;
	bool seen_sub[HOTDOG_PDC_MAX_SUBSCRIPTIONS] = { false };
	char line[256];
	struct stat status;
	FILE *stream;
	int result = 0;

	if (!path || !approval)
		return -EINVAL;
	memset(approval, 0, sizeof(*approval));
	if (lstat(path, &status))
		return -errno;
	if (!S_ISREG(status.st_mode) || (status.st_mode & (S_IWGRP | S_IWOTH)))
		return -EPERM;
	if (status.st_size <= 0 || status.st_size > 4096)
		return -EFBIG;
	stream = fopen(path, "r");
	if (!stream)
		return -errno;
	while (fgets(line, sizeof(line), stream)) {
		char *separator, *key, *value;
		size_t length = strcspn(line, "\r\n");
		unsigned int subscription;

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
			if (seen_schema || strcmp(value, "1")) result = -EINVAL;
			seen_schema = true;
		} else if (!strcmp(key, "boot-id")) {
			if (seen_boot || !valid_boot_id(value)) result = -EINVAL;
			else memcpy(approval->boot_id, value, strlen(value) + 1);
			seen_boot = true;
		} else if (!strcmp(key, "modem-sha256")) {
			if (seen_modem || !valid_sha256(value)) result = -EINVAL;
			else memcpy(approval->modem_sha256, value, strlen(value) + 1);
			seen_modem = true;
		} else if (!strcmp(key, "mcfg-archive-sha256")) {
			if (seen_mcfg || !valid_sha256(value)) result = -EINVAL;
			else memcpy(approval->mcfg_sha256, value, strlen(value) + 1);
			seen_mcfg = true;
		} else if (sscanf(key, "sub%u-selected", &subscription) == 1 &&
			   subscription < HOTDOG_PDC_MAX_SUBSCRIPTIONS) {
			char expected[32];

			snprintf(expected, sizeof(expected), "sub%u-selected", subscription);
			if (strcmp(key, expected) || seen_sub[subscription] ||
			    parse_id(value, &approval->selected[subscription]))
				result = -EINVAL;
			seen_sub[subscription] = true;
		} else {
			result = -EINVAL;
		}
		if (result)
			break;
	}
	if (!result && ferror(stream))
		result = -EIO;
	fclose(stream);
	if (!result && (!seen_schema || !seen_boot || !seen_modem || !seen_mcfg ||
			!seen_sub[0] || !seen_sub[1] || !seen_sub[2]))
		result = -ENODATA;
	return result;
}

int hotdog_radio_approval_validate(
	const struct hotdog_radio_approval *approval, const char *boot_id,
	const char *modem_sha256, const char *mcfg_sha256,
	const struct hotdog_pdc_subscription *subscriptions, size_t subscription_count)
{
	size_t index;

	if (!approval || !boot_id || !modem_sha256 || !mcfg_sha256 || !subscriptions ||
	    subscription_count > HOTDOG_PDC_MAX_SUBSCRIPTIONS)
		return -EINVAL;
	if (strcmp(approval->boot_id, boot_id) ||
	    strcasecmp(approval->modem_sha256, modem_sha256) ||
	    strcasecmp(approval->mcfg_sha256, mcfg_sha256))
		return -ESTALE;
	for (index = 0; index < HOTDOG_PDC_MAX_SUBSCRIPTIONS; index++) {
		bool populated = index < subscription_count && subscriptions[index].populated;

		if (populated != (approval->selected[index].length != 0))
			return -EPROTO;
		if (populated && !hotdog_pdc_id_equal(&approval->selected[index],
						     &subscriptions[index].selected))
			return -ESTALE;
	}
	return 0;
}
