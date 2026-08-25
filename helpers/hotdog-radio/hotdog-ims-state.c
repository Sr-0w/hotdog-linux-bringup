/* SPDX-License-Identifier: GPL-2.0-only */
#define _POSIX_C_SOURCE 200809L
#include "hotdog-ims-state.h"

#include <errno.h>
#include <fcntl.h>
#include <glib.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define IMS_STATE_MAX_SIZE 8192
#define IMS_BASE_KEYS 3
#define IMS_SUB_KEYS 9

static bool valid_boot_id(const char *value)
{
	static const size_t hyphens[] = { 8, 13, 18, 23 };
	size_t index, hyphen = 0;

	if (strlen(value) != HOTDOG_IMS_BOOT_ID_SIZE - 1)
		return false;
	for (index = 0; index < HOTDOG_IMS_BOOT_ID_SIZE - 1; index++) {
		if (hyphen < 4 && index == hyphens[hyphen]) {
			if (value[index] != '-')
				return false;
			hyphen++;
		} else if (!g_ascii_isxdigit(value[index])) {
			return false;
		}
	}
	return true;
}

static bool service_rat_valid(const struct hotdog_ims_state *ims,
			      uint32_t capability, enum hotdog_ims_rat rat)
{
	bool present = (ims->capabilities | ims->limited_capabilities) & capability;

	return present ? rat != HOTDOG_IMS_RAT_UNKNOWN :
		rat == HOTDOG_IMS_RAT_UNKNOWN;
}

int hotdog_ims_runtime_validate(const struct hotdog_ims_runtime_state *state)
{
	const uint32_t known = HOTDOG_IMS_CAP_VOICE | HOTDOG_IMS_CAP_VIDEO |
		HOTDOG_IMS_CAP_SMS;
	size_t index;

	if (!state || !valid_boot_id(state->boot_id))
		return -EINVAL;
	for (index = 0; index < HOTDOG_TELEPHONY_MAX_SUBSCRIPTIONS; index++) {
		const struct hotdog_ims_subscription_state *subscription =
			&state->subscriptions[index];
		const struct hotdog_ims_state *ims = &subscription->ims;

		if (!subscription->populated) {
			struct hotdog_ims_state empty = { 0 };

			if (memcmp(ims, &empty, sizeof(empty)))
				return -EPROTO;
			continue;
		}
		if (ims->registration > HOTDOG_IMS_BLOCKED ||
		    ims->rat > HOTDOG_IMS_RAT_NR5G || ims->voice_rat > HOTDOG_IMS_RAT_NR5G ||
		    ims->video_rat > HOTDOG_IMS_RAT_NR5G || ims->sms_rat > HOTDOG_IMS_RAT_NR5G ||
		    ims->sip_code > UINT16_MAX || ims->capabilities & ~known ||
		    ims->limited_capabilities & ~known ||
		    ims->capabilities & ims->limited_capabilities)
			return -EINVAL;
		if (ims->registration == HOTDOG_IMS_REGISTERED &&
		    ims->rat == HOTDOG_IMS_RAT_UNKNOWN)
			return -ENODATA;
		if (!service_rat_valid(ims, HOTDOG_IMS_CAP_VOICE, ims->voice_rat) ||
		    !service_rat_valid(ims, HOTDOG_IMS_CAP_VIDEO, ims->video_rat) ||
		    !service_rat_valid(ims, HOTDOG_IMS_CAP_SMS, ims->sms_rat))
			return -EPROTO;
	}
	return 0;
}

static const char *rat_name(enum hotdog_ims_rat rat)
{
	static const char *const names[] = { "unknown", "lte", "wlan", "nr5g" };

	return rat <= HOTDOG_IMS_RAT_NR5G ? names[rat] : "invalid";
}

static int parse_rat(const char *value, enum hotdog_ims_rat *rat)
{
	if (!strcmp(value, "unknown")) *rat = HOTDOG_IMS_RAT_UNKNOWN;
	else if (!strcmp(value, "lte")) *rat = HOTDOG_IMS_RAT_LTE;
	else if (!strcmp(value, "wlan")) *rat = HOTDOG_IMS_RAT_WLAN;
	else if (!strcmp(value, "nr5g")) *rat = HOTDOG_IMS_RAT_NR5G;
	else return -EINVAL;
	return 0;
}

static int parse_registration(const char *value,
			      enum hotdog_ims_registration *registration)
{
	if (!strcmp(value, "none")) *registration = HOTDOG_IMS_NONE;
	else if (!strcmp(value, "registering")) *registration = HOTDOG_IMS_REGISTERING;
	else if (!strcmp(value, "registered")) *registration = HOTDOG_IMS_REGISTERED;
	else if (!strcmp(value, "blocked")) *registration = HOTDOG_IMS_BLOCKED;
	else return -EINVAL;
	return 0;
}

