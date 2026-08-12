// SPDX-License-Identifier: GPL-2.0-only
/*
 * Minimal generic-netlink helper for testing one NFC protocol at a time.
 *
 * This deliberately does not subscribe to target events or print tag data.
 * It is intended for hardware bring-up where enabling the full protocol mask
 * makes it impossible to identify which RF discovery configuration failed.
 */

#include <errno.h>
#include <linux/genetlink.h>
#include <linux/netlink.h>
#include <linux/nfc.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#ifndef NLA_ALIGNTO
#define NLA_ALIGNTO 4
#endif
#ifndef NLA_ALIGN
#define NLA_ALIGN(len) (((len) + NLA_ALIGNTO - 1) & ~(NLA_ALIGNTO - 1))
#endif

#define BUFFER_SIZE 4096

static uint32_t sequence;

static int add_attr(struct nlmsghdr *nlh, size_t capacity, uint16_t type,
		    const void *data, size_t data_len)
{
	size_t attr_len = NLA_HDRLEN + data_len;
	size_t new_len = NLMSG_ALIGN(nlh->nlmsg_len) + NLA_ALIGN(attr_len);
	struct nlattr *attr;

	if (new_len > capacity)
		return -EMSGSIZE;

	attr = (struct nlattr *)((char *)nlh + NLMSG_ALIGN(nlh->nlmsg_len));
	attr->nla_type = type;
	attr->nla_len = attr_len;
	memcpy((char *)attr + NLA_HDRLEN, data, data_len);
	memset((char *)attr + attr_len, 0, NLA_ALIGN(attr_len) - attr_len);
	nlh->nlmsg_len = new_len;

	return 0;
}

static int send_message(int fd, struct nlmsghdr *nlh)
{
	struct sockaddr_nl kernel = {
		.nl_family = AF_NETLINK,
	};
	ssize_t sent;

	sent = sendto(fd, nlh, nlh->nlmsg_len, 0,
		      (struct sockaddr *)&kernel, sizeof(kernel));
	if (sent < 0)
		return -errno;
	if ((size_t)sent != nlh->nlmsg_len)
		return -EIO;

	return 0;
}

static int receive_reply(int fd, uint32_t expected_sequence, void *buffer,
			 size_t capacity, ssize_t *reply_len)
{
	for (;;) {
		ssize_t len = recv(fd, buffer, capacity, 0);
		struct nlmsghdr *nlh;
		unsigned int remaining;

		if (len < 0) {
			if (errno == EINTR)
				continue;
			return -errno;
		}

		remaining = (unsigned int)len;
		for (nlh = buffer; NLMSG_OK(nlh, remaining);
		     nlh = NLMSG_NEXT(nlh, remaining)) {
			struct nlmsgerr *error;

			if (nlh->nlmsg_seq != expected_sequence)
				continue;
			if (nlh->nlmsg_type != NLMSG_ERROR) {
				*reply_len = len;
				return 0;
			}
			if (nlh->nlmsg_len < NLMSG_LENGTH(sizeof(*error)))
				return -EBADMSG;

			error = NLMSG_DATA(nlh);
			if (error->error)
				return error->error;
			*reply_len = len;
			return 0;
		}
	}
}

static void init_message(struct nlmsghdr *nlh, uint16_t family, uint8_t command,
			 uint16_t flags)
{
	struct genlmsghdr *genl;

	memset(nlh, 0, BUFFER_SIZE);
	nlh->nlmsg_len = NLMSG_LENGTH(GENL_HDRLEN);
	nlh->nlmsg_type = family;
	nlh->nlmsg_flags = NLM_F_REQUEST | flags;
	nlh->nlmsg_seq = ++sequence;
	nlh->nlmsg_pid = getpid();

	genl = NLMSG_DATA(nlh);
	genl->cmd = command;
	genl->version = NFC_GENL_VERSION;
}

