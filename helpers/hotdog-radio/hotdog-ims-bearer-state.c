/* SPDX-License-Identifier: GPL-2.0-only */
#define _POSIX_C_SOURCE 200809L
#include "hotdog-ims-bearer-state.h"

#include <errno.h>
#include <fcntl.h>
#include <glib.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define STATE_MAX_SIZE 8192
#define STATE_BASE_KEYS 3
#define STATE_SUB_KEYS 11

static bool valid_boot_id(const char *value)
{
	static const size_t hyphens[] = { 8, 13, 18, 23 };
	size_t index, hyphen = 0;

	if (strlen(value) != HOTDOG_IMS_BEARER_BOOT_ID_SIZE - 1)
		return false;
	for (index = 0; index < HOTDOG_IMS_BEARER_BOOT_ID_SIZE - 1; index++) {
		if (hyphen < G_N_ELEMENTS(hyphens) && index == hyphens[hyphen]) {
			if (value[index] != '-')
				return false;
			hyphen++;
		} else if (!g_ascii_isxdigit(value[index])) {
			return false;
		}
	}
	return true;
}

static bool valid_ifname(const char *ifname)
{
	size_t index, length = strnlen(ifname, 16);

	if (!length || length >= 16 || ifname[0] == '-')
		return false;
	for (index = 0; index < length; index++)
		if (!((ifname[index] >= 'a' && ifname[index] <= 'z') ||
		      (ifname[index] >= 'A' && ifname[index] <= 'Z') ||
		      (ifname[index] >= '0' && ifname[index] <= '9') ||
		      ifname[index] == '_' || ifname[index] == '-'))
			return false;
	return true;
}

int hotdog_ims_bearer_runtime_validate(
	const struct hotdog_ims_bearer_runtime_state *state)
{
	size_t index;

	if (!state || !valid_boot_id(state->boot_id))
		return -EINVAL;
	for (index = 0; index < HOTDOG_NETWORK_MAX_SUBSCRIPTIONS; index++) {
		const struct hotdog_ims_bearer_subscription_state *sub =
			&state->subscriptions[index];
		struct hotdog_ims_bearer_subscription_state empty = { 0 };

		if (!sub->populated) {
			if (memcmp(sub, &empty, sizeof(empty)))
				return -EPROTO;
			continue;
		}
		if (sub->status == HOTDOG_IMS_BEARER_ABSENT ||
		    sub->status > HOTDOG_IMS_BEARER_BLOCKED ||
		    sub->profile > UINT8_MAX || sub->family > HOTDOG_IP_V4V6 ||
		    sub->mux_id > UINT8_MAX ||
		    sub->pcscf_address_count > HOTDOG_NETWORK_MAX_PCSCF ||
		    sub->pcscf_domain_count > HOTDOG_NETWORK_MAX_PCSCF ||
		    (sub->profile_selected != (sub->profile != 0)) ||
		    (!!sub->mux_id != !!sub->ifname[0]) ||
		    (sub->ifname[0] && !valid_ifname(sub->ifname)))
			return -EINVAL;
		switch (sub->status) {
		case HOTDOG_IMS_BEARER_DISCOVERING:
			if (sub->profile_selected || sub->mux_id || sub->error || sub->residue ||
			    sub->pcscf_address_count || sub->pcscf_domain_count)
				return -EPROTO;
			break;
		case HOTDOG_IMS_BEARER_UNAVAILABLE:
			if (sub->profile_selected || sub->mux_id || !sub->error || sub->residue ||
			    sub->pcscf_address_count || sub->pcscf_domain_count)
				return -EPROTO;
			break;
		case HOTDOG_IMS_BEARER_STARTING:
			if (!sub->profile_selected || sub->error || sub->residue)
				return -EPROTO;
			break;
		case HOTDOG_IMS_BEARER_UP:
			if (!sub->profile_selected || !sub->mux_id || sub->error || sub->residue ||
			    (!sub->pcscf_address_count && !sub->pcscf_domain_count))
				return -EPROTO;
			break;
		case HOTDOG_IMS_BEARER_FAILED:
			if (!sub->error || sub->residue || sub->mux_id ||
			    sub->pcscf_address_count || sub->pcscf_domain_count)
				return -EPROTO;
			break;
		case HOTDOG_IMS_BEARER_BLOCKED:
			if (!sub->error || !sub->residue || !sub->mux_id)
				return -EPROTO;
			break;
		case HOTDOG_IMS_BEARER_ABSENT:
			return -EPROTO;
		}
	}
	return 0;
}

