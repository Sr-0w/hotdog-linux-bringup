# SLPI 00083 ships a different driver set — and that invalidates part of the ALS work

Date: 2026-08-23

## The inventory differs between the two builds

Counting driver source-file strings in each image:

| driver | 00121 (from `modem_b`) | 00083 (OxygenOS 10.0.13) |
| --- | ---: | ---: |
| `sns_tcs3701` | **absent** | **present, 221** |
| `sns_alsps` | present, 59 | **absent** |
| `sns_stk2232` | absent | present, 219 |
| `sns_lsm6dsm` | present, 175 | present, 309 |
| `sns_mmc5603x` | present, 166 | present, 150 |
| `sns_ak0991x` | present, 30 | present, 68 |
| `sns_sx9324` / `sns_sx932x` | present, 86 | present, 88 |

The ALS/proximity driver is **not the same driver** in the two builds. 00121
has the OnePlus `sns_alsps` combo and no `tcs3701`; 00083 has `sns_tcs3701`
and no `alsps`.

## What that invalidates

Every `alsps` configuration change made while investigating the proximity —
the address, `hw_id`, `is_dri`, the `.cct` groups, `rail_on_state` — was
edited against a driver that **does not exist in the running firmware**. That
is why none of them moved anything, and the earlier reading that "the ALS is
`sns_alsps` on this device" is true only of 00121.

The SUIDs said so all along and I misread them: `amsTCS3701ALS___` and
`amsTCS3701PROX__` are the `tcs3701` driver's naming, not `alsps`'s.

## A real defect found while chasing it

The parser regenerates only the `tcs3701_platform.*` groups. The five
sensor-side groups — `tcs3701`, `tcs3701.als`, `tcs3701.als.config`,
`tcs3701.prox`, `tcs3701.prox.config` — are never recreated, because
`tcs3701.json` gates on a `soc_id` list that **excludes 339**:

```
"soc_id": ["291","246","305","321","336","341","360","365"]
```

They existed on this phone only because they were inherited in the registry
backup. On a clean system they would be absent. Adding `"339"` makes the
parser generate all twelve groups, which is now done in
`firmware/sensors/config/tcs3701.json`.

Same class of defect as `devinfo_0.json`, whose gate also excludes this SoC.

It does not fix the proximity — still 0 events with all twelve groups
generated from the config rather than inherited — but the config is now
self-consistent instead of depending on stale files.

## Proximity, retried against the correct driver

Everything below was tried on `sns_tcs3701` — the driver actually in the
running image — rather than on `alsps`. All reverted, none moved it.

| tried | result |
| --- | --- |
| `tcs3701.prox.config` `is_dri` 1 → 0 (polling instead of IRQ 117) | 0 events |
| `soc_id` gate fixed so all twelve groups generate from config | 0 events, gate fix kept |
| `devinfo.ps` / `devinfo.als` repointed from `alsps_platform.*` to `tcs3701_platform.*` | 0 events, reverted |

The `devinfo` inconsistency is real and worth recording: `devinfo.ps` points
at `alsps_platform.prox.fac_cal`, a calibration group belonging to a driver
absent from this firmware. The registry backup carries it from an era when
the phone ran an `alsps` build. Repointing it at the `tcs3701` paths changes
nothing, so it is inert, and it was reverted rather than kept without a
measured benefit.

The driver has a full proximity implementation including a factory
calibration path, with messages such as
`prox factory cal: offset calibration failed, setting: 1`,
`prox factory cal: timeout, more than 100ms`, `first_prox data contaminated`
and `first_prox data saturated`. Reading those at run time would settle it,
but they go to diag, which this port cannot drain.

Its served calibration is `near_threshold` 200, `far_threshold` 150, and all
four offsets zero.
