# SM8150 must report DisplayPort jack presence

Date: 2026-08-28

## Problem

The fresh Plasma Mobile image initially selected PulseAudio and exposed no ALSA
devices to WirePlumber. After selecting the standard PipeWire backend, the
built-in card, internal microphone and DisplayPort sink all appeared.

The DisplayPort sink was also offered while no dock or monitor was attached.
Plasma could therefore open `DISPLAY_PORT_RX_0` before DisplayPort link training
had completed. Every early attempt left QDSP6 AFE port `0x6020` timing out with
`-110`, and subsequent normal-user playback remained silent.

## Kernel contract

The SM8150 machine driver did not register the DisplayPort jack. The SM8250
driver uses the common Qualcomm helper for the equivalent link. The isolated
candidate applies the same architecture to SM8150:

```c
if (cpu_dai->id == DISPLAY_PORT_RX)
	return qcom_snd_dp_jack_setup(rtd, &pdata->dp_jack, 0);
```

This does not manufacture presence in userspace. It connects the ALSA jack to
the existing DRM/HDMI codec presence path so PipeWire can distinguish an
available DisplayPort route from a disconnected one.

## Combined validation image

The r35 integration image contains exactly two changes relative to the running
r33 baseline:

1. upstream MSM GEM imported dma-buf ownership fix, already validated alone as
   r34;
2. this DisplayPort jack-presence candidate.

The kernel package build and the Hotdog clean validation script passed. The
generated 96 MiB AVB boot image has SHA256
`c4f8459d5a0aeb1ea745d6e6cff04d72a67dce865d0dbeab84f6e57e0a0c2340`;
`avbtool verify_image` verifies its footer and `boot` descriptor.

## Hardware gate

Status: **built, hardware validation pending**.

PASS requires all of the following:

- before dock insertion, PipeWire does not expose DisplayPort as available;
- after link connection, DisplayPort becomes available without restarting the
  sound server;
- normal-user playback reaches the monitor without AFE `0x6020` timeout;
- disconnect removes availability cleanly;
- no GEM warning, refcount failure, Qualcomm 900e/9008 transition or SSH loss.

The sound test is interactive because the monitor input must be switched first.
No tone should be played until the operator explicitly confirms that step.
