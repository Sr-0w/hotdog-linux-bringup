#define _GNU_SOURCE

#include <errno.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define HELPER_MARKER "HOTDOG_BOUNDED_EXEC_V1"
#define MIN_TIMEOUT_SEC 1U
#define MAX_TIMEOUT_SEC 86400U
#define POLL_NSEC 100000000L

static void usage(const char *name)
{
	fprintf(stderr,
		"usage: %s --timeout SECONDS -- COMMAND [ARG ...]\n"
		"       %s --self-test\n",
		name, name);
}

static bool parse_timeout(const char *value, uint32_t *seconds)
{
	char *end = NULL;
	unsigned long parsed;

	errno = 0;
	parsed = strtoul(value, &end, 10);
	if (errno != 0 || end == value || *end != '\0' ||
	    parsed < MIN_TIMEOUT_SEC || parsed > MAX_TIMEOUT_SEC)
		return false;

	*seconds = (uint32_t)parsed;
	return true;
}

static int monotonic_now(struct timespec *value)
{
	if (clock_gettime(CLOCK_MONOTONIC, value) < 0) {
		fprintf(stderr, "clock_gettime: %s\n", strerror(errno));
		return -1;
	}
	return 0;
}

static bool deadline_reached(const struct timespec *now,
			     const struct timespec *deadline)
{
	return now->tv_sec > deadline->tv_sec ||
	       (now->tv_sec == deadline->tv_sec &&
		now->tv_nsec >= deadline->tv_nsec);
}

static int sleep_poll_interval(void)
{
	struct timespec remaining = {
		.tv_sec = 0,
		.tv_nsec = POLL_NSEC,
	};

	while (nanosleep(&remaining, &remaining) < 0) {
		if (errno != EINTR) {
			fprintf(stderr, "nanosleep: %s\n", strerror(errno));
			return -1;
		}
	}
	return 0;
}

static int child_status(int status)
{
	if (WIFEXITED(status))
		return WEXITSTATUS(status);
	if (WIFSIGNALED(status))
		return 128 + WTERMSIG(status);
	return 125;
}

static void terminate_child(pid_t pid)
{
	int status;
	struct timespec grace = {
		.tv_sec = 1,
		.tv_nsec = 0,
	};

	kill(-pid, SIGTERM);
	kill(pid, SIGTERM);
	while (nanosleep(&grace, &grace) < 0 && errno == EINTR)
		;

	if (waitpid(pid, &status, WNOHANG) == pid)
		return;

	kill(-pid, SIGKILL);
	kill(pid, SIGKILL);
	(void)waitpid(pid, &status, WNOHANG);
}

static int run_bounded(char *const command[], uint32_t timeout_sec)
{
	struct timespec deadline;
	struct timespec now;
	pid_t pid;
	pid_t waited;
	int status;

	if (monotonic_now(&deadline) < 0)
		return 125;
	deadline.tv_sec += timeout_sec;

	pid = fork();
	if (pid < 0) {
		fprintf(stderr, "fork: %s\n", strerror(errno));
		return 125;
	}
	if (pid == 0) {
		(void)setpgid(0, 0);
		execvp(command[0], command);
		fprintf(stderr, "exec %s: %s\n", command[0], strerror(errno));
		_exit(127);
	}

	(void)setpgid(pid, pid);
	for (;;) {
		waited = waitpid(pid, &status, WNOHANG);
		if (waited == pid)
			return child_status(status);
		if (waited < 0) {
			if (errno == EINTR)
				continue;
			fprintf(stderr, "waitpid: %s\n", strerror(errno));
			terminate_child(pid);
			return 125;
		}

		if (monotonic_now(&now) < 0) {
			terminate_child(pid);
			return 125;
		}
		if (deadline_reached(&now, &deadline)) {
			fprintf(stderr, "%s TIMEOUT command=%s seconds=%u\n",
				HELPER_MARKER, command[0], timeout_sec);
			terminate_child(pid);
			return 124;
		}
		if (sleep_poll_interval() < 0) {
			terminate_child(pid);
			return 125;
		}
	}
}

static int self_test(void)
{
	pid_t pid;
	int status;

	pid = fork();
	if (pid < 0)
		return 1;
	if (pid == 0) {
		(void)setpgid(0, 0);
		for (;;)
			pause();
	}

	(void)setpgid(pid, pid);
	terminate_child(pid);
	if (waitpid(pid, &status, WNOHANG) != -1 || errno != ECHILD)
		return 1;

	printf("%s SELF_TEST_OK\n", HELPER_MARKER);
	return 0;
}

int main(int argc, char **argv)
{
	uint32_t timeout_sec = 0;
	int command_index = 0;
	int i;

	if (argc == 2 && strcmp(argv[1], "--self-test") == 0)
		return self_test();

	for (i = 1; i < argc; i++) {
		if (strcmp(argv[i], "--timeout") == 0 && i + 1 < argc) {
			if (!parse_timeout(argv[++i], &timeout_sec)) {
				fprintf(stderr, "invalid timeout: %s\n", argv[i]);
				return 2;
			}
		} else if (strcmp(argv[i], "--") == 0 && i + 1 < argc) {
			command_index = i + 1;
			break;
		} else {
			usage(argv[0]);
			return 2;
		}
	}

	if (timeout_sec == 0 || command_index == 0) {
		usage(argv[0]);
		return 2;
	}

	return run_bounded(&argv[command_index], timeout_sec);
}
