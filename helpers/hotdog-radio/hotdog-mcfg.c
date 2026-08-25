/* SPDX-License-Identifier: GPL-2.0-only */
#define _POSIX_C_SOURCE 200809L
#include "hotdog-mcfg.h"

#include <dirent.h>
#include <errno.h>
#include <glib.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static bool safe_relative_path(const char *path)
{
	const char *part = path;

	if (!path || !*path || *path == '/')
		return false;
	while (*part) {
		const char *end = strchr(part, '/');
		size_t length = end ? (size_t)(end - part) : strlen(part);

		if (!length || (length == 1 && part[0] == '.') ||
		    (length == 2 && part[0] == '.' && part[1] == '.'))
			return false;
		if (!end)
			break;
		part = end + 1;
	}
	return true;
}

static bool has_suffix(const char *value, const char *suffix)
{
	size_t value_length = strlen(value);
	size_t suffix_length = strlen(suffix);

	return value_length >= suffix_length &&
	       !memcmp(value + value_length - suffix_length, suffix, suffix_length);
}

static int sha1_file(const char *path, struct hotdog_pdc_id *id)
{
	unsigned char buffer[16384];
	gsize digest_length = HOTDOG_PDC_ID_SIZE;
	GChecksum *checksum;
	FILE *stream;
	size_t count;
	int result = 0;

	stream = fopen(path, "rb");
	if (!stream)
		return -errno;
	checksum = g_checksum_new(G_CHECKSUM_SHA1);
	if (!checksum) {
		fclose(stream);
		return -ENOMEM;
	}
	while ((count = fread(buffer, 1, sizeof(buffer), stream)) > 0)
		g_checksum_update(checksum, buffer, count);
	if (ferror(stream))
		result = -EIO;
	else {
		g_checksum_get_digest(checksum, id->value, &digest_length);
		if (digest_length != HOTDOG_PDC_ID_SIZE)
			result = -EIO;
		else
			id->length = digest_length;
	}
	g_checksum_free(checksum);
	fclose(stream);
	return result;
}

static int add_profile(const char *full_path, const char *relative,
		       struct hotdog_pdc_catalog *catalog)
{
	struct hotdog_pdc_config *config;
	int result;

	if (catalog->count >= HOTDOG_PDC_MAX_CONFIGS)
		return -ENOSPC;
	if (!safe_relative_path(relative) || strlen(relative) >= HOTDOG_PDC_PATH_SIZE)
		return -EINVAL;
	config = &catalog->configs[catalog->count];
	memset(config, 0, sizeof(*config));
	result = hotdog_mbn_read(full_path, &config->metadata);
	if (result)
		return result;
	result = sha1_file(full_path, &config->id);
	if (result)
		return result;
	config->version = config->metadata.oem_version > config->metadata.qc_version ?
		config->metadata.oem_version : config->metadata.qc_version;
	memcpy(config->path, relative, strlen(relative) + 1);
	catalog->count++;
	return 0;
}

static int scan_directory(const char *root, const char *relative,
			  struct hotdog_pdc_catalog *catalog)
{
	char directory_path[HOTDOG_PDC_PATH_SIZE * 2];
	struct dirent *entry;
	DIR *directory;
	int written;
	int result = 0;

