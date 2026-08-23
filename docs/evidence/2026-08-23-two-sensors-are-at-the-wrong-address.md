# Two of the three missing sensors are configured at addresses where nothing is

Date: 2026-08-23

Bus scanning with `sns_ak0991x` — the one failing driver that instantiates,
opens its bus and reports a clean probe — turns the address question into a
measurement. Four addresses probed, each with the noisy absent-chip drivers
removed so the 4 KB `I2C` ring does not wrap and every trace starts at
offset 0.

## The four probes

| bus | address | transfers | errors | reading |
| ---: | ---: | ---: | ---: | --- |
| 1 | `0x0c` (AK0991x) | 6 | **3 NACK** | nothing there |
| 1 | `0x30` (MMC5603) | 2 | none | **a device answers** |
| 3 | `0x46` (`alsps_platform`) | 6 | **3 NACK** | nothing there |
| 3 | `0x39` (TCS3701) | 2 | none | **a device answers** |

Six transfers with three NACKs is a retried absent device. Two transfers with
no error is a device that acknowledged, whose identity register then failed
the AK0991x driver's check, so it stopped without retrying.

## What is actually on this board

- the magnetometer is at **`0x30` on bus instance 1** — the MMC5603, not the
  AK0991x that `ak0991x_0_platform` points at;
- the ALS/proximity chip is at **`0x39` on bus instance 3** — the TCS3701
  address, not the `0x46` that `alsps_platform` points at.

Both served configs aim their driver at an address where nothing exists.

## Why the ALS one matters beyond the address

`sns_tcs3701` is **not in this firmware** — only `sns_alsps` is, and its
part table lists `stk33502`, `tcs3701`, `stk32600`, `mn78911`. The part is
selected by `als_type`, which is read from the platform table at index 3 and
is **zero** because that table is never populated with a board identity. With
`als_type` at zero the driver falls back to its default address, `0x46`, and
finds nothing.

So the ALS chain is: platform table not populated → `als_type` 0 → wrong
part selected → wrong address → NACK. Fixing the address by hand is treating
the symptom, but it is measured and correct, so
`msmnile_alsps.json` now carries `slave_config` 57.

It changes nothing yet, and that is expected: `sns_alsps` blocks on its
`accel` dependency long before it probes. The address only becomes reachable
once the accelerometer publishes.

## What this does not explain

`sns_mmc5603x` never touches the bus even though its chip is present and
answering at exactly the address its config specifies. Same for
`sns_lsm6dsm`. For those two the hardware is now positively ruled out.

## Method

Each probe is one reboot plus one coredump. The technique that makes it
possible is worth restating: **remove the drivers whose chips are absent
before capturing** — their retry storms are what overwrite the ring buffer,
and without that step every trace in this investigation started mid-way and
lost the boot-time probing.
