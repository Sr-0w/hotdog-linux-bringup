# OxygenOS hardware reference - 2026-08-05

## Scope

OxygenOS is the device-specific reference for every remaining Hotdog hardware
subsystem. This is broader than copying audio firmware: the stock device trees,
GPL kernel sources, module metadata, firmware, calibration data, Android
configuration and HAL behavior are all useful inputs to the mainline port.

The reference used here is the European OnePlus 7T Pro OxygenOS 10.0.13 full
package for HD1913. The original archive has SHA256:

```text
91f2e36e8f4d2699e095f02a7e17cede6eba5a72e3b884f75bac0427087c0928
```

The decrypted `super` image was unpacked into its logical partitions and
`vendor_a` plus `odm_a` were mounted read-only. Proprietary payloads and the
generated full inventory remain outside Git. The checked-in
[`inventory-oxygenos-assets.py`](../../scripts/inventory-oxygenos-assets.py)
records only paths, sizes, hashes and module metadata.

## Reuse policy

| Stock input | Mainline use |
| --- | --- |
| Firmware and calibration payload | Package the exact payload when the Linux driver consumes the same ABI and redistribution is permitted. Otherwise provide a user-side extraction recipe. |
| GPL kernel module or published OnePlus kernel source | Port the required behavior to the current kernel API and submit it as source. A 4.14 module cannot be loaded into Linux 6.16. |
| Stock DT/DTBO | Recover addresses, GPIOs, regulators, clocks, memory ownership and bus topology, then express them with upstream bindings. |
| Android XML, ACDB and mixer policy | Use as routing and calibration evidence. Translate it into ALSA UCM, PipeWire/WirePlumber or a kernel interface instead of running Android policy verbatim. |
| Android HAL or Bionic library | Use as behavioral reference only unless a maintained compatibility layer exists. It is not a replacement for a Linux kernel driver. |

No stock kernel module, writable partition or hardware register is modified by
the inventory process.

## Partition firmware

The decrypted package includes the firmware-bearing images below. Their hashes
make future extractions and regional-package comparisons reproducible.

| Image | Bytes | SHA256 | Mainline role |
| --- | ---: | --- | --- |
| `NON-HLOS.bin` | 170,364,928 | `7920f87d8544d17efbe93ec9d7365190a43016eb9d286b1361de5fc96ca6a7b9` | Modem, WLAN and related Qualcomm peripheral firmware source |
| `BTFM.bin` | 847,872 | `6c8218bd5b635c1597700c3ce626693097a783aac74fb5f9ab7390baa2a8de4e` | WCN3990 Bluetooth firmware source |
| `dspso.bin` | 67,108,864 | `72a39b2b444b95aa2bb2787c82e6cb3d8250d5e81c67cbc8b8da30b00f30c5e0` | ADSP/CDSP payload source |
| `qupv3fw.elf` | 70,730 | recorded by inventory | QUPv3 serial-engine firmware |
| `fw_ufs1.bin`, `fw_ufs2.bin` | 516,096 each | recorded by inventory | UFS device firmware reference; not flashed during Linux bring-up |

GPU, modem, ADSP, CDSP, Venus, WLAN and Bluetooth payloads already have
separate postmarketOS firmware subpackages. Their runtime status remains tracked
in the main support matrix. The stock audit additionally found camera ICP, IPA,
touchscreen, AW8697 haptic and TFA98xx payloads that are not all packaged yet.

## Stock kernel modules

`vendor_a/lib/modules` contains 32 Android 4.14 modules. Module metadata proves
the useful source boundary while also preventing accidental attempts to load
them into the mainline kernel:

- 23 Qualcomm/NXP audio modules, including `audio_machine_msmnile.ko`,
  `audio_wcd934x.ko`, `audio_tfa9894.ko`, SoundWire, APR and Q6 support;
- `qca_cld3_wlan.ko`, `wil6210.ko` and `msm_11ad_proxy.ko`;
- three media transport/demux modules;
- `rmnet_perf.ko`, `rmnet_shs.ko` and `rdbg.ko`.

The TFA module identifies itself as an ASoC TFA98xx driver, is GPL licensed,
targets `4.14.117-perf+`, and aliases the two Hotdog I2C devices. The matching
published downstream source is therefore a valid porting input; the `.ko`
itself is not reusable on Linux 6.16.

## Internal audio

The stock HD1913 DT and live read-only I2C identification agree on two NXP
TFA9874 smart amplifiers:

| Function | I2C address | Reset GPIO | Stock profile |
| --- | ---: | ---: | --- |
| Top speaker / earpiece | `0x34` | `37` | `receiver`, `speaker`, `calibrate.cal` |
| Bottom speaker | `0x35` | `100` | `speaker`, `calibrate.cal` |

The stock container is `vendor/firmware/tfa98xx.cnt`, 3,591 bytes, SHA256
`6326d29289dc17694313e3969e90f311cb71f08321702ac962a46df7eb2cd1f3`.
Its CRC is valid, it declares two devices and three profiles, and it contains
device-specific TDM slots, current limits, receiver tuning and three embedded
calibration messages. The speaker ACDB has SHA256
`4315910bfc831d249e9f3e023f624326c620892559649b333c79ad7755e0ba4a`.

TFA9874 has no internal audio DSP. The stock GPL driver marks it as a ProBus
device and sends container messages to the Qualcomm ADSP through quaternary
MI2S RX/TX. The exact stock AFE identifiers are:

```text
RX module  0x1000b911    TX module  0x1000b912
TX enable  0x1000b920    RX config  0x1000b921
RX result  0x1000b922    RX bypass  0x1000b923
```

This establishes the implementation boundary for mainline: a TFA9874 ASoC
codec, the MI2S4 playback/feedback links, and a small Q6AFE interface for the
stock ADSP module. Initial hardware probing must keep `PWDN=1`, `AMPE=0` and
`DCA=0`. Audible speaker testing is gated on successful protection-profile
loading and conservative gain; writing an arbitrary profile can damage the
speakers.

## Reproduction

After mounting extracted partitions read-only, create a local JSON inventory:

```sh
./scripts/inventory-oxygenos-assets.py \
  --root vendor=/mnt/oxygenos/vendor \
  --root odm=/mnt/oxygenos/odm \
  --images /path/to/decrypted-images \
  > oxygenos-hardware-assets.json
```

Inspect the TFA container without touching hardware:

```sh
./scripts/inspect-tfa-container.py --details \
  --field-header /path/to/tfa9874_tfafieldnames.h \
  /mnt/oxygenos/vendor/firmware/tfa98xx.cnt
```

The JSON output and extracted proprietary files must not be committed without a
separate provenance and redistribution review.
