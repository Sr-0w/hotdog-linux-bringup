/* SPDX-License-Identifier: GPL-2.0-only */
#include "hotdog-mbn.h"

#include <ctype.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MBN_MAGIC_LENGTH 16
#define MBN_TYPE_OEM_VERSION 0x01
#define MBN_TYPE_CARRIER 0x03
#define MBN_TYPE_IIN 0x04
#define MBN_TYPE_QC_VERSION 0x05
#define MBN_TYPE_MCC_MNC 0x06
#define MBN_TYPE_CAPABILITY 0x07
#define MBN_TYPE_LONG_IIN 0x09

static uint16_t get_le16(const unsigned char *value)
{
	return (uint16_t)value[0] | (uint16_t)value[1] << 8;
}

static uint32_t get_le32(const unsigned char *value)
{
	return (uint32_t)value[0] | (uint32_t)value[1] << 8 |
	       (uint32_t)value[2] << 16 | (uint32_t)value[3] << 24;
}

static int copy_string(char *target, size_t target_size,
		       const unsigned char *value, size_t length)
{
	if (length >= target_size)
		return -EOVERFLOW;
	memcpy(target, value, length);
	target[length] = '\0';
	return 0;
}

static int parse_iins(struct hotdog_mbn_metadata *metadata,
		      const unsigned char *value, size_t length)
{
	size_t count, index, i;

	if (length < 2)
		return -EINVAL;
	metadata->wildcard_iin = value[0] == 1;
	count = value[1];
	if (count > HOTDOG_MBN_MAX_IINS || length < 2 + count * sizeof(uint32_t))
		return -EOVERFLOW;
	index = 2;
	for (i = 0; i < count; i++, index += sizeof(uint32_t))
		metadata->iins[i] = get_le32(&value[index]);
	metadata->iin_count = count;
	return 0;
}

static int parse_plmns(struct hotdog_mbn_metadata *metadata,
		       const unsigned char *value, size_t length)
{
	size_t count, index, i;

	if (length < 2)
		return -EINVAL;
	metadata->wildcard_plmn = value[0] == 1;
	count = value[1];
	if (count > HOTDOG_MBN_MAX_PLMNS || length < 2 + count * 4)
		return -EOVERFLOW;
	index = 2;
	for (i = 0; i < count; i++, index += 4) {
		metadata->plmns[i].mcc = get_le16(&value[index]);
		metadata->plmns[i].mnc = get_le16(&value[index + 2]);
	}
	metadata->plmn_count = count;
	return 0;
}

static int parse_metadata(const unsigned char *data, size_t length,
			  struct hotdog_mbn_metadata *metadata)
{
	size_t index = MBN_MAGIC_LENGTH;

	if (length < MBN_MAGIC_LENGTH || memcmp(&data[8], "MCFG_TRL", 8))
		return -EINVAL;
	while (index + 3 <= length) {
		const unsigned char type = data[index];
		const size_t value_length = get_le16(&data[index + 1]);
		const unsigned char *value;
		int result = 0;

		index += 3;
		if (!type && value_length > length - index)
			break;
		if (value_length > length - index)
			return -EINVAL;
		value = &data[index];
		switch (type) {
		case MBN_TYPE_CARRIER:
			result = copy_string(metadata->carrier, sizeof(metadata->carrier), value, value_length);
			break;
		case MBN_TYPE_IIN:
			result = parse_iins(metadata, value, value_length);
			break;
		case MBN_TYPE_MCC_MNC:
			result = parse_plmns(metadata, value, value_length);
			break;
		case MBN_TYPE_LONG_IIN:
			result = copy_string(metadata->long_iins, sizeof(metadata->long_iins), value, value_length);
			break;
		case MBN_TYPE_QC_VERSION:
			if (value_length == 4)
				metadata->qc_version = get_le32(value);
			break;
		case MBN_TYPE_OEM_VERSION:
			if (value_length == 4)
				metadata->oem_version = get_le32(value);
			break;
		case MBN_TYPE_CAPABILITY:
			if (value_length == 4)
				metadata->capability = get_le32(value);
			break;
		default:
			break;
		}
		if (result)
			return result;
		index += value_length;
	}
	return 0;
}