const char *hotdog_ims_bearer_runtime_status_name(
	enum hotdog_ims_bearer_runtime_status status)
{
	static const char *const names[] = {
		"absent", "discovering", "unavailable", "starting", "up",
		"failed", "blocked",
	};

	return status <= HOTDOG_IMS_BEARER_BLOCKED ? names[status] : "invalid";
}

static int parse_status(const char *value,
			enum hotdog_ims_bearer_runtime_status *status)
{
	unsigned int index;

	for (index = 0; index <= HOTDOG_IMS_BEARER_BLOCKED; index++)
		if (!strcmp(value, hotdog_ims_bearer_runtime_status_name(index))) {
			*status = index;
			return 0;
		}
	return -EINVAL;
}

static int parse_family(const char *value, bool selected,
			enum hotdog_ip_family *family)
{
	if (!selected)
		return strcmp(value, "-") ? -EINVAL : 0;
	if (!strcmp(value, "ipv4"))
		*family = HOTDOG_IP_V4;
	else if (!strcmp(value, "ipv6"))
		*family = HOTDOG_IP_V6;
	else if (!strcmp(value, "ipv4v6"))
		*family = HOTDOG_IP_V4V6;
	else
		return -EINVAL;
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

	if (!path || strlen(path) >= sizeof(directory_path))
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
		close(directory);
		return -errno;
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

int hotdog_ims_bearer_runtime_write(
	const char *path, const struct hotdog_ims_bearer_runtime_state *state)
{
	GKeyFile *key_file;
	char *data;
	gsize size;
	size_t index;
	int result = hotdog_ims_bearer_runtime_validate(state);

	if (result || !path)
		return result ? result : -EINVAL;
	key_file = g_key_file_new();
	g_key_file_set_integer(key_file, "hotdog-ims-bearer", "schema", 1);
	g_key_file_set_string(key_file, "hotdog-ims-bearer", "boot-id", state->boot_id);
	g_key_file_set_uint64(key_file, "hotdog-ims-bearer", "generation", state->generation);
	for (index = 0; index < HOTDOG_NETWORK_MAX_SUBSCRIPTIONS; index++) {
		const struct hotdog_ims_bearer_subscription_state *sub =
			&state->subscriptions[index];
		char group[24];

		snprintf(group, sizeof(group), "subscription%zu", index);
		g_key_file_set_boolean(key_file, group, "populated", sub->populated);
		g_key_file_set_string(key_file, group, "status",
			hotdog_ims_bearer_runtime_status_name(sub->status));
		g_key_file_set_boolean(key_file, group, "profile-selected", sub->profile_selected);
		g_key_file_set_uint64(key_file, group, "profile", sub->profile);
		g_key_file_set_string(key_file, group, "family",
			sub->profile_selected ? hotdog_ip_family_name(sub->family) : "-");
		g_key_file_set_uint64(key_file, group, "mux-id", sub->mux_id);
		g_key_file_set_string(key_file, group, "ifname", sub->ifname[0] ? sub->ifname : "-");
		g_key_file_set_uint64(key_file, group, "pcscf-address-count",
				      sub->pcscf_address_count);
		g_key_file_set_uint64(key_file, group, "pcscf-domain-count",
				      sub->pcscf_domain_count);
		g_key_file_set_uint64(key_file, group, "error", sub->error);
		g_key_file_set_boolean(key_file, group, "residue", sub->residue);
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
	else if (status.st_size <= 0 || status.st_size > STATE_MAX_SIZE)
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
	if (result || memchr(buffer, '\0', offset)) {
		g_free(buffer);
		return result ? result : -EPROTO;
	}
	buffer[offset] = '\0';
	*data = buffer;
	*size = offset;
	return 0;
}

static int verify_keys(GKeyFile *key_file, const char *group,
		       const char *const *expected, size_t expected_count)
{
	bool seen[STATE_SUB_KEYS] = { false };
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

static int get_uint(GKeyFile *key_file, const char *group, const char *key,
		    unsigned int maximum, unsigned int *value)
{
	GError *error = NULL;
	guint64 parsed = g_key_file_get_uint64(key_file, group, key, &error);

	if (error || parsed > maximum) {
		g_clear_error(&error);
		return -EINVAL;
	}
	*value = (unsigned int)parsed;
	return 0;
}

int hotdog_ims_bearer_runtime_read(
	const char *path, struct hotdog_ims_bearer_runtime_state *state)
{
	static const char *const base_keys[] = { "schema", "boot-id", "generation" };
	static const char *const sub_keys[] = {
		"populated", "status", "profile-selected", "profile", "family",
		"mux-id", "ifname", "pcscf-address-count", "pcscf-domain-count",
		"error", "residue",
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
	if (group_count != HOTDOG_NETWORK_MAX_SUBSCRIPTIONS + 1) {
		result = -ENODATA;
		goto out;
	}
	result = verify_keys(key_file, "hotdog-ims-bearer", base_keys, STATE_BASE_KEYS);
	if (result)
		goto out;
	if (g_key_file_get_integer(key_file, "hotdog-ims-bearer", "schema", &error) != 1 ||
	    error) {
		g_clear_error(&error);
		result = -EINVAL;
		goto out;
	}
	value = g_key_file_get_string(key_file, "hotdog-ims-bearer", "boot-id", NULL);
	if (!value || strlen(value) >= sizeof(state->boot_id)) {
		g_free(value);
		result = -EINVAL;
		goto out;
	}
	memcpy(state->boot_id, value, strlen(value) + 1);
	g_free(value);
	result = get_uint(key_file, "hotdog-ims-bearer", "generation", UINT_MAX,
			  &state->generation);
	for (index = 0; !result && index < HOTDOG_NETWORK_MAX_SUBSCRIPTIONS; index++) {
		struct hotdog_ims_bearer_subscription_state *sub =
			&state->subscriptions[index];
		char group[24];
		unsigned int count = 0;

		snprintf(group, sizeof(group), "subscription%zu", index);
		result = verify_keys(key_file, group, sub_keys, STATE_SUB_KEYS);
		if (result)
			break;
		sub->populated = g_key_file_get_boolean(key_file, group, "populated", &error);
		if (error) { g_clear_error(&error); result = -EINVAL; break; }
		value = g_key_file_get_string(key_file, group, "status", NULL);
		result = value ? parse_status(value, &sub->status) : -EINVAL;
		g_free(value);
		if (result) break;
		sub->profile_selected = g_key_file_get_boolean(
			key_file, group, "profile-selected", &error);
		if (error) { g_clear_error(&error); result = -EINVAL; break; }
		result = get_uint(key_file, group, "profile", UINT8_MAX, &sub->profile);
		value = g_key_file_get_string(key_file, group, "family", NULL);
		if (!result)
			result = value ? parse_family(value, sub->profile_selected, &sub->family) :
				-EINVAL;
		g_free(value);
		if (!result) result = get_uint(key_file, group, "mux-id", UINT8_MAX, &sub->mux_id);
		value = g_key_file_get_string(key_file, group, "ifname", NULL);
		if (!result && (!value || strlen(value) >= sizeof(sub->ifname))) result = -EINVAL;
		else if (!result && strcmp(value, "-")) memcpy(sub->ifname, value, strlen(value) + 1);
		g_free(value);
		if (!result) {
			result = get_uint(key_file, group, "pcscf-address-count",
				HOTDOG_NETWORK_MAX_PCSCF, &count);
			sub->pcscf_address_count = count;
		}
		if (!result) {
			result = get_uint(key_file, group, "pcscf-domain-count",
				HOTDOG_NETWORK_MAX_PCSCF, &count);
			sub->pcscf_domain_count = count;
		}
		if (!result) result = get_uint(key_file, group, "error", UINT_MAX, &sub->error);
		if (!result) {
			sub->residue = g_key_file_get_boolean(key_file, group, "residue", &error);
			if (error) { g_clear_error(&error); result = -EINVAL; }
		}
	}
	if (!result)
		result = hotdog_ims_bearer_runtime_validate(state);
out:
	g_strfreev(groups);
	g_key_file_unref(key_file);
	return result;
}
