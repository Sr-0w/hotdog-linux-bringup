# Linux on the OnePlus 7T Pro (`hotdog`)

Experimental Linux and postmarketOS bring-up for the OnePlus 7T Pro. The
physical test handset is rear-labelled as a European HD1913 with a Qualcomm
Snapdragon 855+ (SM8150-AC), while its recovery and vendor software identify
it as HD1911 and expose the `hotdog` project/codename.

> [!WARNING]
> This is early hardware enablement, not a daily-driver image. An unlocked
> bootloader and a dedicated test device are strongly recommended. A failed
> kernel can leave the phone unreachable until fastboot or recovery returns.

## Goal

Two halves, both required. **Publishable in postmarketOS**: the device must be
submittable as a normal pmaports device, built from a shared, upstreamable
kernel package rather than the device-specific fork used during bring-up,
without laboratory-only deployment steps, with device-tree changes that are
correct descriptions rather than temporary removals, and with an honest support
matrix. **Complete hardware support**: every peripheral the handset has should
work, including USB host mode and the Type-C dock, cameras, sensors and
telephony. Neither half is subordinate to the other. See the
[roadmap](docs/roadmap.md) and the
[pmaports upstreaming plan](docs/pmaports-upstreaming.md).

## Hardware support at a glance

This table describes the tested HD1913 handset, not every `hotdog` variant.
States are deliberately evidence-based: **🟢** means the function has been
validated on the physical handset, **🟡** means some of the path works but the
feature is incomplete or insufficiently tested, **🔴** means a hardware test
demonstrated that the function is currently broken, **⚪** means not yet
hardware-validated (including prepared/offline-only candidates), and **⚫**
means the function is known to be impossible to support within the project's
technical constraints. Prepared code or a successful offline build alone never
counts as hardware support. Rows are sorted by state in the order 🟢, 🟡, 🔴,
⚪, ⚫. No current item is classified ⚫; vendor-dependent features remain ⚪
unless impossibility is actually established. See [docs/status.md](docs/status.md)
for the detailed evidence and limitations.

