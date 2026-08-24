# Dual-SIM slot 2 and PIN routing - 2026-08-24

## Hardware inventory

The bootloader identifies this HD1913 as dual-SIM with
`simcardnum.doublesim=1`. QMI UIM independently reports two physical slots.
During this test slot 1 was absent and slot 2 contained a USIM.

The initial Plasma display was misleading. It showed one usable card as
unlocked while ModemManager actually reported:

```text
primary-sim-slot: 2
sim-slots.length: 2
unlock-required: --
state-failed-reason: sim-missing
```

QMI had not selected a provisioning application, so PIN state, IMSI and the
normal SIM object were not initialized.

## Provisioning order

postmarketOS already ships `msm-modem-uim-selection`. It finds the first
present USIM and creates a `primary-gw-provisioning` session, but the service
was not enabled on this image. The Hotdog nonfree-firmware package now:

1. depends explicitly on `msm-modem-uim-selection` and ModemManager OpenRC;
2. starts UIM selection in the `boot` runlevel after `rmtfs`;
3. starts ModemManager in `boot`, after UIM selection and before default-runlevel
   NetworkManager can activate it over D-Bus.

After a clean reboot, QMI reported `Primary GW: slot 2, application 1` and
ModemManager correctly exposed two slots, primary slot 2 and `sim-pin` with
three PIN and ten PUK attempts remaining.

Stopping a D-Bus-activated ModemManager instance at runtime froze the phone
before UIM selection ran. That path is quarantined. Modem selection must occur
during boot; do not stop or replace the active modem daemon to select a SIM.

## ModemManager PIN bug

The exact installed ModemManager commit
`d776ea38d29ca472a12323c1d45002ee19a66f57` and current upstream `main`
`306f6256f83a98fadb3f4dd9d84b68c80d4b7b99` both hard-code
`QMI_UIM_SESSION_TYPE_CARD_SLOT_1` for UIM verify, unblock, change and PIN
protection operations. The active SIM object already carries slot number 2.

Entering the correct PIN through Plasma therefore returned QMI protocol error
3, `Internal`. Hardware counters remained PIN 3 and PUK 10, proving that this
was not an incorrect PIN and consumed no attempt.

The local ModemManager override maps the SIM object's slot number to
`CARD_SLOT_1` through `CARD_SLOT_5` for all four PIN operations. Legacy SIM
objects with no explicit slot retain slot 1. The aarch64 package applies the
patch, compiles all 662 targets and produces the final `r1` packages. The
cross-build test pass was 35 of 38; three unrelated generic/base-call/stub
tests abort under qemu-aarch64, so the override records `!check` and keeps this
result explicit rather than presenting a false all-tests pass.

The final ModemManager APK SHA256 is
`3550ace694782becc4760e1dd846089256ecd15a0891e2d163ca5ebce5d49bca`.
The installed `/usr/sbin/ModemManager` SHA256 is
`25cb578e9cf3354b7de14653ab500ab6c911c24d0386ea99ab99554e61d24ef9`.

The firmware also reports both physical slots as active even when one is
empty. The original slot loader selected the last active slot, which made a
card in slot 1 plus an empty slot 2 appear as `PrimarySimSlot=2`. The `r2`
override instead prefers the first active slot with an ICCID, while retaining
the first-active fallback for firmware that does not expose card contents.
The final aarch64 `r2` APK SHA256 is
`ede40f2fec625f14318770866591838c5c436a795a61986cd50faf9723236d11`.

## PIN success exposes a modem firmware crash

With the corrected binary, the same PIN produced no unlock error. The modem
then entered radio bring-up and watchdoged. Ramoops from the following boot
records the first failure:

```text
qcom_q6v5_pas 4080000.remoteproc: watchdog received:
rflm_diag_error.cc:368:RFLM@qsf_hl_seq.c:118
Assertion (rflm_qlnk_ls_retry_cnt < 2) failed
remoteproc remoteproc1: crash detected in modem: type watchdog
```

The modem SSR then reached IPA, WCN3990 also crashed, a GPU hangcheck fired and
the phone rebooted. The next boot again showed slot 2 selected and SIM PIN
required with counters still 3/10. The PIN-routing defect is fixed; this run
then exposed a separate RFLM/QLINK firmware crash.

No further PIN attempt should be made until the radio bring-up failure is
understood. The SIM is not blocked or degraded.

## The packaged modem was from OxygenOS 12

The newly supplied OxygenOS firmware archive made the firmware provenance
testable. `pil-squasher` from upstream commit
`509cf42bdd15bc4b08de3d1e7ba093d3f27464e1` reproduces the public Hotdog
`modem.mbn` byte-for-byte from the OxygenOS 12 EU F.22 `modem.img`:

