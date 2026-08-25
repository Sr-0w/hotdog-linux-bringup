# Linux upstream submission queue

The immutable submission artifacts live under
[`upstream/2026-08-11`](../upstream/2026-08-11) and
[`upstream/2026-08-12`](../upstream/2026-08-12). They use the DCO identity
`Robin Snyders <robin@snyders.xyz>`.

Q6AFE v1, SM8150 download-mode v1/v2, the Qualcomm SMB5 v1/v2/v3 series and its
five-patch SMB2 prerequisite series have been mailed. Their files are
immutable submission artifacts: revise the source branch and regenerate a
complete versioned series instead of editing a mailed patch in place. The
OnePlus 7T Pro device-tree series has not been mailed.

## Queue

| Series | Patches | State | Remaining gate |
| --- | ---: | --- | --- |
| Q6AFE DisplayPort playback widget | 1 | [v1 withdrawn](https://lore.kernel.org/r/178648858640.3471590.18184750436169014545.q6afe-withdrawal-resend@snyders.xyz) | Do not send the unsupported runtime claim as v2 |
| SM8150 download-mode register | 1 | [Submitted v2](https://lore.kernel.org/r/20260811-submit-sm8150-dload-v2-1-fb688ac4896b@snyders.xyz) | Awaiting review; no unresolved finding |
| Qualcomm SMB2 fixes | 5 | [Submitted v1](https://lore.kernel.org/r/20260812-qcom-smbx-fixes-v1-0-eb48246be599@snyders.xyz) | Awaiting review |
| Qualcomm SMB5 charger support | 2 | [Submitted v3](https://lore.kernel.org/r/20260813-submit-qcom-smbx-send-v1-v3-0-27be0091d7c7@snyders.xyz) | Awaiting review; exact tree passed charge and physical VBUS gates; depends on the five SMB2 fixes |
| OnePlus 7T Pro initial device tree | 2 | Preflight | Boot the exact rebased DTB once and verify the initial hardware subset |
| S6SY761 resume sensing | 1 | Local, `checkpatch --strict` clean | Confirm on a second suspend cycle after the next flash, then send standalone; it is an upstream driver bug, not device-specific |
| DSI raw FIFO/timeout reporting | 1 | Local, `checkpatch --strict` clean | Diagnostic-only improvement; decide whether to send alone or with the eventual DSI transport fix |
| PAS proxy power domains held until stop | 1 | Local | `qcom_pas_handover()` drops the proxy votes at handover, but the domains only actually power off at the first `genpd_suspend_noirq()`, taking `cx` and `mss` from under a modem that has run for minutes. First suspend of every boot crashed it, 6 boots out of 6; 0/4 with the patch and 0/15 over real s2idle cycles. Power cost of holding the domains is unmeasured |
| SM8150 sdhc_2 power domain | 1 | Local | `sm8150.dtsi` puts the SD host in `<&rpmhpd 0>`, which is `SM8150_MSS`, so it votes on the modem's power domain and drops it on suspend. Verified on hardware: `pm_test=devices` goes from 6/10 crashes to 0/15. Affects every SM8150 board running a modem, not just this one |
| IPA bounded GSI transaction wait | 1 | Local | `gsi_trans_commit_wait()` waits forever on a completion from the modem's SSR notifier chain while the rproc lock is held, so a modem crash can wedge recovery permanently and block any driver unregistering an SSR notifier. Two sysrq-w stack traces in the evidence file |
| ath10k snoc wakeup capability | 1 | Local | `ath10k_snoc_hif_suspend()` gates on `device_may_wakeup()` and nothing ever calls `device_init_wakeup()`, so the WoWLAN path is dead code and mac80211 tears the link down on every suspend. Wi-Fi lost on 13/15 cycles before, 0/12 after |
| ath10k recover from INCOMPATIBLE_STATE | 1 | Local | Bringing WLAN up is refused with QMI error 90 when the firmware still considers it enabled, and the state is permanent although the driver holds the command that clears it. Robustness only: it does not explain why the teardown fails |
| ath10k MSA reclaim after modem crash | 2 | Local | The reclaim hangs off the WLFW service leaving QRTR, which a crashing modem does not reliably produce, and it names a source VM set the hypervisor rejects once the modem is torn down. Wi-Fi survives 4/4 modem crashes with both applied, against 0/4 before |
| PM8150 PON reboot modes | 1 | Local | `pm8150.dtsi` declares `qcom,pm8998-pon` without `mode-bootloader`/`mode-recovery`, so `qcom-pon.c` registers no reboot modes and `reboot bootloader` silently returns to the OS. Every other mainline user of that compatible — pm6125, pm6150, pm6350, pm660, pm8998 — carries both properties. Affects every PM8150 board, not just this one. Needs one boot to confirm the phone reaches fastboot |

All submitted messages were sent through the kernel.org `b4` web endpoint,
signed with the configured patatt key, and copied to
`Robin Snyders <robin@snyders.xyz>`. Each 2026-08-12 send was reflected to the
same mailbox first and then verified in Infomaniak and on lore. The
device-tree series remains held back until its hardware gate is complete.

The device-tree series intentionally excludes native panel support, audio,
Type-C role switching, cameras, NFC, haptics and other experimental pieces.
Those require focused follow-up series with their own bindings and evidence.

## Userspace upstream

Not kernel patches, so not part of the `b4` queue above, but found here and
worth reporting.

| Project | Issue | State |
| --- | --- | --- |
| iio-sensor-proxy 3.9 | A `Claim*` that arrives before the matching driver has registered is accepted and lost. The daemon owns its D-Bus name before it finishes enumerating SSC sensors, so any client watching the name wins the race | Patch written, not yet submitted |

The daemon takes `net.hadess.SensorProxy` and only then discovers sensors. On a
Qualcomm SSC device that discovery is a QMI round trip per sensor over QRTR —
tens of milliseconds — while a client watching the bus name claims within ten.
Measured on this phone, one restart under a running KWin:

A patch now exists. `bus_acquired_handler` registers both D-Bus objects,
making every method callable, while discovery and `driver_open` run afterwards
in `name_acquired_handler`; a claim landing between the two is answered against
a NULL client array and a NULL device, and asserts twice:

```
g_ptr_array_add: assertion 'rarray' failed
driver_set_polling: assertion 'sensor_device' failed
```

The proximity work measured the window directly: the device is found, and the
claim arrives 15 ms later, before anything has been opened. The patch moves
discovery and opening ahead of the object registration, so no method is
callable until the devices behind it exist. It is
[`0010-Open-the-sensors-before-exporting-the-D-Bus-interfac.patch`](../src/postmarketos/pmaports-sm8150/temp/iio-sensor-proxy/0010-Open-the-sensors-before-exporting-the-D-Bus-interfac.patch)
in the local aport series and builds clean, but is **not verified on the
device**. That verification is its gate, and it decides more than proximity: if
the patch is right, `hotdog-sensor-gate` no longer needs to exist for the
accelerometer either. It goes to the project as a merge request, not to a
mailing list.

```
15:09:20.410  Handling driver refcounting method 'ClaimAccelerometer'
15:09:20.419  Found SSC proximity
15:09:20.434  Found SSC accelerometer      <- 24 ms after the claim
```

No samples follow, and `AccelerometerOrientation` stays `undefined` for the
life of the process. A second, later claim from `monitor-sensor` also failed
to enable it, while `ClaimLight` in the same call enabled the light sensor
normally — the light driver had registered before that client connected. The
reading that fits is that the early claim takes the 0→1 client transition
without a driver to enable, and every later claim is then only 1→2. That
reading is not proven; what is measured is that a claim landing before
registration is silently dropped and the client never retries.

Two fixes are plausible upstream: own the bus name only after driver
discovery, or re-check pending claims when a driver registers. The second is
better — it also covers a sensor DSP that publishes late, which is the actual
situation here.

Worked around locally by [the boot gate](../helpers/hotdog-sensor-proxy-gate.sh),
which restarts the daemon once SEE has published `accel` — early enough that
the session, and therefore KWin's single claim, starts afterwards.

## Automated review follow-up

The bot findings and an independent source audit are fully dispositioned. The
download-mode ordering correction is public as v2. Q6AFE v1 was withdrawn
because the claimed runtime effect could not be proven. Five pre-existing
SMB2 defects were sent as a separate `Fixes:` prerequisite series, and SMB5 v2
was rebuilt after resolving Type-C/VBUS ownership, generation-specific AICL,
status decoding, IIO scaling, probe publication and cleanup ordering.

The claimed SMB5 watchdog-offset mismatch remains a false positive: the
relative offsets plus the charger base resolve to Qualcomm's downstream
PM8150B MISC registers. The distinct missing-base bug in the watchdog handler
was real and is patch 1/5 of the public SMB2 series.

The initial bot audit is retained as history in
[the 2026-08-11 review audit](evidence/2026-08-11-upstream-review-audit.md).
The authoritative final decisions, source proofs, sent commits and Message-IDs
are in [the 2026-08-12 follow-up](evidence/2026-08-12-upstream-follow-up.md).

## Validation completed

- every sent commit carries the required DCO trailers and every outgoing mail
  explicitly copies `robin@snyders.xyz`;
- SM8150 dload v2 applies to linux-next `5e6de6a2b522` and Qualcomm
  `arm64-for-7.3`, passes strict checkpatch and builds the schema-checked MTP
  DTB;
- the five SMB2 fixes apply cleanly to power-supply `for-next` and pass ARM64
  LLVM `W=1`, Sparse, strict checkpatch and `git diff --check`;
- SMB5 v3 is based on power-supply `for-next` `99b38cda3f4c`; replaying the
  five public prerequisites plus both v3 patches yields the validated tree
  `face07e87b8b06d4d93e0d8d598e13a64d72f255`;
- the final SMB5 driver passes ARM64 LLVM `W=1` and Sparse without a driver
  warning, the binding passes targeted `dt_binding_check`, and both patches
  pass strict checkpatch with zero diagnostics;
- `b4 prep --check`, dependency replay, reflected delivery, Infomaniak
  receipt and public lore retrieval all passed for the 2026-08-12 series.

## Final Hotdog hardware gate

Before mailing the OnePlus device-tree series, apply it to the stated
linux-next base, build `qcom/sm8150-oneplus-hotdog.dtb`, and boot that exact
artifact without carrying unrelated project patches. Verify at minimum:

1. direct kernel entry and visible simple-framebuffer output;
2. UFS discovery and root filesystem access;
3. USB peripheral networking or ACM access;
4. S6SY761 touch and both volume keys;
5. WiFi and the ADSP/MPSS remote processors;
6. a clean software reboot without Qualcomm 900e download mode.

Record the exact commit, DTB hash and result in `docs/evidence` before removing
the preflight hold.

## Reproduction and dry-run commands

Use the enrolled `b4` prep branch for the series. Before any external send,
confirm that the cover has the prior revision in `In-Reply-To`, the changelog
is complete, every patch has the intended DCO trailers, and
`Robin Snyders <robin@snyders.xyz>` appears in Cc.

```sh
b4 prep --show-info
b4 prep --check
b4 prep --check-deps --no-cache
b4 send --output-dir /tmp/series-render
patatt validate /tmp/series-render/*.eml
```

Inspect every rendered header and archive the EMLs. Then reflect through the
same transport used for the real send and verify every message in Infomaniak:

```sh
b4 send --reflect --use-web-endpoint
b4 send --use-web-endpoint
```

After the real send, verify the actual Message-IDs rather than the dry-render
IDs, retrieve the public thread with `b4 mbox --no-cache`, and run
`b4 am --no-cache --check` on the posted revision. `b4 send` automatically
rerolls the prep branch; the resulting templated next-revision cover is not a
new submission and must not be sent until a real review requires it.

## Not for upstream

`net: ipa: add a diagnostic switch for the system suspend callback` adds an
`no_system_suspend` module parameter purely to bisect the modem crash, since
unloading IPA makes the modem assert on its own in `ipa_hwp_init.c` and so
cannot be used as a test arm. It must never be sent.
