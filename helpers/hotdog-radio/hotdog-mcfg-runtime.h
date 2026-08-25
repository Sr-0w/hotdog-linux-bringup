/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef HOTDOG_MCFG_RUNTIME_H
#define HOTDOG_MCFG_RUNTIME_H

#include <stddef.h>

#define HOTDOG_MCFG_RUNTIME_SHA256_SIZE 65
#define HOTDOG_MCFG_RUNTIME_BUILD_SIZE 128

struct hotdog_mcfg_runtime {
	char source_sha256[HOTDOG_MCFG_RUNTIME_SHA256_SIZE];
	char modem_sha256[HOTDOG_MCFG_RUNTIME_SHA256_SIZE];
	char archive_sha256[HOTDOG_MCFG_RUNTIME_SHA256_SIZE];
	char mpss_build[HOTDOG_MCFG_RUNTIME_BUILD_SIZE];
	size_t profile_count;
	size_t signature_count;
	size_t catalog_file_count;
};

int hotdog_mcfg_runtime_read(const char *path,
			     struct hotdog_mcfg_runtime *runtime);

#endif
