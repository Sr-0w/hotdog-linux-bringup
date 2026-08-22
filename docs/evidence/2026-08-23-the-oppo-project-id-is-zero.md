# The OnePlus project id was never set — found, and fixed

Date: 2026-08-23

The board was never identified to the sensor DSP. `oppo_project` read zero in
every coredump on file. It now reads `0x4d59` = 19801, verified in memory.
This did **not** make the sensors register, so it is not the whole story, but
it was a real defect and it is repaired.

## What the firmware wants

`sns_registry_parser.c` in the SLPI image carries three hardcoded OnePlus
paths:

```
/proc/oppoVersion/modemType
/proc/oppoVersion/pcbVersion
/proc/oppoVersion/prjName
```

The `prjName` read sits at `0xb21a98f0` and is straightforward once the log
strings are resolved:

| address | string |
| --- | --- |
| `0xb222546c` | `hw 1 project read len=%d` |
| `0xb2225485` | `hw 2 project version=%s` |
| `0xb222549d` | `oppo_project=%d op_project=%d` |

The sequence is `fopen(path, "r")`, allocate 8 bytes, `fread` up to 8, reject
if the length is `0` or `> 7`, NUL-terminate, parse with `%d`
(`0xb220ab8d`), and store the result at **`0xb28d8f10`**.

That address matters: it sits immediately below the platform-table pointer at
`0xb28d8f14` whose entry 3 supplies `als_type`. The project id and the
per-sensor hardware table are neighbours in the same structure.

## It is zero, always

Read out of every 32-bit SLPI coredump on file, using `PA = VA - 0x1A600000`:

```
coredump                              prjId(8f10)   table(8f14)
01-slpi-early-devcoredump.elf         0x00000000    0xe65f2648
03-slpi-devcoredump.elf               0x00000000    0xe65f2648
17-slpi-devcoredump.elf               0x00000000    0xe65f2648
01-slpi-als-only.elf                  0x00000000    0xe65f2648
05-slpi-clean-registry.elf            0x00000000    0xe65f2648
01-slpi-nosar.elf                     0x00000000    0xe65f2648
01-slpi-curated-alsps.elf             0x00000000    0xe65f2648
```

`oppo_project` is `0` in all of them. The board is never identified.

## And the request never leaves the DSP

`hexagonrpcd` maps by directory prefix and already knows `/oppoVersion/`,
`/project_info/` and `/socinfo/` — there is no filename whitelist, and
`/usr/share/qcom/oppoVersion/modemType` has been served since 19 August. Yet:

```
grep -c oppoVersion /root/hexagonrpcd.log  ->  0
```

Zero requests, ever. The guard immediately before the `fopen` (`0xb21a98ec`)
skips it. So this is not a missing file we can simply supply — the firmware
decides not to ask.

`prjName` was nevertheless written as `19801` (5 bytes, inside the 1–7 byte
window the parser enforces), taken from the `project_info/project_name` value
already served. Rebooting with it present changed nothing, consistent with
the request never being made:

```
accel / gyro / mag / proximity / ambient_light / wise_light / rgb / cct   no SUID
sars   7335663959f5698867456bc70a6c70ca
```

## What the parser does read

The entry point is `/vendor/etc/sensors/sns_reg_config`, which `hexagonrpcd`
maps to `<root>/sensors/sns_reg.conf`. It is a `key=value` file split on
`\n` and `=`, and the DSP does open it every boot. It names the project
source as a path:

```
file=project=/sys/project_info/project_name
```

and the log confirms that read happens (`openat(..., /sys/project_info/project_name) -> 3`).

**The served file is byte-identical to the stock OnePlus one**, taken from
the OxygenOS 10.0.13 vendor partition at
`build/stock-super-oos10.0.13/mnt-vendor/etc/sensors/sns_reg_config`,
including the two trailing `property=` lines. So the configuration is not the
gap, and "our sns_reg.conf is a generic Qualcomm template" — which is what it
looks like at first glance — is wrong. Checked against downstream before
acting on it.

## A measurement caveat worth recording

File access times are **not** a reliable probe here. The root filesystem is
mounted `relatime`, so an atime is only refreshed when it is older than the
file's mtime or more than 24 hours stale. A file the DSP genuinely read this
boot can therefore still show an atime from the previous boot — which is
exactly what `project_info/project_name` did. The `hexagonrpcd` log is the
authoritative record of what the DSP asked for.

Separately, `hexagonrpcd` reads the whole registry directory in one sweep at
startup — all 441 files within two seconds — so atimes cannot distinguish
which groups a driver actually consulted either.

## The guard, resolved

`0xb216ede0` is `strncmp`. The call site assembles its arguments in the
packet that performs the call, so the real test is:

```
r2 = strlen(value)                                   ; value parsed from sns_reg_config
strncmp("/proc/oppoVersion/prjName", value, r2)
if (result != 0) skip the read
```

The firmware reads `prjName` **only if some entry in `sns_reg_config` has
that exact path as its value**. Ours names the project source as
`/sys/project_info/project_name`, so the comparison fails every time and the
read is skipped. That is why supplying the file alone did nothing: the
request was never made.

`pcbVersion` is different — its `fopen` at `0xb21a99e0` is unconditional
within the same per-entry block, which is why it is attempted once per entry.

## The fix

Two lines appended to `sensors/sns_reg.conf`, which add entries whose values
are the paths the firmware compares against, leaving every existing entry
untouched:

```
file=oppo_project=/proc/oppoVersion/prjName
file=oppo_pcb=/proc/oppoVersion/pcbVersion
```

and the two files themselves, served under `oppoVersion/` where hexagonrpcd
already maps the prefix. **Both values were measured, not invented** — the
bootloader passes them on the kernel command line:

```
androidboot.prjname=19801
androidboot.hw_version=14
androidboot.rf_version=4
androidboot.prj_version=19801
```

so `prjName` is `19801` and `pcbVersion` is `14`. Both sit inside the 1–7
byte window the parser enforces. The device tree agrees:
`/proc/device-tree/model` reads `SM8150 MTP 19801 EVT PVT DVT`.

## Verified in memory

`hexagonrpcd` went from zero `oppoVersion` requests to four successful reads
and zero errors, and a fresh coredump shows the parsed value:

```
                             oppo_project   table        handle
before (20 August)           0x00000000     0xe65f2648   0x00001030
after  (prjName+pcbVersion)  0x00004d59     0xe65f2648   0x00001030
```

`0x4d59` = 19801. The sensor DSP now knows which board it is running on, for
the first time.

## What it did not fix

Nothing changed in the census:

```
accel / gyro / mag / proximity / ambient_light / wise_light / rgb / cct   no SUID
sars   7335663959f5698867456bc70a6c70ca
```

So the project id is necessary but not sufficient. It is worth keeping
regardless — it is a genuine mismatch between what this firmware expects and
what the port supplies, and any further hardware-selection logic that reads
`oppo_project` now gets the right answer instead of zero.

The registry parser does re-run on every boot, rewriting 218 of the 441
registry files, so changes here do take effect without any cache-busting.

## Operational note

Crashing the SLPI to take a coredump leaves it `offline` and it will not
restart in place — same wedge as a manual `stop`. Recovery is a reboot.
Enable `coredump` (`echo inline > .../remoteproc0/coredump`) *before*
triggering the crash, or the crash costs a reboot and produces nothing.