```text
MPSS.HE.1.0.c10-00093-SM8150_GEN_PACK-1.505508.2.505991.36
size 78921500
SHA256 de2ae2cf307cd8d719bd3b65579240bfeac0ae81ec817a825f2f1fa7bd737ecd
```

The rest of this phone's validated stock control is OxygenOS 10.0.13: DTBO,
persist data and the sensor-compatible SLPI image. The exact OOS10
`NON-HLOS.bin`, SHA256
`7920f87d8544d17efbe93ec9d7365190a43016eb9d286b1361de5fc96ca6a7b9`,
contains an older, different MPSS:

```text
MPSS.HE.1.0.c11.1-00007-SM8150_GEN_PACK-2.320290.2.328393.1
size 75953080
SHA256 559a517c2d4ca5c22d25e0a9b3383bbf7591a632f688b629a19c3e51e3dba9e5
```

Mixing OOS12 MPSS with the OOS10 low-level baseline was a testable firmware
provenance mismatch. The OOS10 image is packaged by the private-source,
hash-gated
`firmware-oneplus-hotdog-modem-oos10-1.0.11.1.7-r0`. No proprietary modem bytes
are committed.

With no SIM inserted, a clean reboot loaded the OOS10 image. QMI DMS reported
the exact OOS10 revision, MPSS and the UIM/NAS/WDS/DMS/Voice services were
running, and a 120-second window produced 24 of 24 healthy samples with zero
modem crash. This proves the image boots and serves QMI; registration with a
SIM remains deliberately deferred.

After a card was inserted in slot 1, the correct PIN reproduced the same
RFLM/QLINK assertion and reboot with the exact OOS10 MPSS. PIN and PUK counters
remained 3/10. The firmware-generation mismatch is therefore disproved as the
root cause of the post-PIN crash.

OxygenOS performs another preparation step that mainline currently omits.
Its `libril-qc-qmi-1.so` initializes the Qualcomm PDC/MCFG machinery and
contains explicit select/activate flows for software MBN configurations.
Read-only PDC enumeration on the failing mainline boot found 25 resident
software configurations, including `Common-Commercial` and
`Proximus_VoLTE`, but every configuration was inactive. `qmicli` implements
activation as `Set Selected Config` followed by `Activate Config`, matching
the high-level OxygenOS sequence.

The PIN is not the direct crash trigger. With ModemManager masked and the SIM
still locked at PIN 3/PUK 10, a direct DMS transition from `shutting-down` to
`online` reproduced the same RFLM/QLINK assertion and reboot. The PIN had only
caused ModemManager to request that transition. Selecting
`Common-Commercial` through stock `qmicli` produced a pending config, but
neither activation nor a reboot made it active before the assertion.

Reverse engineering the OxygenOS `libqmiservices.so` service object and
`libril-qc-qmi-1.so` request builder identified the missing protocol field.
PDC `Get Selected Config` and `Set Selected Config` accept a token in TLV
`0x10` and a separate subscription ID in TLV `0x11`. `Activate Config` uses
TLV `0x12` for its subscription, while `Deactivate Config` uses `0x11`.
OxygenOS sets the subscription-valid field for both software selection and
activation, using subscription 0 for the primary software configuration.
Upstream libqmi lacks all four subscription fields. The local libqmi override
adds them and a bounded `qmicli --pdc-subscription-id=0..2` option so software
MCFG selection, activation, deactivation and readback operate on the same DSDS
subscription. No PIN attempt has been consumed while developing this fix.

The exact aarch64 packages built from libqmi commit
`cff17a676e10d75081516dafa997fe9bc9043c38` are:

```text
libqmi-1.38.0_git20260414-r2.apk
SHA256 9b6d73628f9d55bb263412b7b79e9bbd3a80fcd966747cdfbe838afb2e960ab8
qmi-utils-1.38.0_git20260414-r2.apk
SHA256 be232981e95cd91ad80aeaa40c6de69047eb2b1e6690d4d3457ccad524d81e7a
```

The guarded phone-side test is installed as
`/home/user/test-hotdog-sim-slot2`. It verifies the kernel, ModemManager and
OOS10 firmware hashes, slot 2 provisioning and exact 3/10 counters before it
allows the user to enter one PIN in Plasma. It never reads or submits the PIN,
stops on any retry decrement, and then monitors MPSS and registration for
three minutes. A no-SIM dry run stopped before the PIN gate as designed.

## Packaging incident

The live APK installation mistakenly used `apk add --upgrade`, which also
accepted 62 available edge updates, primarily KDE Frameworks 6.28 to 6.29 and
minor libraries. Kernel, kernel modules, `boot_b` and `dtbo_b` were unchanged.
This was broader than intended and must not be repeated; future local APK
installation must use `--no-network` and explicit package files without
`--upgrade`.