static int secure_write(const char *path, const char *data, size_t size)
{
	char directory_path[512], temporary[512];
	struct stat status;
	char *separator;
	ssize_t written;
	int descriptor, directory, result = 0;
	size_t offset = 0;

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
	if (fstat(directory, &status))
		result = -errno;
	else if (!S_ISDIR(status.st_mode) || status.st_mode & (S_IWGRP | S_IWOTH))
		result = -EPERM;
	if (result) {
		close(directory);
		return result;
	}
	if (snprintf(temporary, sizeof(temporary), "%s.new.%ld", path, (long)getpid()) >=
	    (int)sizeof(temporary)) {
		close(directory);
		return -ENAMETOOLONG;
	}
	descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
			  0644);
	if (descriptor < 0) {
		result = -errno;
		close(directory);
		return result;
	}
	while (offset < size) {
		written = write(descriptor, data + offset, size - offset);
		if (written < 0 && errno == EINTR)
			continue;
		if (written <= 0) {
			result = written < 0 ? -errno : -EIO;
			break;
		}
		offset += (size_t)written;
	}
	if (!result && fsync(descriptor))
		result = -errno;
	if (close(descriptor) && !result)
		result = -errno;
	if (!result && rename(temporary, path))
		result = -errno;
	if (!result && fsync(directory))
		result = -errno;
	if (result)
		unlink(temporary);
	close(directory);
	return result;
}

int hotdog_ims_runtime_write(const char *path,
			     const struct hotdog_ims_runtime_state *state)
{
	GKeyFile *key_file;
	char *data;
	gsize size;
	size_t index;
	int result;

	result = hotdog_ims_runtime_validate(state);
	if (result || !path)
		return result ? result : -EINVAL;
	key_file = g_key_file_new();
	g_key_file_set_integer(key_file, "hotdog-ims", "schema", 1);
	g_key_file_set_string(key_file, "hotdog-ims", "boot-id", state->boot_id);
	g_key_file_set_uint64(key_file, "hotdog-ims", "generation", state->generation);
	for (index = 0; index < HOTDOG_TELEPHONY_MAX_SUBSCRIPTIONS; index++) {
		const struct hotdog_ims_subscription_state *subscription =
			&state->subscriptions[index];
		const struct hotdog_ims_state *ims = &subscription->ims;
		char group[16];

		snprintf(group, sizeof(group), "subscription%zu", index);
		g_key_file_set_boolean(key_file, group, "populated", subscription->populated);
		g_key_file_set_string(key_file, group, "registration",
			hotdog_ims_registration_name(ims->registration));
		g_key_file_set_string(key_file, group, "rat", rat_name(ims->rat));
		g_key_file_set_uint64(key_file, group, "capabilities", ims->capabilities);
		g_key_file_set_uint64(key_file, group, "limited-capabilities",
				      ims->limited_capabilities);
		g_key_file_set_uint64(key_file, group, "sip-code", ims->sip_code);
		g_key_file_set_string(key_file, group, "voice-rat", rat_name(ims->voice_rat));
		g_key_file_set_string(key_file, group, "video-rat", rat_name(ims->video_rat));
		g_key_file_set_string(key_file, group, "sms-rat", rat_name(ims->sms_rat));
	}
	data = g_key_file_to_data(key_file, &size, NULL);
	g_key_file_unref(key_file);
	if (!data)
		return -EIO;
	result = secure_write(path, data, size);
	g_free(data);
	return result;
}

static int secure_read(const char *path, char **data, size_t *size)
{
	struct stat status;
	char *buffer;
	ssize_t count;
	int descriptor, result = 0;
	size_t offset = 0;

	descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
	if (descriptor < 0)
		return -errno;
	if (fstat(descriptor, &status))
		result = -errno;
	else if (!S_ISREG(status.st_mode) || status.st_mode & (S_IWGRP | S_IWOTH))
		result = -EPERM;
	else if (status.st_size <= 0 || status.st_size > IMS_STATE_MAX_SIZE)
		result = -EFBIG;
	if (result) {
		close(descriptor);
		return result;
	}
	buffer = g_malloc((size_t)status.st_size + 1);
	while (offset < (size_t)status.st_size) {
		count = read(descriptor, buffer + offset, (size_t)status.st_size - offset);
		if (count < 0 && errno == EINTR)
			continue;
		if (count <= 0) {
			result = count < 0 ? -errno : -EIO;
			break;
		}
		offset += (size_t)count;
	}
	close(descriptor);
	if (result) {
		g_free(buffer);
		return result;
	}
	if (memchr(buffer, '\0', offset)) {
		g_free(buffer);
		return -EPROTO;
	}
	buffer[offset] = '\0';
	*data = buffer;
	*size = offset;
	return 0;
}

static int verify_keys(GKeyFile *key_file, const char *group,
		       const char *const *expected, size_t expected_count)
{
	bool seen[IMS_SUB_KEYS] = { false };
	char **keys;
	gsize count, index, candidate;

	keys = g_key_file_get_keys(key_file, group, &count, NULL);
	if (!keys || count != expected_count) {
		g_strfreev(keys);
		return -ENODATA;
	}
	for (index = 0; index < count; index++) {
		for (candidate = 0; candidate < expected_count; candidate++)
			if (!strcmp(keys[index], expected[candidate]))
				break;
		if (candidate == expected_count || seen[candidate]) {
			g_strfreev(keys);
			return -EINVAL;
		}
		seen[candidate] = true;
	}
	g_strfreev(keys);
	return 0;
}

