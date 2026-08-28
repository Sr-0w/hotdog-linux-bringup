# DisplayPort hotplug exposed the upstream MSM GEM dma-buf refcount bug

Date: 2026-08-28

## Scope

The clean Linux 6.17 r33 image boots a fresh postmarketOS edge Plasma Mobile
rootfs. Its first dock test survived the complete 180-second capture and
enumerated the GenesysLogic USB2/USB3 hubs, RTL8153 Ethernet, USB storage and a
connected DRM DisplayPort connector. It did not reproduce the earlier immediate
r30/r32 reset.

That run was not clean. KWin repeatedly closed buffers during DisplayPort link
renegotiation and the kernel reported:

```text
WARNING: ... msm_gem_free_object+0x1c8/0x26c
refcount_t: underflow; use-after-free
drm_gem_object_handle_put_unlocked
drm_gem_object_release_handle
drm_gem_handle_delete
drm_gem_close_ioctl
```

The USB3 hub also disconnected and re-enumerated several times. The phone
remained reachable over Wi-Fi, but the warning proves memory ownership was
already broken.

## Reproduction and crash capture

Device r45 changes only userspace audio selection: it replaces PulseAudio with
the PipeWire backend already required by the validated Hotdog UCM/WirePlumber
path. The kernel remains byte-identical r33.

After a clean reboot, WirePlumber saw the built-in ALSA card, DisplayPort sink
and internal microphone. Inserting the dock again caused an abrupt Qualcomm
`05c6:900e` transition before the phone-local logger observed its first USB
host child. This shows the crash is not introduced by a new kernel patch in
r45; the same kernel race had already warned in the preceding r33 run.

QDL captured every offered region with `--skip-reset`: four complete 2 GiB DDR
segments, KMSG, OCIMEM, PIMEM, DCC, IPA and PMIC state. The capture completed
without resetting the phone. Raw RAM remains private. Public identifiers:

- KMSG SHA256:
  `f9c827bb35f52f45e311675ecc8bc2ce87734e09bd84fe4ac6b9f3f76ed14856`;
- ramoops reservation SHA256:
  `91f056dd1f0ebb6a44b5e30a79754ff9d640ec3f9a94863a7a7d7a5de272595a`;
- decoded ramoops console SHA256:
  `0073c38f51a0b5a5c13fc6e4f6aa2c1dbd39d78ea5c6b40b84e342bb3a3cc2ff`.

The base ramoops console contains the completed boot but no panic record; the
full in-memory analysis remains available if the targeted fix does not remove
the failure.

## Exact upstream defect

The warning is byte-for-byte the defect fixed by upstream commit
`c34e08ba6c0037a72a7433741225b020c989e4ae`:

```text
drm/msm: Fix GEM free for imported dma-bufs
```

The 6.17 SM8150 base contains commit `de651b6e040b`, which changed the release
condition to `obj->resv != &obj->_resv`. Imported dma-bufs satisfy that
condition too, despite not being `MSM_BO_NO_SHARE`. Their reservation object
was therefore treated as the driver's shared reservation and incorrectly put.

The upstream fix requires both conditions:

```c
if ((msm_obj->flags & MSM_BO_NO_SHARE) &&
    (obj->resv != &obj->_resv))
        drm_gem_object_put(r_obj);
```

Its commit message reports the same line, call trace and workload class, was
tested on three Qualcomm platforms, and is the minimal correction for the
observed underflow. The exact upstream patch is staged alone as r34 on
`bringup/hotdog-sm8150-dock-stability`.

## Hardware validation

The r34 boot image changed only this upstream fix relative to the r33 kernel.
It booted the existing fresh Plasma Mobile rootfs, and the complete dock then
enumerated its USB2 and USB3 hubs, RTL8153 Ethernet, USB storage and DisplayPort
connector. KWin remained active while the phone was initially reachable.

The pre-fix signatures did not recur:

- no `msm_gem_free_object` warning;
- no refcount underflow or use-after-free report;
- no Qualcomm `05c6:900e` or `05c6:9008` transition while SSH remained
  reachable;
- no immediate loss of SSH during enumeration.

The USB3 hub did renegotiate once, and DisplayPort audio still failed with AFE
port `0x6020` timeouts. After the reachable observation window ended, reconnecting
the phone to the PC exposed it in Qualcomm `05c6:900e`. A second complete
no-reset RAM capture was therefore started. The phone-local logger did not
record the terminal event, so the late crash must not be attributed to the GEM
bug merely because that was the first known defect.

## Exact r34 RAM result

The second QDL capture again contains all four 2 GiB DDR segments and was
completed with `--skip-reset`. Public identifiers are:

- firmware KMSG region SHA256:
  `91970cb8e80534ccb2ea87a90c2ede166d22f173c626a87aa301d707b9ad7f8b`;
- ramoops reservation SHA256:
  `5f7f92a784b7d4d4874573d8614d843ea608f23f38d38f65f5b146de8dbf1234`;
- decoded ramoops SHA256:
  `158b6bc346a85472fc5fd536969453815ac9211a1aeab021dae24f18dfa13630`.

An exact-symbol r34 `vmlinux` was rebuilt with the same Alpine toolchain. Its
Image is byte-identical to the kernel unpacked from the tested r34 boot image.
Ramparser recovered KASLR offset `0x3e4b8e080000` and the complete printk ring.

There is still no Linux panic, oops or lockup report. The dock is inserted at
kernel time 744 s. PipeWire's normal-user DisplayPort stream immediately starts
AFE port `0x6020`; configuration times out, and the sound server retries every
three seconds while the DSP alternates timeout, generic error and already-active
responses. The final line at 923.563 s is:

```text
[drm:msm_dp_bridge_atomic_post_disable] *ERROR* audio comp timeout
```

The transition therefore occurs after about 179 seconds of active dock time,
not after the initially inferred twelve-minute stable interval. It crosses the
DisplayPort audio teardown boundary without a Linux panic. The GEM fix removes
one demonstrated memory-corruption bug, but it does not solve this second
failure.

Status: **the exact GEM warning is not reproduced, but overall dock stability
remains BLOCKED by a later 900e transition**.

DisplayPort presence and audio are validated independently on
`bringup/hotdog-sm8150-dp-jack-presence` and
`bringup/hotdog-sm8150-dp-audio`. This topic must not absorb either change just
because the combined validation image contains them.