| Subsystem | Function | State | Current result |
|---|---|:---:|---|
| Boot | Direct boot from OnePlus bootloader | 🟢 | Package-built Linux 6.16, DTB, initramfs and postmarketOS rootfs direct-boot from `boot_b`. |
| Boot | Persistent postmarketOS rootfs / OpenRC / SSH | 🟢 | Read-write rootfs, OpenRC, USB networking and SSH are hardware-validated. |
| Storage | UFS | 🟢 | Direct boot, raw I/O, large buffered writes/imports and application workloads pass with the current reservation fixes. |
| Memory | RAM map and firmware reservations | 🟢 | The complete stock HD1913 reservation union is applied and passed the workload that previously collided with firmware-owned memory. |
| Display | Internal panel 1440x3120 at 60 Hz | 🟢 | Native DPU/DSI/DSC KMS scanout is stable in graphical userspace. |
| GPU | Adreno 640 / GMU / Turnip | 🟢 | Vulkan workloads, `kmscube`, Weston and Plasma Mobile use accelerated rendering without observed GPU/GMU/IOMMU faults. |
| Input | S6SY761 touchscreen | 🟢 | Touch, drag, pressure, multitouch and graphical orientation are hardware-validated. |
| Input | Power key | 🟢 | PM8150 PON power-key input is present and physical power-button interaction has been observed on hardware. |
| Input | Volume Down | 🟢 | The original RESIN mapping was invalidated; the corrected PM8150 GPIO7 mapping is physically tested and functional. |
| Input | Volume Up | 🟢 | PM8150 GPIO6 / `KEY_VOLUMEUP` is physically tested and functional. |
| USB | USB gadget / NCM networking | 🟢 | Stable host ping and SSH at `172.16.42.1` through the translated DWC3 SMMU path. |
| USB-C | Type-C dual role and USB-PD detection | 🟢 | Type-C partner/PD state is exposed and device/sink negotiation works. |
| USB-C | Host mode through powered dock | 🟢 | xHCI, a hub and attached devices enumerate while the handset remains a power sink. |
| USB-C | USB 3 SuperSpeed | 🟢 | Dock hub and RTL8153 enumerate at 5 Gbit/s. |
| USB-C | USB mass storage | 🟢 | A SanDisk device enumerates, mounts and reads through the dock. |
| DisplayPort | External video at 2560x1440@60 | 🟢 | Plasma reaches the external monitor with correct image while the internal panel remains active. |
| Audio | Internal stereo speakers | 🟢 | Both TFA9874 speaker channels are independently hardware-validated and work through the packaged UCM/PulseAudio path. |
| Audio | Handset microphone | 🟢 | AMIC4 with MIC BIAS1 is acoustically validated from the packaged profile and confirmed by listening. |
| Wi-Fi | WCN3990 association and IPv4 connectivity | 🟢 | Both bands scan, NetworkManager associates and basic external IPv4 reachability is validated. |
| Modem | MPSS remote processor / QRTR services | 🟢 | MPSS reaches `running`; RMTFS, QRTR, PD mapper and related services are present. |
| Power | Fuel gauge / battery level / temperature / current / capacity | 🟢 | The gauge uses the bq27421 register layout; `ti,bq27411` reports coherent SoC, voltage, temperature, current and 3856/4040 mAh capacity on hardware. |
| Boot | Reboot to bootloader / recovery integration | 🟡 | Bootloader restart reason works from the validated kexec path; direct recovery-mode integration remains incomplete. |
| Display | Internal panel 90 Hz / dynamic 60↔90 selection | 🟡 | 90 Hz and runtime mode switching work, but wake/blank-unblank reliability is not yet acceptable. |
| USB | USB ACM serial | 🟡 | CDC ACM enumerates and `ttyGS0` exists; an interactive serial session remains unvalidated. |
| USB-C | USB Ethernet | 🟡 | RTL8153 enumerates, `r8152` binds and creates `eth0`; link/data were not tested because no Ethernet cable was attached. |
| Wi-Fi | Power management / suspend / stable factory identity | 🟡 | Basic data works; sustained PM/suspend and factory-address handling remain insufficiently tested. |
| Bluetooth | Scan and HID connectivity | 🟡 | Scanning and real HID connections work, but one historical `900e` event plus incomplete repeated/suspend/audio validation keep this partial. |
| Power | SMB5 charging basic limits | 🟡 | 4.40 V float, 1.50 A fast-charge and 500 mA USB input limits are directly verified; termination, low-SoC, thermal and long-duration policy remain open. |
| Storage | UFS ICE | 🔴 | ICE probe fails; the working UFS path currently runs without ICE. |
| DisplayPort | 2560x1440@120 on two-lane HBR2 | 🔴 | Hardware output is persistently corrupt; msm DP currently accepts a mode that exceeds the available link budget. |
| DisplayPort | Audio | 🔴 | Linux-side backend is present, but the ADSP times out starting AFE port `0x6020`. |
| Power | System suspend / s2idle | 🔴 | Freezer passes, but `pm_test=devices` fails on S6SY761 resume; usable system suspend is currently broken. |
| USB-C | Source VBUS for an unpowered peripheral | ⚪ | Not yet hardware-tested. |
| Audio | Earpiece | ⚪ | Not yet brought up/validated. |
| Audio | Headset / other headphone paths and detection | ⚪ | Remaining headset routing/detection paths are not hardware-validated. |
| Audio | Other analogue/digital microphones, EC/NR | ⚪ | Other live pads, digital microphones, echo cancellation and noise-reduction policy remain open. |
| Cellular | WWAN data / calls / SMS / SIM handling | ⚪ | Telephony stack is not yet hardware-validated. |
| GNSS | Location | ⚪ | Not yet hardware-validated. |
| Cameras | Rear main / ultra-wide / telephoto / front | ⚪ | No camera is hardware-operational yet. CAMSS SM8150 and three missing Sony sensor drivers still need implementation; S5K3M5 has an upstream template/driver path only. |
| Sensors | Motion / rotation / proximity | ⚪ | Mainline integration remains to be implemented and hardware-tested. |
| NFC | NFC / secure-element path | ⚪ | Not yet hardware-validated. |
| Haptics | AW8697 | ⚪ | No mainline driver/integration is validated yet. |
| Hall sensors | MXM1120 | ⚪ | Driver/integration work remains. |
| Range sensor | STMVL53L1 laser rangefinder | ⚪ | Driver/integration work remains. |
| Fingerprint | Fingerprint reader | ⚪ | Vendor-dependent path; no mainline hardware support is validated. |
| Fast charging | OnePlus Warp charge | ⚪ | Vendor-dependent path; no mainline hardware support is validated. |

