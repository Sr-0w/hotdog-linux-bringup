# The OnePlus project id is never set, and the firmware never asks for it

Date: 2026-08-23

The most promising thread found so far. It is not proven to be the cause, but
it is a concrete, named mechanism that is measurably not working.

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

## Where to pick this up

The guard at `0xb21a98ec`, and what has to be true for the parser to reach
the `prjName`/`pcbVersion` reads at `0xb21a98f0` and `0xb21a99e0`. The
enclosing function is `0xb21a9648`; it walks the `sns_reg_config` entries,
storing name/value pairs into a 12-byte-strided table before reaching this
block. Resolving that guard says whether the project id can be made non-zero
at all without patching firmware.

`pcbVersion` was deliberately **not** invented: its correct value is not
derivable from anything on hand, and a wrong board revision could select the
wrong hardware variant if the read ever does happen.
