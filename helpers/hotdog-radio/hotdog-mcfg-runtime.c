/* SPDX-License-Identifier: GPL-2.0-only */
#define _POSIX_C_SOURCE 200809L
#include "hotdog-mcfg-runtime.h"

#include <errno.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

static bool valid_sha256(const char *value)
{
	size_t index;

	if (strlen(value) != HOTDOG_MCFG_RUNTIME_SHA256_SIZE - 1)
		return false;
	for (index = 0; index < HOTDOG_MCFG_RUNTIME_SHA256_SIZE - 1; index++)
		if (!((value[index] >= '0' && value[index] <= '9') ||
		      (value[index] >= 'a' && value[index] <= 'f') ||
		      (value[index] >= 'A' && value[index] <= 'F')))
			return false;
	return true;
}

static int parse_count(const char *value, size_t maximum, size_t *count)
{
	char *end;
	unsigned long parsed;

	errno = 0;
	parsed = strtoul(value, &end, 10);
	if (errno || !*value || *end || !parsed || parsed > maximum)
		return -EINVAL;
	*count = (size_t)parsed;
	return 0;
}

int hotdog_mcfg_runtime_read(const char *path,
			     struct hotdog_mcfg_runtime *runtime)
{
	enum { SCHEMA, SOURCE, BUILD, MODEM, ARCHIVE, PROFILES, SIGNATURES, FILES, KEY_COUNT };
	bool seen[KEY_COUNT] = { false };
	char line[256];
	struct stat status;
	FILE *stream;
	int result = 0;

	if (!path || !runtime)
		return -EINVAL;
	memset(runtime, 0, sizeof(*runtime));
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
		char *separator, *key, *value, *target = NULL;
		size_t target_size = 0, length = strcspn(line, "\r\n");
		int key_index = -1;

		if (line[length] == '\0' && !feof(stream)) { result = -EOVERFLOW; break; }
		line[length] = '\0';
		if (!length || line[0] == '#') continue;
		separator = strchr(line, '=');
		if (!separator || separator == line || !separator[1]) { result = -EINVAL; break; }
		*separator = '\0'; key = line; value = separator + 1;
		if (!strcmp(key, "schema")) key_index = SCHEMA;
		else if (!strcmp(key, "source-sha256")) { key_index = SOURCE; target = runtime->source_sha256; target_size = sizeof(runtime->source_sha256); }
		else if (!strcmp(key, "mpss-build")) { key_index = BUILD; target = runtime->mpss_build; target_size = sizeof(runtime->mpss_build); }
		else if (!strcmp(key, "modem-sha256")) { key_index = MODEM; target = runtime->modem_sha256; target_size = sizeof(runtime->modem_sha256); }
		else if (!strcmp(key, "mcfg-archive-sha256")) { key_index = ARCHIVE; target = runtime->archive_sha256; target_size = sizeof(runtime->archive_sha256); }
		else if (!strcmp(key, "profile-count")) key_index = PROFILES;
		else if (!strcmp(key, "signature-count")) key_index = SIGNATURES;
		else if (!strcmp(key, "catalog-file-count")) key_index = FILES;
		else { result = -EINVAL; break; }
		if (seen[key_index]) { result = -EINVAL; break; }
		seen[key_index] = true;
		if (key_index == SCHEMA) result = strcmp(value, "1") ? -EINVAL : 0;
		else if (key_index == PROFILES) result = parse_count(value, 256, &runtime->profile_count);
		else if (key_index == SIGNATURES) result = parse_count(value, 256, &runtime->signature_count);
		else if (key_index == FILES) result = parse_count(value, 1024, &runtime->catalog_file_count);
		else if (target) {
			if (strlen(value) >= target_size ||
			    (key_index != BUILD && !valid_sha256(value))) result = -EINVAL;
			else memcpy(target, value, strlen(value) + 1);
		}
		if (result) break;
	}
	if (!result && ferror(stream)) result = -EIO;
	fclose(stream);
	if (!result) {
		size_t index;
		for (index = 0; index < KEY_COUNT; index++)
			if (!seen[index]) return -ENODATA;
		if (!runtime->mpss_build[0]) return -ENODATA;
	}
	return result;
}