static int resolve_family(int fd, const char *name)
{
	char request[BUFFER_SIZE];
	char reply[BUFFER_SIZE];
	struct nlmsghdr *nlh = (struct nlmsghdr *)request;
	ssize_t reply_len;
	int ret;

	init_message(nlh, GENL_ID_CTRL, CTRL_CMD_GETFAMILY, 0);
	((struct genlmsghdr *)NLMSG_DATA(nlh))->version = 1;
	ret = add_attr(nlh, sizeof(request), CTRL_ATTR_FAMILY_NAME,
		       name, strlen(name) + 1);
	if (ret)
		return ret;

	ret = send_message(fd, nlh);
	if (ret)
		return ret;
	ret = receive_reply(fd, nlh->nlmsg_seq, reply, sizeof(reply), &reply_len);
	if (ret)
		return ret;

	for (nlh = (struct nlmsghdr *)reply; NLMSG_OK(nlh, reply_len);
	     nlh = NLMSG_NEXT(nlh, reply_len)) {
		struct genlmsghdr *genl;
		struct nlattr *attr;
		unsigned int remaining;

		if (nlh->nlmsg_type == NLMSG_ERROR)
			continue;
		genl = NLMSG_DATA(nlh);
		remaining = nlh->nlmsg_len - NLMSG_HDRLEN - GENL_HDRLEN;
		attr = (struct nlattr *)((char *)genl + GENL_HDRLEN);
		while (remaining >= sizeof(*attr) &&
		       attr->nla_len >= sizeof(*attr) &&
		       attr->nla_len <= remaining) {
			if (attr->nla_type == CTRL_ATTR_FAMILY_ID &&
			    attr->nla_len >= NLA_HDRLEN + sizeof(uint16_t)) {
				uint16_t family;

				memcpy(&family, (char *)attr + NLA_HDRLEN,
				       sizeof(family));
				return family;
			}
			remaining -= NLA_ALIGN(attr->nla_len);
			attr = (struct nlattr *)((char *)attr +
						NLA_ALIGN(attr->nla_len));
		}
	}

	return -ENOENT;
}

static int nfc_command(int fd, uint16_t family, uint8_t command,
		       uint32_t device, uint32_t protocols)
{
	char request[BUFFER_SIZE];
	char reply[BUFFER_SIZE];
	struct nlmsghdr *nlh = (struct nlmsghdr *)request;
	ssize_t reply_len;
	int ret;

	init_message(nlh, family, command, NLM_F_ACK);
	ret = add_attr(nlh, sizeof(request), NFC_ATTR_DEVICE_INDEX,
		       &device, sizeof(device));
	if (ret)
		return ret;

	if (command == NFC_CMD_START_POLL) {
		ret = add_attr(nlh, sizeof(request), NFC_ATTR_IM_PROTOCOLS,
			       &protocols, sizeof(protocols));
		if (ret)
			return ret;
		ret = add_attr(nlh, sizeof(request), NFC_ATTR_PROTOCOLS,
			       &protocols, sizeof(protocols));
		if (ret)
			return ret;
	}

	ret = send_message(fd, nlh);
	if (ret)
		return ret;
	return receive_reply(fd, nlh->nlmsg_seq, reply, sizeof(reply),
			     &reply_len);
}

static int parse_protocol(const char *name, uint32_t *protocols)
{
	struct protocol_name {
		const char *name;
		uint32_t mask;
	};
	static const struct protocol_name names[] = {
		{ "reader", NFC_PROTO_JEWEL_MASK | NFC_PROTO_MIFARE_MASK |
			    NFC_PROTO_FELICA_MASK | NFC_PROTO_ISO14443_MASK |
			    NFC_PROTO_ISO14443_B_MASK },
		{ "all", NFC_PROTO_JEWEL_MASK | NFC_PROTO_MIFARE_MASK |
			 NFC_PROTO_FELICA_MASK | NFC_PROTO_ISO14443_MASK |
			 NFC_PROTO_NFC_DEP_MASK | NFC_PROTO_ISO14443_B_MASK },
		{ "jewel", NFC_PROTO_JEWEL_MASK },
		{ "mifare", NFC_PROTO_MIFARE_MASK },
		{ "felica", NFC_PROTO_FELICA_MASK },
		{ "iso14443-a", NFC_PROTO_ISO14443_MASK },
		{ "iso14443-b", NFC_PROTO_ISO14443_B_MASK },
		{ "nfc-dep", NFC_PROTO_NFC_DEP_MASK },
		{ "iso15693", NFC_PROTO_ISO15693_MASK },
	};
	size_t i;

	for (i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
		if (!strcmp(name, names[i].name)) {
			*protocols = names[i].mask;
			return 0;
		}
	}

	return -EINVAL;
}

