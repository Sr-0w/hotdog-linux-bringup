#define _GNU_SOURCE

#include <errno.h>
#include <linux/reboot.h>
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

int main(int argc, char **argv)
{
	const char *mode;
	long rc;

	if (argc != 2) {
		fprintf(stderr, "usage: %s bootloader|recovery\n", argv[0]);
		return 2;
	}

	mode = argv[1];
	if (strcmp(mode, "bootloader") != 0 && strcmp(mode, "recovery") != 0) {
		fprintf(stderr, "unsupported reboot mode: %s\n", mode);
		return 2;
	}

	sync();
	rc = syscall(SYS_reboot,
		     LINUX_REBOOT_MAGIC1,
		     LINUX_REBOOT_MAGIC2,
		     LINUX_REBOOT_CMD_RESTART2,
		     mode);
	if (rc < 0) {
		fprintf(stderr, "reboot(%s) failed: %s\n", mode, strerror(errno));
		return 1;
	}

	return 0;
}