## Current state

The current pmaports-shaped Linux 6.16 system boots directly from the OnePlus
bootloader into a read-write postmarketOS installation with native display,
accelerated Plasma Mobile, UFS, USB networking, Wi-Fi, Bluetooth, touchscreen,
working internal speakers and handset microphone, battery reporting, and a
working powered USB-C dock path including SuperSpeed and DisplayPort video.
The detailed chronological bring-up record, superseded experiments, recovery
work, boot-path diagram, and validated mainline fixes now live in
[docs/bringup-history.md](docs/bringup-history.md).

## Quick start

Clone the repository and bootstrap the host-side workspace:

```bash
git clone https://github.com/Sr-0w/hotdog-linux-bringup.git
cd hotdog-linux-bringup
./scripts/bootstrap-host.sh
```

The complete source bootstrap, reproducible kernel/package build, image
assembly, AVB validation, and hardware-test workflow is documented in
[docs/build-and-test.md](docs/build-and-test.md). Read
[docs/device-safety.md](docs/device-safety.md) before any hardware operation.

## Repository layout

| Path | Purpose |
|---|---|
| `aports/` | Local postmarketOS package snapshots used during bring-up. |
| `docs/` | Public status, architecture, build, safety, and roadmap documentation. |
| `helpers/` | Small device-side diagnostic helpers. |
| `host/` | Host integration files such as udev and Gentoo configuration snippets. |
| `patches/` | Focused experimental kernel and boot patches. |
| `scripts/` | Reproducible build, inspection, test, and rescue tooling. |

The `src/`, `build/`, `images/`, `logs/`, `reports/`, `android-dumps/`,
`rootfs/`, `tools/`, and `pmbootstrap-work/` directories are local workspaces
and are not part of the Git history. Durable conclusions from experiments
belong in `docs/`; raw reports may contain device identifiers or proprietary
runtime data and must remain local.

## Documentation

- [Documentation index](docs/README.md)
- [Support status](docs/status.md)
- [Bring-up history and validation narrative](docs/bringup-history.md)
- [Build and test workflow](docs/build-and-test.md)
- [Mainline bring-up fixes](docs/mainline-bringup.md)
- [Direct mainline boot](docs/direct-boot.md)
- [Boot architecture](docs/boot-flow.md)
- [Host setup](docs/host-setup.md)
- [Device safety](docs/device-safety.md)
- [Artifacts and reproducibility](docs/artifacts.md)
- [Source trees](docs/sources.md)
- [Roadmap](docs/roadmap.md)
- [Hardware enablement roadmap](docs/hardware-roadmap.md)
- [pmaports upstreaming plan](docs/pmaports-upstreaming.md)

## Contributing

Hardware reports, DT reviews, pmaports packaging help, and focused fixes are
welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request.
Reports should identify the exact model, kernel commit, DTB hash, boot method,
and observed result.

## License

The original tooling and documentation in this repository are licensed under
the GNU General Public License version 2. Third-party source snapshots and
derived files retain their respective upstream licenses. See [LICENSE](LICENSE).