static void usage(const char *program)
{
	fprintf(stderr,
		"Usage:\n"
		"  %s DEVICE up|down|stop\n"
		"  %s DEVICE start PROTOCOL\n"
		"  %s DEVICE test PROTOCOL SECONDS\n\n"
		"PROTOCOL: reader, all, jewel, mifare, felica, iso14443-a, "
		"iso14443-b, nfc-dep, iso15693\n",
		program, program, program);
}

int main(int argc, char **argv)
{
	struct sockaddr_nl local = {
		.nl_family = AF_NETLINK,
	};
	uint32_t device;
	uint32_t protocols = 0;
	unsigned long seconds = 0;
	char *end;
	int family;
	int command;
	int fd;
	int ret;

	if (argc < 3) {
		usage(argv[0]);
		return 2;
	}

	errno = 0;
	device = strtoul(argv[1], &end, 0);
	if (errno || *end) {
		fprintf(stderr, "Invalid device index: %s\n", argv[1]);
		return 2;
	}

	if (!strcmp(argv[2], "up")) {
		command = NFC_CMD_DEV_UP;
	} else if (!strcmp(argv[2], "down")) {
		command = NFC_CMD_DEV_DOWN;
	} else if (!strcmp(argv[2], "stop")) {
		command = NFC_CMD_STOP_POLL;
	} else if (!strcmp(argv[2], "start") || !strcmp(argv[2], "test")) {
		if (argc < 4 || parse_protocol(argv[3], &protocols)) {
			usage(argv[0]);
			return 2;
		}
		command = NFC_CMD_START_POLL;
		if (!strcmp(argv[2], "test")) {
			if (argc != 5) {
				usage(argv[0]);
				return 2;
			}
			errno = 0;
			seconds = strtoul(argv[4], &end, 0);
			if (errno || *end || !seconds) {
				fprintf(stderr, "Invalid duration: %s\n", argv[4]);
				return 2;
			}
		}
	} else {
		usage(argv[0]);
		return 2;
	}

	fd = socket(AF_NETLINK, SOCK_RAW, NETLINK_GENERIC);
	if (fd < 0) {
		perror("socket");
		return 1;
	}
	local.nl_pid = getpid();
	if (bind(fd, (struct sockaddr *)&local, sizeof(local)) < 0) {
		perror("bind");
		close(fd);
		return 1;
	}

	family = resolve_family(fd, NFC_GENL_NAME);
	if (family < 0) {
		fprintf(stderr, "Cannot resolve NFC generic-netlink family: %s\n",
			strerror(-family));
		close(fd);
		return 1;
	}

	if (seconds) {
		ret = nfc_command(fd, family, NFC_CMD_DEV_UP, device, 0);
		if (ret && ret != -EALREADY) {
			fprintf(stderr, "Cannot power NFC device: %s\n", strerror(-ret));
			close(fd);
			return 1;
		}
	}

	ret = nfc_command(fd, family, command, device, protocols);
	if (ret) {
		fprintf(stderr, "NFC command failed: %s\n", strerror(-ret));
		close(fd);
		return 1;
	}

	if (seconds) {
		struct timespec delay = {
			.tv_sec = seconds,
		};

		printf("Polling device %u with protocol mask %#x for %lu seconds\n",
		       device, protocols, seconds);
		while (nanosleep(&delay, &delay) && errno == EINTR)
			;
		ret = nfc_command(fd, family, NFC_CMD_STOP_POLL, device, 0);
		if (ret) {
			fprintf(stderr, "Cannot stop NFC polling: %s\n", strerror(-ret));
			close(fd);
			return 1;
		}
		printf("Polling stopped cleanly\n");
	}

	close(fd);
	return 0;
}
