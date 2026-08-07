# Mainline 6.16 ADSP remoteproc preflight

Date: 2026-08-04

Device target: OnePlus 7T Pro (`hotdog`), tested-model baseline HD1913

Kernel target: `6.16.0-sm8150`

Result: reproducible `r12` ADSP remoteproc candidate built and statically
validated; hardware validation is pending. This record does not claim a
working ALSA sound card, speaker, earpiece, microphone, headphone path, or
Bluetooth audio path.

## Scope

Revision `r12` adds one isolated dependency for later audio bring-up:

- enable the SM8150 ADSP PAS remote processor;
- select the packaged hotdog `adsp.mbn` firmware;
- retain the existing 30 MiB ADSP reserved-memory region at `0x8be00000`;
- retain the kernel's Qualcomm PAS, sysmon, SMEM GLINK, APR, and QDSP6 support;
  and
- deliberately keep CDSP, SLIMbus, the external speaker-codec bus, and the
  sound-card topology disabled.

The accepted runtime baseline remains `r6`. Revision `r12` is cumulative at
the package level, so the first hardware campaign must validate `r10`, then
`r11`, then `r12` separately. That order prevents a battery, MPSS, or ADSP
result from being attributed to the wrong subsystem.

## Static contract

The source-built DTB is rejected unless it contains all of the following:

| Property | Required value |
|---|---|
| ADSP node | `/soc@0/remoteproc@17300000` |
| `compatible` | `qcom,sm8150-adsp-pas` |
| `status` | `okay` |
| Firmware | `qcom/sm8150/oneplus/hotdog/adsp.mbn` |
| Reserved memory | `/reserved-memory/memory@8be00000` |
| Reserved-memory range | `<0x0 0x8be00000 0x0 0x1e00000>` |
| CDSP | disabled, with no firmware override |
| SLIMbus | disabled |
| External speaker-codec I2C bus | disabled |
| Sound-card `compatible` | absent |

The packaged firmware is 14,459,152 bytes with SHA256
`6fac2ca7c5617e8abf36f2f64de433d7d89ffeea9f51d79d1ee6871de6bc62fd`.
No firmware contents are stored in this repository.

A property-sorted DTS comparison between the reproducible `r11` and `r12`
DTBs contains exactly two semantic changes: the ADSP `firmware-name` is added
and the ADSP status changes from `disabled` to `okay`. No sound, codec, WiFi,
CDSP, storage, display, USB, GPU, touch, key, or power property changes in this
revision.

## Reproducible artifacts

One strict kernel build used the normal cache and a second strict build used
`pmbootstrap --no-ccache`. The APKs and their complete extracted trees are
byte-for-byte identical. Two independent boot-image assemblies also produced
identical raw and AVB images.

| Artifact | Size | SHA256 |
|---|---:|---|
| `linux-oneplus-hotdog-mainline616-6.16.0-r12.apk` | 25,502,535 bytes | `4753bcfd5494a3d97c8c84a78bd57c58360bff55a4cb986c560d86e48fc37ebd` |
| APK `boot/vmlinuz` | 27,506,696 bytes | `c9f8d11c7669c17620c96087524457dde7ffc592dcfa87a44e236b007d7ee852` |
| APK hotdog DTB | 139,720 bytes | `d4dc7528492befbd9683bb144e1a9e14741c226f9a70fc3935f2ef5ef53647da` |
| Reused pmaports initramfs | 9,478,673 bytes | `347365a8e008a4f1d8b6788a6e933945a1eb940faa6af53b4057ba92d938c0bd` |
| Raw header-v2 boot image | 37,138,432 bytes | `c2bd2314d5a56b60b4e036cd8f98b9621f7cea10e09dd4cc455c338994068310` |
| Partition-sized AVB `boot.img` | 100,663,296 bytes | `390c16cefad408322672cc4c4a94a691af1e79dacd6aba2c0869eadc4d8ca80d` |

The AVB footer and boot descriptor verify successfully. Unpacking the final
image reproduces the exact r12 kernel, DTB, validated initramfs, and command
line.

## Hardware validation gate

The first `r12` run must preserve the accepted `r6` fallback, write only the
candidate slot, verify the complete partition readback, and attest the fresh
kernel, DTB, and boot-image hashes before accepting runtime evidence.

The read-only collector `scripts/collect-mainline616-adsp.sh` does not load a
module, start a service, or write remoteproc state. Its strict gate requires:

- the `17300000.remoteproc` platform device to bind;
- the ADSP remote processor to use the exact hotdog firmware and remain
  `running` throughout a 60-second observation;
- an APR or GLINK endpoint to appear;
- no ADSP crash, watchdog, authentication failure, firmware-load failure, or
  timeout;
- CDSP and the complete sound-card topology to remain outside this test; and
- display, UFS, writable rootfs, USB networking, SSH, touch, GPU, keys, power,
  MPSS, and RMTFS to retain their separately accepted behavior.

Only after this isolated gate passes should a later revision enable the LPASS
audio transport and construct a sound-card topology. The handset's external
TFA9894 speaker amplifier must not be represented as a different supported
codec merely to make the card probe.
