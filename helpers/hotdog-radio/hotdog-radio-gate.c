/* SPDX-License-Identifier: GPL-2.0-only */
#define _POSIX_C_SOURCE 200809L
#include "hotdog-radio-gate.h"

#include "hotdog-mcfg.h"
#include "hotdog-radio-approval.h"

#include <errno.h>
#include <fcntl.h>
#include <glib.h>
#include <stdio.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <unistd.h>

#define HOTDOG_MODEM_MAX_SIZE (128U * 1024U * 1024U)

static int read_boot_id(const char *path, char *boot_id, size_t size)
{
	char line[64];
	FILE *stream;
	size_t length;

	stream = fopen(path, "r");
	if (!stream)
		return -errno;
	if (!fgets(line, sizeof(line), stream)) {
		fclose(stream);
		return -EIO;
	}
	if (fgetc(stream) != EOF) {
		fclose(stream);
		return -EOVERFLOW;
	}
	fclose(stream);
	length = strcspn(line, "\r\n");
	if (length != HOTDOG_APPROVAL_BOOT_ID_SIZE - 1 || length >= size)
		return -EINVAL;
	memcpy(boot_id, line, length);
	boot_id[length] = '\0';
	return 0;
}

static int sha256_file(const char *path, char output[HOTDOG_MCFG_RUNTIME_SHA256_SIZE])
{
	unsigned char buffer[65536], digest[32];
	GChecksum *checksum;
	struct stat status;
	gsize digest_size = sizeof(digest);
	ssize_t count;
	int descriptor, result = 0;
	size_t index;

	descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
	if (descriptor < 0)
		return -errno;
	if (fstat(descriptor, &status)) {
		result = -errno;
		goto out;
	}
	if (!S_ISREG(status.st_mode) || status.st_size <= 0 ||
	    status.st_size > HOTDOG_MODEM_MAX_SIZE) {
		result = -EFBIG;
		goto out;
	}
	checksum = g_checksum_new(G_CHECKSUM_SHA256);
	if (!checksum) {
		result = -ENOMEM;
		goto out;
	}
	while ((count = read(descriptor, buffer, sizeof(buffer))) != 0) {
		if (count < 0) {
			if (errno == EINTR)
				continue;
			result = -errno;
			break;
		}
		g_checksum_update(checksum, buffer, (gsize)count);
	}
	if (!result) {
		g_checksum_get_digest(checksum, digest, &digest_size);
		for (index = 0; index < sizeof(digest); index++)
			snprintf(output + index * 2, 3, "%02x", digest[index]);
		output[64] = '\0';
	}
	g_checksum_free(checksum);
out:
	close(descriptor);
	return result;
}

int hotdog_radio_gate_validate(
	const struct hotdog_radio_gate_paths *paths,
	const struct hotdog_pdc_catalog *catalog,
	const struct hotdog_pdc_subscription *subscriptions,
	size_t subscription_count,
	struct hotdog_mcfg_runtime *runtime)
{
	struct hotdog_radio_approval approval;
	char boot_id[HOTDOG_APPROVAL_BOOT_ID_SIZE];
	char modem_sha256[HOTDOG_MCFG_RUNTIME_SHA256_SIZE];
	size_t profiles, signatures, files;
	int result;

	if (!paths || !paths->approval || !paths->runtime_manifest || !paths->boot_id ||
	    !paths->modem || !paths->mcfg_root || !catalog || !subscriptions || !runtime)
		return -EINVAL;
	result = hotdog_mcfg_runtime_read(paths->runtime_manifest, runtime);
	if (result)
		return result;
	result = read_boot_id(paths->boot_id, boot_id, sizeof(boot_id));
	if (result)
		return result;
	result = sha256_file(paths->modem, modem_sha256);
	if (result)
		return result;
	if (strcasecmp(modem_sha256, runtime->modem_sha256))
		return -ESTALE;
	result = hotdog_mcfg_tree_counts(
		paths->mcfg_root, &profiles, &signatures, &files);
	if (result)
		return result;
	if (profiles != runtime->profile_count || signatures != runtime->signature_count ||
	    files != runtime->catalog_file_count || catalog->count != runtime->profile_count)
		return -EPROTO;
	result = hotdog_radio_approval_read(paths->approval, &approval);
	if (result)
		return result;
	return hotdog_radio_approval_validate(
		&approval, boot_id, runtime->modem_sha256, runtime->archive_sha256,
		subscriptions, subscription_count);
}