int hotdog_mbn_read(const char *path, struct hotdog_mbn_metadata *metadata)
{
	unsigned char *file = NULL;
	unsigned char *payload;
	long file_size;
	uint32_t trailer_offset, metadata_length;
	FILE *stream;
	int result = -EINVAL;

	if (!path || !metadata)
		return -EINVAL;
	memset(metadata, 0, sizeof(*metadata));
	stream = fopen(path, "rb");
	if (!stream)
		return -errno;
	if (fseek(stream, 0, SEEK_END) || (file_size = ftell(stream)) < 8 ||
	    fseek(stream, 0, SEEK_SET))
		goto out;
	file = malloc((size_t)file_size);
	if (!file) {
		result = -ENOMEM;
		goto out;
	}
	if (fread(file, 1, (size_t)file_size, stream) != (size_t)file_size) {
		result = -EIO;
		goto out;
	}
	trailer_offset = get_le32(&file[file_size - 4]);
	if (trailer_offset < 8 || trailer_offset > (uint32_t)file_size)
		goto out;
	payload = &file[file_size - trailer_offset];
	metadata_length = get_le32(payload);
	if (metadata_length < 4 || metadata_length > trailer_offset)
		goto out;
	result = parse_metadata(payload + 4, metadata_length - 4, metadata);
out:
	free(file);
	fclose(stream);
	return result;
}

static bool prefix_matches(const char *value, const char *prefix, size_t length)
{
	return strlen(value) >= length && !strncmp(value, prefix, length);
}

static bool match_long_iin(const char *list, const char *iccid)
{
	const char *start = list;

	while (*start) {
		const char *end;
		size_t length;
		while (*start && !isdigit((unsigned char)*start))
			start++;
		end = start;
		while (isdigit((unsigned char)*end))
			end++;
		length = (size_t)(end - start);
		if (length && prefix_matches(iccid, start, length))
			return true;
		start = end;
	}
	return false;
}

enum hotdog_mbn_match hotdog_mbn_match(const struct hotdog_mbn_metadata *metadata,
				       const char *iccid, uint16_t mcc, uint16_t mnc)
{
	size_t i;
	char iin[7];

	if (!metadata || !iccid)
		return HOTDOG_MBN_MATCH_NONE;
	if (metadata->long_iins[0] && match_long_iin(metadata->long_iins, iccid))
		return HOTDOG_MBN_MATCH_LONG_IIN;
	for (i = 0; i < metadata->iin_count; i++) {
		snprintf(iin, sizeof(iin), "%06u", metadata->iins[i]);
		if (prefix_matches(iccid, iin, 6))
			return HOTDOG_MBN_MATCH_IIN;
	}
	for (i = 0; i < metadata->plmn_count; i++) {
		if (metadata->plmns[i].mcc == mcc && metadata->plmns[i].mnc == mnc)
			return HOTDOG_MBN_MATCH_PLMN;
	}
	if (metadata->wildcard_iin || metadata->wildcard_plmn)
		return HOTDOG_MBN_MATCH_WILDCARD;
	return HOTDOG_MBN_MATCH_NONE;
}

const char *hotdog_mbn_match_name(enum hotdog_mbn_match match)
{
	switch (match) {
	case HOTDOG_MBN_MATCH_LONG_IIN: return "long-iin";
	case HOTDOG_MBN_MATCH_IIN: return "iin";
	case HOTDOG_MBN_MATCH_PLMN: return "plmn";
	case HOTDOG_MBN_MATCH_WILDCARD: return "wildcard";
	case HOTDOG_MBN_MATCH_NONE: return "none";
	}
	return "invalid";
}
