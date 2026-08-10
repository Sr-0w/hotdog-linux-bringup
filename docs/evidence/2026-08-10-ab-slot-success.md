# Automatic A/B boot-success marking

Date: 2026-08-10

## Result

The OnePlus bootloader decrements the active slot retry counter on every boot
until Linux marks that slot successful. The Alpha image did not include
`qbootctl`, so repeated otherwise successful direct-mainline boots eventually
left slot B with this state:

```text
current-slot: b
slot-successful:b: no
slot-unbootable:b: yes
slot-retry-count:b: 0
```

At that point the bootloader fell back to the invalid slot-A image and showed
the OnePlus "current image ... destroyed" screen. This was retry exhaustion,
not image corruption and not Qualcomm EDL mode.

`fastboot set_active b` restored seven attempts. After booting the verified
Alpha-rootfs image, `qbootctl 0.2.2-r1` marked B successful and reported:

```text
Current slot: _b
SLOT _a:
        Active      : 0
        Successful  : 0
        Bootable    : 1
SLOT _b:
        Active      : 1
        Successful  : 1
        Bootable    : 1
```

Device package `3-r18` now depends on the standard pmaports
`soc-qcom-qbootctl` integration. Its OpenRC subpackage enables the official
`qbootctl` service in the default runlevel; the service executes `qbootctl -m`
so every userspace boot marks its current Android A/B slot successful
automatically. The package passed a strict aarch64 pmbootstrap build.
The resulting `device-oneplus-hotdog-3-r18.apk` has SHA-256
`1feadb3a7c532f956c6191f289462994368f860d2f3036ff9332a8402755cd79`.

## Recovery evidence

The known-good slot-B image is the Alpha-rootfs r109 image with SHA-256
`6e44d40bfed5f93f991ac6fa0c1c114c8f739d48052fbc39b74b25ce39be5df4`.
It embeds boot/root UUIDs `0ab55a28-43d8-4cb8-b181-165a5d3fb56d` and
`7349e861-b909-462f-b866-c597d6a115d6`. A byte-for-byte readback of the
96 MiB `boot_b` partition produced the same digest before reboot.
