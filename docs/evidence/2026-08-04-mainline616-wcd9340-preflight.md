# Mainline 6.16 WCD9340 transport preflight

Date: 2026-08-04

Device target: OnePlus 7T Pro (`hotdog`), tested-model baseline HD1913

Kernel target: `6.16.0-sm8150`

Result: reproducible `r13` SLIMbus/WCD9340 transport candidate built and
statically validated; hardware validation is pending. This record does not
claim a working ALSA sound card, speaker, earpiece, microphone, headphone, or
Bluetooth audio path.

## Scope

Revision `r13` adds one isolated layer after the `r12` ADSP candidate:

- enable the SM8150 SLIMbus NGD topology;
- describe the WCD9340 interface and codec devices at manufacturer/product
  address `217:250`;
- use TLMM GPIO 123 for the codec interrupt and GPIO 143 for active-high reset;
- supply the five driver-facing codec rails from PM8150 S4 at 1.8 V;
- retain the upstream 9.6 MHz codec clock, four 1.8 V micbias descriptions,
  WCD9340 GPIO controller, and Qualcomm SoundWire master; and
- deliberately keep `/sound`, the external speaker-amplifier I2C bus, and CDSP
  outside this experiment.

The accepted runtime baseline remains `r6`. The cumulative candidates must be
tested in order: `r10` power, `r11` MPSS/RMTFS, `r12` ADSP, then `r13`
SLIMbus/WCD9340. This preserves failure attribution across hardware domains.

## Hardware contract

The codec interrupt on GPIO 123, reset-n on GPIO 143, and 1.8 V supply class
are present in the tested HD1913 stock device tree. The exact reset and supply
description also matches the upstream SM8150 WCD9340 integration. The common
`sm8150-wcd9340.dtsi` supplies the established SLIMbus, GPIO, interrupt, clock,
micbias, and SoundWire topology rather than reproducing those nodes locally.

The source-built DTB is rejected unless it contains all of the following:

| Property | Required value |
|---|---|
| SLIMbus controller | `/soc@0/slim-ngd@171c0000`, `status = "okay"` |
| Interface device | `slim217,250`, address `<0 0>` |
| Codec device | `slim217,250`, address `<1 0>` |
| Codec reset | TLMM GPIO 143, active high |
| Codec interrupt | TLMM GPIO 123, level high |
| External clock | 9.6 MHz |
| Codec supplies | all five driver supplies reference PM8150 S4 at 1.8 V |
| Micbias descriptions | four rails at 1.8 V |
| GPIO child | `qcom,wcd9340-gpio`, register range `<0x42 0x2>` |
| SoundWire child | `qcom,soundwire-v1.3.0`, register range `<0xc85 0x40>` |
| External speaker I2C | disabled, with no codec at `0x34` |
| Sound-card `compatible` | absent |
| CDSP | disabled |

The package validator also requires the SLIMbus core/regmap/Qualcomm NGD,
WCD9340 MFD/GPIO/codec, and SoundWire core/Qualcomm modules. It resolves every
generated phandle back to the expected provider instead of relying on fixed
numeric phandle allocation.

## Reproducible artifacts

One strict kernel build used the normal cache and a second strict build used
`pmbootstrap --no-ccache`. The APKs, kernels, DTBs, and all seven transport
modules are byte-for-byte identical. Two independent boot-image assemblies
also produced identical raw and AVB images.

| Artifact | Size | SHA256 |
|---|---:|---|
| `linux-oneplus-hotdog-mainline616-6.16.0-r13.apk` | 25,502,739 bytes | `0644c117b1a8e7719b9980fc1781a57f5e6fdf02429847a6b09f24f33ed9a47d` |
| APK `boot/vmlinuz` | 27,506,696 bytes | `a6d9a418f5e632185016f50edc12ed5dc055478e9040b73947d77422c4b1340c` |
| APK hotdog DTB | 141,523 bytes | `92254c10063f091c49ecd32a8080b1712010cbd6a52b1e925327ca6c9b378e95` |
| Reused pmaports initramfs | 9,478,673 bytes | `347365a8e008a4f1d8b6788a6e933945a1eb940faa6af53b4057ba92d938c0bd` |
| Raw header-v2 boot image | 37,138,432 bytes | `cbb6e5f365940dff89ca3ab8fe7e46826d2eb4a59459f55237e080c1347baa64` |
| Partition-sized AVB `boot.img` | 100,663,296 bytes | `8908fb343b2a8477fbb48697a85413fef372d8f3877550d1f2fcfd0709861adc` |

The AVB footer and boot descriptor verify successfully. Unpacking the final
image reproduces the exact `r13` kernel, DTB, validated initramfs, and command
line. No phone command was issued while producing this evidence.

## Hardware validation gate

The first `r13` run must preserve the accepted `r6` fallback, write only the
candidate slot, verify the complete partition readback, and attest the fresh
kernel, DTB, and boot-image hashes before accepting runtime evidence.

The read-only collector `scripts/collect-mainline616-wcd9340.sh` does not load
modules, start services, write sysfs, or change audio state. Its strict gate
requires:

- the ADSP to remain running throughout a 60-second observation;
- the `171c0000` NGD controller and generated NGD child to bind;
- SLIMbus devices `217:250:0:0` and `217:250:1:0` to enumerate;
- the codec device to bind `wcd934x-slim`;
- the WCD9340 codec, GPIO, and Qualcomm SoundWire children to bind;
- no capability timeout, SLIM NACK, logical-address failure, WCD9340 bring-up
  failure, regmap/IRQ/child creation failure, or SoundWire probe failure;
- no ALSA card or external speaker-amplifier device to appear yet; and
- the separately accepted display, UFS, rootfs, USB, touch, GPU, key, power,
  MPSS, and ADSP behavior to remain stable.

Only after this transport gate passes should a later revision construct the
SM8150 machine card and validate internal codec routes. External TFA98xx
speaker amplifiers remain a separate hardware and driver problem and must not
be represented as a different supported codec to force card registration.
