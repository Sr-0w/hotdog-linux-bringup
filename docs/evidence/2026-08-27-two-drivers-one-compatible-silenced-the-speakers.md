# Two drivers, one compatible, and the speakers went silent

Date: 2026-08-27

The internal speakers worked on 6.16 and were silent on 6.17. Everything that
usually explains that was healthy.

## Everything looked right

The card enumerates as `OnePlus 7T Pro`, the UCM profile is installed and loads
its `HiFi` verb, both PCMs it references exist, both amplifiers answer on I2C,
and `speaker-test` runs to completion without an error:

```
tfa987x 2-0034: Chip revision: 0x0c74
tfa987x 2-0035: Chip revision: 0x0c74
```

Nothing was audible.

Two things looked suspicious and were not the cause. PulseAudio and
PipeWire/WirePlumber were both running, with PulseAudio holding `/dev/snd` and
WirePlumber showing no sinks — a real userspace conflict, but stopping the
contenders did not restore sound. The proximity arming daemon held a PCM,
because the ultrasound engine drives the same speaker; stopping it freed the
route and the speakers stayed silent.

## The two lines that mattered

```
tfa987x 2-0035: ASoC: sink widget PWUP overwritten
tfa987x 2-0035: ASoC: sink widget Speaker overwritten
```

Both amplifiers were bound to a driver registering identical DAPM widget names
for each instance, so the second overwrote the first and the routing collapsed
onto one set of widgets.

The driver doing that was not ours. The 6.17 base gained
`sound/soc/codecs/tfa9872.c` (`ASoC: codecs: add driver for tfa9872`), whose
match table claims both compatibles:

```c
{ .compatible = "nxp,tfa9872" },
{ .compatible = "nxp,tfa9874" },
```

The tree also carries the dedicated `tfa9874.c` this port validated on 6.16 —
byte-identical between the two trees apart from its `MODULE_AUTHOR` line. Two
drivers matching one compatible is a race the board cannot win, and on 6.17
`tfa987x` won: `lsmod` showed `snd_soc_tfa9874` at refcount 0 while
`snd_soc_tfa9872` held 2.

So the regression is not in any audio code. It is a name collision introduced by
the base tree, and it silently displaced a driver that had been hardware-
validated.

## Fixed and validated

`nxp,tfa9874` is left to the driver written for it. On `r16`:

```
2-0034 -> tfa9874
2-0035 -> tfa9874
widget overwritten: 0 occurrences

tfa9874 2-0034: unmuted status0=0016 status1=e2c2 status3=850f temp=0024
tfa9874 2-0035: pre-mute status0=0016 status1=e2fb status3=850f temp=003b
```

The owner confirms the test tone is audible. The amplifier die temperature rises
from 0x1f to 0x3b — 31 °C to 59 °C — across playback, which is the amplifiers
doing real acoustic work rather than merely unmuting.

The proximity arming service runs alongside it: with nothing claiming proximity
the ultrasound engine stays at `enable=0 rx_port=0`, the `MultiMedia1` mixer
route is on, and playback is unaffected.

## Worth remembering

Three regressions in this migration had the same shape — the Bluetooth `hsuart`
alias, the DisplayPort `altmodes` node, and this. Each time the answer was in
the tree already, in the 6.16 series that worked, and each time comparing the
two directly found it faster than reasoning from symptoms. The owner said so
outright: *"on a la source de vérité 6.16 si jamais au lieu de faire à
l'aveugle"*.
