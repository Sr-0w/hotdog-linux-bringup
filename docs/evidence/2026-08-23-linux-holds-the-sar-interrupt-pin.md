# Linux holds the SAR's interrupt pin for a card slot that does not exist

Date: 2026-08-23

A real device-tree defect, found while chasing the SAR. It does not explain the
SAR, and saying so is the point of this note.

## The conflict

`sm8150.dtsi` enables `mmc@8804000` — sdhc_2, the SD card controller — with

```
cd-gpios = <&tlmm 96 GPIO_ACTIVE_LOW>
```

The OnePlus 7T Pro has no card slot. GPIO 96 is `dri_irq_num` for the SX9324 SAR
sensor, so Linux takes the sensor's interrupt line to watch for a card that
cannot be inserted. Measured:

```
line  96:  unnamed  input active-low consumer="cd"
```

and unbinding the driver frees it:

```
echo 8804000.mmc > /sys/bus/platform/drivers/sdhci_msm/unbind
line  96:  unnamed  input
```

The pin must be free before the SLPI arms its interrupts, so the unbind was
moved into [the boot gate](../../helpers/hotdog-sensor-proxy-gate.sh), which
reports `GPIO 96 libere a 9s` — well before the sensor core comes up.

## It does not fix the SAR

With the line demonstrably free from 9 seconds and the SLPI starting afterwards,
the SAR still publishes nothing: a configuration event and no sample, in
on-change and in continuous mode alike. So the conflict is a genuine defect
worth fixing on its own, and it is not the cause of the silence.

Recorded because a plausible mechanism that survives only until it is tested is
exactly the kind of thing that otherwise gets written down as an explanation.

## Keep the fix anyway

Two reasons. A driver holding a pin another processor needs is wrong whether or
not it currently breaks anything, and this one costs nothing to release on a
device with no slot. And sdhc_2 has already caused trouble here once: it sits in
`<&rpmhpd 0>` — `SM8150_MSS` — in `sm8150.dtsi`, so it voted on the modem's power
domain and dropped it on suspend, which is a separate patch already in the
upstream queue.

The proper form is to disable `sdhc_2` for this device in its own DTS rather
than unbind at run time. That needs a kernel rebuild and is queued with the
other two pending device-tree changes.

## Where the SAR actually stops

Established by [the SAR diagnostic](../../helpers/sar.py), which separates three
questions that are easy to conflate:

| question | SAR | proximity |
| --- | --- | --- |
| published, has a SUID | yes | yes |
| request accepted and honoured | **configuration event** | ack only, no event |
| emits a value | no | no |

They are not the same failure. The SAR is configured and then silent; proximity
is never configured at all. Any single explanation covering both has to account
for that difference, and the interrupt-starvation story does not — it would have
been refuted here in any case, since freeing GPIO 96 changed nothing.
