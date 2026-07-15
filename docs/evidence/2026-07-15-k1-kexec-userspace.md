# K1 mainline userspace evidence (2026-07-15)

This run validated the historical K1 Linux 6.17 payload as a complete kernel
and postmarketOS userspace combination. It also separated that result from the
still-failing direct boot path.

## Validated kexec boot

R6 Linux 4.14 booted from slot B and provided the controlled kexec bridge. The
bridge reported the APSS watchdog disabled before handoff. The K1 Image was
modified only to clear the same watchdog enable register in `primary_entry`.

| Item | Value |
|---|---|
| Kernel commit | `379d8fe35c7ca685a650bd82fd023af0ea3f0de0` |
| Runtime identity | `6.17.0-sm8150-g379d8fe35c7c-dirty` |
| Kernel Image SHA256 | `d0eb811216e5e61c682ea5e0597d393151803cfa5e8af0f09d35b0fc70b124c3` |
| DTB SHA256 | `cf63ae7f686bc76b912520f54e14c589b4c23c833069e45ba9097157a0665440` |
| Initramfs SHA256 | `b7e939614b7cb34ecdd8639613d76b8adba39b069b6591e35c39bc4c57a37622` |
| Mainline boot ID | `0d710588-58c8-4d59-96ba-04ec8ef05246` |

SSH became reachable at `172.16.42.1`. The system remained stable for the
observation window and exposed all eight CPUs, Samsung UFS storage, the nested
postmarketOS root filesystem, USB NCM, USB ACM, and OpenSSH.

The same run also recorded the current hardware gaps:

- Apps SMMU registration times out with `-ETIMEDOUT`.
- No DRM framebuffer or connector is registered.
- Touch input is absent.
- The temporary device tree exposes only the reduced bring-up memory map.
- Wi-Fi, Bluetooth, audio, modem, cameras, and charging remain unvalidated.

The validated launch path is `scripts/test-mainline-via-kexec.sh`. Its fallback
watchdog helper is built reproducibly by
`scripts/build-hotdog-apss-wdt-control.sh` from the tracked helper source.

## Direct-boot follow-up

A direct candidate then used the same K1 commit and postmarketOS payload with
the already validated temporary direct-boot workarounds:

- stock-compatible non-EFI arm64 Image entry layout;
- forced single-CPU bring-up;
- `CONFIG_RAID6_PQ_BENCHMARK=n`;
- early APSS watchdog disable;
- D7 UFS/GDSC bridge DTBO.

| Item | Value |
|---|---|
| Kernel Image SHA256 | `ddc716c5b8be880bca52d46d2074a5b0ea104875b9a8aa040528144f422e8483` |
| AVB boot image SHA256 | `38c103f9cc03cc7f0f90033cf29b658e42d73486e0875f24f6dd815ecd7d7ffe` |
| Observation window | 480 seconds |
| Result | Fixed OnePlus logo; no USB identity and no SSH |

This proves that bypassing the RAID6 benchmark is necessary but not sufficient
for a complete direct boot. The remaining failure is specific to the direct
firmware-to-kernel handoff or a later direct-only initialization dependency;
the complete K1 kernel and userspace are viable after the downstream bridge.

## Next diagnostic

The prepared follow-up writes a persistent breadcrumb before and after every
initcall, writes the downstream OnePlus fastboot restart reason to IMEM, and
arms the APSS watchdog. If an initcall stalls, the next warm reset should retain
the last stage and request fastboot instead of leaving the handset indefinitely
on the logo. The fastboot request and breadcrumb recovery remain hardware
tests; they are not presented as working until observed on the device.
