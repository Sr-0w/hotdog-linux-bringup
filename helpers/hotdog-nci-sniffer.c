// SPDX-License-Identifier: GPL-2.0-only
/* Capture raw NCI control traffic exposed by the Linux NFC raw socket. */

#include <errno.h>
#include <linux/nfc.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define BUFFER_SIZE 4096

static volatile sig_atomic_t stop;

static void handle_signal(int signal)
{
	(void)signal;
	stop = 1;
}

static void print_hex(const uint8_t *data, size_t length)
{
	for (size_t i = 0; i < length; i++)
		printf("%02x", data[i]);
}

int main(void)
{
	struct sigaction action = {
		.sa_handler = handle_signal,
	};
	uint8_t buffer[BUFFER_SIZE];
	int fd;

	setvbuf(stdout, NULL, _IONBF, 0);
	sigemptyset(&action.sa_mask);
	sigaction(SIGINT, &action, NULL);
	sigaction(SIGTERM, &action, NULL);

	fd = socket(AF_NFC, SOCK_RAW, NFC_SOCKPROTO_RAW);
	if (fd < 0) {
		perror("socket(AF_NFC, SOCK_RAW)");
		return 1;
	}

	while (!stop) {
		struct timespec timestamp;
		ssize_t length;

		length = recv(fd, buffer, sizeof(buffer), 0);
		if (length < 0) {
			if (errno == EINTR)
				continue;
			perror("recv");
			close(fd);
			return 1;
		}
		if (length < NFC_RAW_HEADER_SIZE)
			continue;

		clock_gettime(CLOCK_MONOTONIC, &timestamp);
		printf("%lld.%09ld dev=%u dir=%s type=%u nci=",
		       (long long)timestamp.tv_sec, timestamp.tv_nsec,
		       buffer[0], buffer[1] & 1 ? "tx" : "rx",
		       buffer[1] >> 1);
		print_hex(buffer + NFC_RAW_HEADER_SIZE,
			  (size_t)length - NFC_RAW_HEADER_SIZE);
		putchar('\n');
	}

	close(fd);
	return 0;
}
