# Mainline 6.16 battery and charger preflight

Date: 2026-08-04

Device target: OnePlus 7T Pro (`hotdog`), tested-model baseline HD1913

Kernel target: `6.16.0-sm8150`

Result: reproducible `r10` candidate built and statically validated; hardware
validation is pending. This record does not claim working battery reporting or
charging.

## Scope

The accepted `r6` direct-boot image exposes no power-supply class device. The
`r10` candidate adds the handset battery description, enables the PM8150B Gen4
fuel gauge and SMB5 charger, and corrects generation-specific programming in
the existing `qcom_smbx` driver. It retains the validated display, UFS, USB,
touchscreen, GPU, key, initramfs, rootfs, and Android boot-image contracts.

The candidate has not been written to the phone. The target was not visible in
fastboot, USB gadget, Qualcomm EDL, or SSH state when this preflight was
published.

## Battery limits

The source-built DTB describes the downstream HD191x profile with deliberately
conservative initial charging limits:

| Property | Value |
|---|---:|
| Design capacity | 4,085,000 uAh |
| Design voltage range | 3,300,000-4,420,000 uV |
| Initial constant-charge current limit | 1,500,000 uA |
| Initial constant-charge voltage limit | 4,400,000 uV |
| Termination current | 310,000 uA |
| Initial USB input-current limit during probe | 500,000 uA |

The 4.40 V charger limit is intentionally below the 4.42 V battery design
maximum. USB SDP starts at 500 mA. CDP and DCP detection may raise the input
limit to at most 1.5 A for this profile.

## Driver safeguards

Patch `0020-power-supply-qcom-smbx-fix-charge-parameters.patch` makes the
following preflight invariants explicit:

- SMB5 uses a 3.60-4.79 V float-voltage range in 10 mV steps and 50 mA steps
  for fast-charge and USB input current;
- SMB2 retains its separate 7.5 mV and 25 mA selector conversions;
- requested voltage and current limits are range checked and rounded down;
- charging is disabled before charger initialization and is enabled only after
  the battery limits, 500 mA input limit, interrupts, wake IRQ, and AICL are
  configured successfully;
- the previous hard-coded 1.95 A fast-charge write and both early charging
  enable commands are removed;
- the battery-overvoltage helper checks the value read from hardware;
- the watchdog-pet write uses the PM8150B charger base, targeting the MISC
  register at charger base plus `0x643` rather than an unrelated absolute SPMI
  address.

The build validator rejects missing limits, changed ordering, either early
enable command, the old conversion expressions, a bare watchdog-pet address,
or DT values outside this contract.

## Reproducible artifacts

One strict build used the normal cache and a second strict build used
`pmbootstrap --no-ccache`. The APKs and their complete extracted trees are
byte-for-byte identical.

| Artifact | Size | SHA256 |
|---|---:|---|
| `linux-oneplus-hotdog-mainline616-6.16.0-r10.apk` | 25,502,529 bytes | `d0bee4414fab8b4a8f4944bfde94653fb399f4d3aeff950c8849ad33cf7f4b75` |
| APK `boot/vmlinuz` | 27,506,696 bytes | `fff37462a4435a7c0de303d3eeeeddf9fe3a570573d789841ef7f9646f78ab6c` |
| APK hotdog DTB | 139,672 bytes | `17e7dabb69f8376cbd294e82b01fcbd797d7bcc05d5f5a31b42939bf86ddad19` |
| Reused pmaports initramfs | 9,478,673 bytes | `347365a8e008a4f1d8b6788a6e933945a1eb940faa6af53b4057ba92d938c0bd` |
| Partition-sized AVB `boot.img` | 100,663,296 bytes | `b693955decab74addf4b14caf28f43bcee5d6fc98bb7f6675d10cde32933d385` |

The AVB footer verifies successfully. The kernel header now derives its image
window from `_end - _text`; the package validator compares that field with the
linked `vmlinux` symbols so built-in driver growth cannot silently overlap a
later Android boot payload.

## Hardware validation gate

The first hardware run must preserve the accepted `r6` image as the fallback,
write only the candidate slot, verify the complete partition readback, and
confirm the fresh kernel identity before accepting any result. The
`collect-mainline616-power.sh` collector then samples both power-supply devices
for ten minutes and fails if battery voltage exceeds 4,420,000 uV.

Acceptance requires all of the following:

- `qcom-battery` and `pm8150b-charger` appear without probe errors;
- capacity, voltage, current, temperature, health, online state, and USB type
  remain plausible throughout the observation;
- the programmed SMB5 selectors correspond to 4.40 V float voltage, 1.50 A
  fast-charge current, and the expected USB input-current limit;
- no battery overvoltage, thermal fault, watchdog fault, repeated IRQ, PMIC
  regmap error, USB regression, storage regression, or kernel warning appears;
- touchscreen, GPU render node, physical input registration, writable rootfs,
  USB networking, and SSH remain available.

Only after this gate passes should the support matrix change from candidate to
working.