int hotdog_ims_runtime_read(const char *path,
			    struct hotdog_ims_runtime_state *state)
{
	static const char *const base_keys[] = { "schema", "boot-id", "generation" };
	static const char *const sub_keys[] = {
		"populated", "registration", "rat", "capabilities",
		"limited-capabilities", "sip-code", "voice-rat", "video-rat", "sms-rat",
	};
	GKeyFile *key_file;
	GError *error = NULL;
	char **groups, *data = NULL, *value;
	gsize group_count, size = 0;
	size_t index;
	int result;

	if (!path || !state)
		return -EINVAL;
	memset(state, 0, sizeof(*state));
	result = secure_read(path, &data, &size);
	if (result)
		return result;
	key_file = g_key_file_new();
	if (!g_key_file_load_from_data(key_file, data, size, G_KEY_FILE_NONE, &error)) {
		g_clear_error(&error);
		g_free(data);
		g_key_file_unref(key_file);
		return -EINVAL;
	}
	g_free(data);
	groups = g_key_file_get_groups(key_file, &group_count);
	if (group_count != HOTDOG_TELEPHONY_MAX_SUBSCRIPTIONS + 1) {
		result = -ENODATA;
		goto out;
	}
	result = verify_keys(key_file, "hotdog-ims", base_keys, IMS_BASE_KEYS);
	if (result)
		goto out;
	if (g_key_file_get_integer(key_file, "hotdog-ims", "schema", &error) != 1 || error) {
		g_clear_error(&error);
		result = -EINVAL;
		goto out;
	}
	value = g_key_file_get_string(key_file, "hotdog-ims", "boot-id", NULL);
	if (!value || strlen(value) >= sizeof(state->boot_id)) {
		g_free(value);
		result = -EINVAL;
		goto out;
	}
	memcpy(state->boot_id, value, strlen(value) + 1);
	g_free(value);
	{
		guint64 generation = g_key_file_get_uint64(
			key_file, "hotdog-ims", "generation", &error);

		if (!error && generation <= UINT32_MAX)
			state->generation = (unsigned int)generation;
		else
			result = -EINVAL;
	}
	if (error || result) {
		g_clear_error(&error);
		goto out;
	}
	for (index = 0; index < HOTDOG_TELEPHONY_MAX_SUBSCRIPTIONS; index++) {
		struct hotdog_ims_subscription_state *subscription =
			&state->subscriptions[index];
		struct hotdog_ims_state *ims = &subscription->ims;
		guint64 numeric;
		char group[16];

		snprintf(group, sizeof(group), "subscription%zu", index);
		result = verify_keys(key_file, group, sub_keys, IMS_SUB_KEYS);
		if (result)
			goto out;
		subscription->populated = g_key_file_get_boolean(
			key_file, group, "populated", &error);
		if (error) goto parse_error;
		value = g_key_file_get_string(key_file, group, "registration", &error);
		if (error || parse_registration(value, &ims->registration)) goto parse_error_value;
		g_free(value); value = NULL;
		value = g_key_file_get_string(key_file, group, "rat", &error);
		if (error || parse_rat(value, &ims->rat)) goto parse_error_value;
		g_free(value); value = NULL;
		numeric = g_key_file_get_uint64(key_file, group, "capabilities", &error);
		if (error || numeric > UINT32_MAX) goto parse_error;
		ims->capabilities = (uint32_t)numeric;
		numeric = g_key_file_get_uint64(key_file, group, "limited-capabilities", &error);
		if (error || numeric > UINT32_MAX) goto parse_error;
		ims->limited_capabilities = (uint32_t)numeric;
		numeric = g_key_file_get_uint64(key_file, group, "sip-code", &error);
		if (error || numeric > UINT16_MAX) goto parse_error;
		ims->sip_code = (unsigned int)numeric;
		value = g_key_file_get_string(key_file, group, "voice-rat", &error);
		if (error || parse_rat(value, &ims->voice_rat)) goto parse_error_value;
		g_free(value); value = NULL;
		value = g_key_file_get_string(key_file, group, "video-rat", &error);
		if (error || parse_rat(value, &ims->video_rat)) goto parse_error_value;
		g_free(value); value = NULL;
		value = g_key_file_get_string(key_file, group, "sms-rat", &error);
		if (error || parse_rat(value, &ims->sms_rat)) goto parse_error_value;
		g_free(value); value = NULL;
		continue;
parse_error_value:
		g_free(value);
parse_error:
		g_clear_error(&error);
		result = -EINVAL;
		goto out;
	}
	result = hotdog_ims_runtime_validate(state);
out:
	g_strfreev(groups);
	g_key_file_unref(key_file);
	return result;
}
