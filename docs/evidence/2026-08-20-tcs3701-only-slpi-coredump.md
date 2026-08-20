# TCS3701-only SLPI coredump

Date: 2026-08-20

## Purpose

This test isolates the OnePlus ALS/proximity family from the other physical
SSC clients to determine whether another sensor consumes the I2C resource
before TCS3701 can open it.

The active registry retained TCS3701 and the framework files. The exact
LSM6DSM, MMC5603x and SX9324 registry families were moved to a temporary
directory, reducing the active registry from 133 to 80 files. The phone was
fully rebooted before the capture.

## Identity and capture

The isolated boot had boot ID:

```
e8c79361-bdb8-4db5-b54a-8856aa399aa5
```

The live SLPI devcoredump was captured after queries for `ambient_light`,
`proximity`, `rgb`, `accel`, `gyro`, `mag` and `sars` all returned no SUID.
Only SLPI was crashed, with remoteproc coredumps explicitly enabled.

```
file    logs/2026-08-20-sensors-als-only-coredump/01-slpi-als-only.elf
size    20885487 bytes
sha256  e79465ef1b323a1be6d3d7827df3d0056529b6864661012bf7fb96b6ab9da452
```

The devcoredump was released after the local copy and hash were verified.

## Decoded TCS3701 state

The 32-bit com-port configuration signature
`(bus_type=0, slave=0x46, reg_addr_type=0, min=400, max=400, instance=3)`
occurs exactly three times in this dump, at file offsets `0x13883e3`,
`0x1388753` and `0x1388ac3`. These map to physical addresses `0x9869d3f4`,
`0x9869d764` and `0x9869dad4` in the final ELF LOAD segment.

The same three signatures occur at the same offsets in both earlier curated
captures. They represent the ALS, proximity and CCT logical instances. Thus
registry decoding completed and isolation did not remove or corrupt the
TCS3701 platform configuration.

## I2C evidence

The trusted I2C format-string relocation is `0x185c5000`. The entire I2C ULog
contains only:

```
qdi root obj = 0xb001b1d0
qdi_handle = 0x00001038
qdi root waiting for callback
```

`I2C_error` is empty. There is no GPI transaction, transfer descriptor,
`i2c_open()` success or physical bus activity. By contrast, the curated
capture in which SX9324 was operational contains a populated transfer trace.

This proves that TCS3701 fails before its first physical I2C transaction even
when the other physical sensor families are absent. It rules out simple
first-client resource exhaustion and leaves the shared
`i2c_setup_lpi_resource()` / root-PD QDI setup boundary as the earliest named
failure point. It does not identify which root-PD operation returns the
error.

## Restoration

All 53 isolated files were moved back to the active registry, restoring the
count to 133, and the temporary directory was removed. After a full reboot:

```
boot_id  96d2ff3b-c2cf-426c-bce5-8dd8d79fe77a
SLPI     running
SAR SUID 7335663959f5698867456bc70a6c70ca
```

The phone therefore ended the experiment in its normal curated sensor state.
