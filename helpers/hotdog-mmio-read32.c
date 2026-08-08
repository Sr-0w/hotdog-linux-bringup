// SPDX-License-Identifier: GPL-2.0-only
/* Read selected 32-bit MMIO registers through /dev/mem. */

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

static int read_register(int fd, long page_size, uint64_t address)
{
	uint64_t page = address & ~((uint64_t)page_size - 1);
	size_t offset = (size_t)(address - page);
	void *mapping;
	uint32_t value;

	if ((address & 3) != 0) {
		fprintf(stderr, "unaligned address: 0x%" PRIx64 "\n", address);
		return 1;
	}

	mapping = mmap(NULL, (size_t)page_size, PROT_READ, MAP_SHARED, fd,
		       (off_t)page);
	if (mapping == MAP_FAILED) {
		fprintf(stderr, "mmap 0x%" PRIx64 ": %s\n", page,
			strerror(errno));
		return 1;
	}

	value = *(volatile uint32_t *)((char *)mapping + offset);
	printf("0x%08" PRIx64 "=0x%08" PRIx32 "\n", address, value);
	munmap(mapping, (size_t)page_size);
	return 0;
}

int main(int argc, char **argv)
{
	long page_size;
	int fd;
	int status = 0;
	int i;

	if (argc < 2) {
		fprintf(stderr, "usage: %s ADDRESS [ADDRESS ...]\n", argv[0]);
		return 2;
	}

	page_size = sysconf(_SC_PAGESIZE);
	if (page_size <= 0) {
		perror("sysconf(_SC_PAGESIZE)");
		return 1;
	}

	fd = open("/dev/mem", O_RDONLY | O_SYNC);
	if (fd < 0) {
		perror("open /dev/mem");
		return 1;
	}

	for (i = 1; i < argc; i++) {
		char *end;
		uint64_t address;

		errno = 0;
		address = strtoull(argv[i], &end, 0);
		if (errno || *end != '\0') {
			fprintf(stderr, "invalid address: %s\n", argv[i]);
			status = 1;
			continue;
		}
		status |= read_register(fd, page_size, address);
	}

	close(fd);
	return status;
}