	if (relative[0])
		written = snprintf(directory_path, sizeof(directory_path), "%s/%s", root, relative);
	else
		written = snprintf(directory_path, sizeof(directory_path), "%s", root);
	if (written < 0 || (size_t)written >= sizeof(directory_path))
		return -ENAMETOOLONG;
	directory = opendir(directory_path);
	if (!directory)
		return -errno;
	while ((entry = readdir(directory))) {
		char child_relative[HOTDOG_PDC_PATH_SIZE];
		char child_path[HOTDOG_PDC_PATH_SIZE * 2];
		struct stat status;

		if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, ".."))
			continue;
		written = snprintf(child_relative, sizeof(child_relative), "%s%s%s",
				  relative, relative[0] ? "/" : "", entry->d_name);
		if (written < 0 || (size_t)written >= sizeof(child_relative)) {
			result = -ENAMETOOLONG;
			break;
		}
		written = snprintf(child_path, sizeof(child_path), "%s/%s", root, child_relative);
		if (written < 0 || (size_t)written >= sizeof(child_path)) {
			result = -ENAMETOOLONG;
			break;
		}
		if (lstat(child_path, &status)) {
			result = -errno;
			break;
		}
		if (S_ISLNK(status.st_mode)) {
			result = -ELOOP;
			break;
		}
		if (S_ISDIR(status.st_mode)) {
			result = scan_directory(root, child_relative, catalog);
			if (result)
				break;
		} else if (S_ISREG(status.st_mode) && !strcmp(entry->d_name, "mcfg_sw.mbn")) {
			result = add_profile(child_path, child_relative, catalog);
			if (result)
				break;
		}
	}
	closedir(directory);
	return result;
}

static int compare_config_path(const void *left, const void *right)
{
	const struct hotdog_pdc_config *a = left;
	const struct hotdog_pdc_config *b = right;

	return strcmp(a->path, b->path);
}

static int validate_unique_ids(const struct hotdog_pdc_catalog *catalog)
{
	size_t left, right;

	for (left = 0; left < catalog->count; left++)
		for (right = left + 1; right < catalog->count; right++)
			if (hotdog_pdc_id_equal(&catalog->configs[left].id,
						&catalog->configs[right].id))
				return -EEXIST;
	return 0;
}

static int inspect_list(const char *root, struct hotdog_mcfg_report *report)
{
	char list_path[HOTDOG_PDC_PATH_SIZE * 2];
	char line[HOTDOG_PDC_PATH_SIZE + 32];
	FILE *stream;

	if (snprintf(list_path, sizeof(list_path), "%s/mbn_sw.txt", root) >=
	    (int)sizeof(list_path))
		return -ENAMETOOLONG;
	stream = fopen(list_path, "r");
	if (!stream)
		return -errno;
	while (fgets(line, sizeof(line), stream)) {
		char full_path[HOTDOG_PDC_PATH_SIZE * 2];
		char *relative;
		size_t length = strcspn(line, "\r\n");

		if (line[length] == '\0' && !feof(stream)) {
			fclose(stream);
			return -EOVERFLOW;
		}
		line[length] = '\0';
		if (!length)
			continue;
		if (strncmp(line, "mcfg_sw/", 8) || !safe_relative_path(line) ||
		    !has_suffix(line, "/mcfg_sw.mbn")) {
			fclose(stream);
			return -EINVAL;
		}
		relative = line + 8;
		report->listed++;
		if (snprintf(full_path, sizeof(full_path), "%s/%s", root, relative) >=
		    (int)sizeof(full_path)) {
			fclose(stream);
			return -ENAMETOOLONG;
		}
		if (access(full_path, F_OK))
			report->listed_missing++;
	}
	if (ferror(stream)) {
		fclose(stream);
		return -EIO;
	}
	fclose(stream);
	return 0;
}

int hotdog_mcfg_catalog_load(const char *root, struct hotdog_pdc_catalog *catalog,
			     struct hotdog_mcfg_report *report)
{
	struct stat status;
	int result;

	if (!root || !catalog || !report)
		return -EINVAL;
	memset(catalog, 0, sizeof(*catalog));
	memset(report, 0, sizeof(*report));
	if (lstat(root, &status))
		return -errno;
	if (!S_ISDIR(status.st_mode))
		return -ENOTDIR;
	result = inspect_list(root, report);
	if (result)
		return result;
	result = scan_directory(root, "", catalog);
	if (result)
		return result;
	if (!catalog->count)
		return -ENOENT;
	qsort(catalog->configs, catalog->count, sizeof(catalog->configs[0]),
	      compare_config_path);
	return validate_unique_ids(catalog);
}
