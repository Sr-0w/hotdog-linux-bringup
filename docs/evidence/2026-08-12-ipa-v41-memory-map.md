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

## Endpoints, resources and QSB limits

The remaining tables are in the same file, indexed by hardware version, so the
v4.1 rows read out directly. Note that `IPA_4_1_APQ` sits next to `IPA_4_1`
throughout and carries identical values; APQ is the Wi-Fi-only variant, so
either row gives the same answer here.

### Endpoints, from `ipa3_ep_mapping`

The trailing struct is `{ ep_num, gsi_chan_num, tlv_count, aos_count, ee }`.

| Client | ep | chan | tlv | aos | EE | group |
|---|---|---|---|---|---|---|
| APPS_CMD_PROD | 5 | 4 | 20 | 24 | AP | UL_DL |
| APPS_LAN_PROD | 8 | 10 | 8 | 16 | AP | UL_DL |
| APPS_WAN_PROD | 2 | 3 | 16 | 32 | AP | UL_DL |
| APPS_LAN_CONS | 10 | 5 | 9 | 9 | AP | UL_DL |
| APPS_WAN_CONS | 11 | 6 | 9 | 9 | AP | UL_DL |
| Q6_CMD_PROD | 4 | 1 | 20 | 24 | Q6 | UL_DL |
| Q6_WAN_PROD | 3 | 0 | 16 | 32 | Q6 | UL_DL |
| Q6_LAN_CONS | 14 | 4 | 9 | 9 | Q6 | UL_DL |
| Q6_WAN_CONS | 13 | 3 | 9 | 9 | Q6 | UL_DL |

`APPS_CMD_PROD` uses `DPS_HPS_SEQ_TYPE_DMA_ONLY`, the producers use the
two-pass no-decompression sequencer, and the consumers carry no sequencer.
There are no UL_NLO or DL_NLO endpoints on this generation; those appear from
v4.5 onwards, so mainline's `IPA_ENDPOINT_MODEM_DL_NLO_TX` has no counterpart
here and must be left out.

### Resource groups

Groups are ordered LWA_DL, UL_DL, unused, UC_RX_Q on the source side, and
LWA_DL, UL/DL/DPL, uC on the destination side. Entries are `{min, max}`.

Source, from `ipa3_rsrc_src_grp_config[IPA_4_1]`:

| Type | LWA_DL | UL_DL | unused | UC_RX_Q |
|---|---|---|---|---|
| PKT_CONTEXTS | 1, 63 | 1, 63 | 0, 0 | 1, 63 |
| DESCRIPTOR_LISTS | 10, 10 | 10, 10 | 0, 0 | 8, 8 |
| DESCRIPTOR_BUFF | 12, 12 | 14, 14 | 0, 0 | 8, 8 |
| HPS_DMARS | 0, 63 | 0, 63 | 0, 63 | 0, 63 |
| ACK_ENTRIES | 14, 14 | 20, 20 | 0, 0 | 14, 14 |

Destination, from `ipa3_rsrc_dst_grp_config[IPA_4_1]`:

| Type | LWA_DL | UL/DL/DPL | uC | fourth |
|---|---|---|---|---|
| DATA_SECTORS | 4, 4 | 4, 4 | 3, 3 | 2, 2 |
| DPS_DMARS | 2, 63 | 1, 63 | 1, 2 | 0, 2 |

### QSB limits

From `ipa3_qmb_outstanding[IPA_4_1]`, as `{reads, writes}`:

| Instance | reads | writes |
|---|---|---|
| DDR | 12 | 8 |
| PCIe | 12 | 4 |

## What is left to assemble

Everything that cannot be guessed is now extracted. Assembling
`ipa_data-v4.1.c` from it needs no further source access. Three things still
have to be decided rather than copied:

- the interconnect entries and their bandwidths. The stock node votes through
  the legacy MSM bus scaling with five performance cases across four paths;
  mainline uses the interconnect framework, so these have to be translated
  into named paths with average and peak figures rather than lifted.
- the core clock rate for the power data.
- the register split. Downstream describes one `ipa-base` at 0x1e00000 for
  0x34000 with `gsi-base` at 0x1e04000 inside it. Mainline wants three ranges
  named `ipa-reg`, `ipa-shared` and `gsi`, so the node has to be rewritten
  against the v4.1 register layout rather than copied.
