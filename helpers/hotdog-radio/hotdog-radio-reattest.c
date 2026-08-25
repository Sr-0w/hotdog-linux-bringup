/* SPDX-License-Identifier: GPL-2.0-only */
#define _POSIX_C_SOURCE 200809L
#include "hotdog-radio-reattest.h"

#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define REATTEST_REQUEST "pin-unlocked\n"

int hotdog_radio_reattest_consume(const char *path)
{
	char content[sizeof(REATTEST_REQUEST)] = { 0 };
	struct stat status;
	ssize_t count;
	int descriptor, result = 0;
	size_t offset = 0;

	if (!path)
		return -EINVAL;
	descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
	if (descriptor < 0)
		return errno == ENOENT ? 0 : -errno;
	if (fstat(descriptor, &status))
		result = -errno;
	else if (!S_ISREG(status.st_mode) || status.st_mode & (S_IWGRP | S_IWOTH) ||
		 status.st_size != (off_t)(sizeof(REATTEST_REQUEST) - 1))
		result = -EPERM;
	while (!result && offset < sizeof(REATTEST_REQUEST) - 1) {
		count = read(descriptor, content + offset,
			     sizeof(REATTEST_REQUEST) - 1 - offset);
		if (count < 0 && errno == EINTR)
			continue;
		if (count <= 0) {
			result = count < 0 ? -errno : -EIO;
			break;
		}
		offset += (size_t)count;
	}
	if (close(descriptor) && !result)
		result = -errno;
	if (!result && memcmp(content, REATTEST_REQUEST,
			      sizeof(REATTEST_REQUEST) - 1))
		result = -EPROTO;
	if (result)
		return result;
	if (unlink(path))
		return -errno;
	return 1;
}
