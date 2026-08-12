# IPA v4.1 memory map, translated for mainline - 2026-08-12

The downstream source for this handset is available at
`src/lineage/android_kernel_oneplus_sm8150`, and
`drivers/platform/msm/ipa/ipa_v3/ipa_utils.c` carries `ipa_4_1_mem_part`, the
authoritative IPA-local memory partition for this generation. That is the part
of the platform data that cannot be guessed, so it is extracted here in full
and translated into the layout mainline expects.

## The partition as downstream states it

Every region, ordered, with its computed end. The map is contiguous from
`ofst_start = 0x280` to `end_ofst = 0x2800`, which is the check that it was
read correctly.

| Offset | Size | End | Region |
|---|---|---|---|
| 0x0080 | 0x0200 | 0x0280 | uc_info |
| 0x0288 | 0x0078 | 0x0300 | v4_flt_hash |
| 0x0308 | 0x0078 | 0x0380 | v4_flt_nhash |
| 0x0388 | 0x0078 | 0x0400 | v6_flt_hash |
| 0x0408 | 0x0078 | 0x0480 | v6_flt_nhash |
| 0x0488 | 0x0078 | 0x0500 | v4_rt_hash |
| 0x0508 | 0x0078 | 0x0580 | v4_rt_nhash |
| 0x0588 | 0x0078 | 0x0600 | v6_rt_hash |
| 0x0608 | 0x0078 | 0x0680 | v6_rt_nhash |
| 0x0688 | 0x0140 | 0x07c8 | modem_hdr |
| 0x07c8 | 0x0000 | 0x07c8 | apps_hdr |
| 0x07d0 | 0x0200 | 0x09d0 | modem_hdr_proc_ctx |
| 0x09d0 | 0x0200 | 0x0bd0 | apps_hdr_proc_ctx |
| 0x0bd8 | 0x0050 | 0x0c28 | pdn_config |
| 0x0c30 | 0x0060 | 0x0c90 | stats_quota_q6 |
| 0x0c90 | 0x0140 | 0x0dd0 | stats_tethering |
| 0x0dd0 | 0x0180 | 0x0f50 | stats_flt_v4 |
| 0x0f50 | 0x0180 | 0x10d0 | stats_flt_v6 |
| 0x10d0 | 0x0180 | 0x1250 | stats_rt_v4 |
| 0x1250 | 0x0180 | 0x13d0 | stats_rt_v6 |
| 0x13d0 | 0x0020 | 0x13f0 | stats_drop |
| 0x13f0 | 0x100c | 0x23fc | modem |
| 0x2400 | 0x0400 | 0x2800 | uc_descriptor_ram |

The apps filter and route regions are all zero-sized at 0x23fc, which is
normal: on this generation the AP keeps its tables in DDR rather than in IPA
local memory, and the `_size_ddr` fields carry their real sizes.

## Translated to mainline

Mainline does not store offsets and sizes separately from the gaps between
them. It records a `canary_count`, the number of 4-byte canary words written
immediately before each region, and derives the rest. Every gap in the table
above is exactly 8 bytes, which is two canaries, except where regions abut.

```c
static const struct ipa_mem ipa_mem_local_data[] = {
	{ .id = IPA_MEM_UC_SHARED,         .offset = 0x0000, .size = 0x0080, .canary_count = 0 },
	{ .id = IPA_MEM_UC_INFO,           .offset = 0x0080, .size = 0x0200, .canary_count = 0 },
	{ .id = IPA_MEM_V4_FILTER_HASHED,  .offset = 0x0288, .size = 0x0078, .canary_count = 2 },
	{ .id = IPA_MEM_V4_FILTER,         .offset = 0x0308, .size = 0x0078, .canary_count = 2 },
	{ .id = IPA_MEM_V6_FILTER_HASHED,  .offset = 0x0388, .size = 0x0078, .canary_count = 2 },
	{ .id = IPA_MEM_V6_FILTER,         .offset = 0x0408, .size = 0x0078, .canary_count = 2 },
	{ .id = IPA_MEM_V4_ROUTE_HASHED,   .offset = 0x0488, .size = 0x0078, .canary_count = 2 },
	{ .id = IPA_MEM_V4_ROUTE,          .offset = 0x0508, .size = 0x0078, .canary_count = 2 },
	{ .id = IPA_MEM_V6_ROUTE_HASHED,   .offset = 0x0588, .size = 0x0078, .canary_count = 2 },
	{ .id = IPA_MEM_V6_ROUTE,          .offset = 0x0608, .size = 0x0078, .canary_count = 2 },
	{ .id = IPA_MEM_MODEM_HEADER,      .offset = 0x0688, .size = 0x0140, .canary_count = 2 },
	{ .id = IPA_MEM_AP_HEADER,         .offset = 0x07c8, .size = 0x0000, .canary_count = 0 },
	{ .id = IPA_MEM_MODEM_PROC_CTX,    .offset = 0x07d0, .size = 0x0200, .canary_count = 2 },
	{ .id = IPA_MEM_AP_PROC_CTX,       .offset = 0x09d0, .size = 0x0200, .canary_count = 0 },
	{ .id = IPA_MEM_PDN_CONFIG,        .offset = 0x0bd8, .size = 0x0050, .canary_count = 2 },
	{ .id = IPA_MEM_STATS_QUOTA_MODEM, .offset = 0x0c30, .size = 0x0060, .canary_count = 2 },
	{ .id = IPA_MEM_STATS_TETHERING,   .offset = 0x0c90, .size = 0x0140, .canary_count = 0 },
	{ .id = IPA_MEM_STATS_V4_FILTER,   .offset = 0x0dd0, .size = 0x0180, .canary_count = 0 },
	{ .id = IPA_MEM_STATS_V6_FILTER,   .offset = 0x0f50, .size = 0x0180, .canary_count = 0 },
	{ .id = IPA_MEM_STATS_V4_ROUTE,    .offset = 0x10d0, .size = 0x0180, .canary_count = 0 },
	{ .id = IPA_MEM_STATS_V6_ROUTE,    .offset = 0x1250, .size = 0x0180, .canary_count = 0 },
	{ .id = IPA_MEM_STATS_DROP,        .offset = 0x13d0, .size = 0x0020, .canary_count = 0 },
	{ .id = IPA_MEM_MODEM,             .offset = 0x13f0, .size = 0x100c, .canary_count = 0 },
	{ .id = IPA_MEM_UC_EVENT_RING,     .offset = 0x2400, .size = 0x0400, .canary_count = 1 },
};
```

The last entry is the one place the gap is not 8 bytes: `modem` ends at
0x23fc and the uC descriptor ram begins at 0x2400, so a single canary sits
between them.

## Still to extract

The same file holds the other two tables this needs, both indexed by hardware
version so the v4.1 rows are directly readable:

- `ipa3_ep_mapping` at line 712, which becomes mainline's
  `ipa_gsi_endpoint_data`: channel and endpoint numbering, TLV counts, TRE and
  event ring depths, and per-endpoint configuration.
- `ipa3_rsrc_src_grp_config` at line 271 and `ipa3_rsrc_dst_grp_config` at
  line 450, which become `ipa_resource_data`.

Interconnect bandwidths and the core clock rate come from the stock device
tree rather than from the driver, and the register split has to be translated
from downstream's single `ipa-base` into mainline's `ipa-reg`, `ipa-shared`
and `gsi`.
