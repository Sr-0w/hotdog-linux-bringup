# The charge gap at plug-in is two PD hard resets

Date: 2026-08-19

## The report

"Il charge moins d'une seconde puis s'arrete de charger", then starts on its
own after a pause. Reported first against a PC port, reproduced here with a
65 W USB-C charger.

## Charging itself is fine

Sampling the supply every 200 ms across a plug event shows the input limit
ramping normally on both paths:

| source | input current limit over time |
| --- | --- |
| 65 W charger, detected `DCP` | 100 mA → 450 → 1100 → 1300 → 1400 → **1450 mA** |
| PC port, detected `SDP` | 100 mA → 600 → **900 mA** after enumeration |

So AICL works, BC1.2 detection works, and the final steady state is correct in
both cases. Nothing is broken about the current limits.

## What the gap actually is

The TCPM state log, drained from
`/sys/kernel/debug/usb/tcpm-.../log`, gives the sequence on attach:

```
SNK_ATTACHED -> SNK_STARTUP -> SNK_DISCOVERY
Setting voltage/current limit 5000 mV 0 mA
SNK_DISCOVERY -> SNK_WAIT_CAPABILITIES
pending state change SNK_WAIT_CAPABILITIES -> HARD_RESET_SEND @ 310 ms
  ... AMS HARD_RESET start, SNK_HARD_RESET_SINK_OFF @ 650 ms, SINK_ON
pending state change SNK_WAIT_CAPABILITIES -> HARD_RESET_SEND @ 310 ms
  ... AMS HARD_RESET start, SNK_HARD_RESET_SINK_OFF @ 650 ms, SINK_ON
pending state change SNK_WAIT_CAPABILITIES -> SNK_READY @ 310 ms
```

No `PD RX` line appears anywhere between attach and the resets: the source
never sends Source_Capabilities. TCPM waits `PD_T_SINK_WAIT_CAP`, 310 ms, then
hard resets, twice, because `PD_N_HARD_RESET_COUNT` is 2, and each hard reset
turns the sink off for 650 ms. That is roughly 2.3 seconds with charging
interrupted, immediately after it started. It then lands in `SNK_READY` and
charges normally.

That is a real, measured interruption. Whether it is *the* symptom reported is
not established, and the section below explains why.

## The battery was full throughout, which confounds the attribution

The supply samples carry the battery state, and it never left the top of its
range for the whole capture:

```
13:21:55  Charging      icl=500000   batt=+194000@93%
14:15:53  Discharging   icl=0        batt=-89000@100%    <- unplug
14:15:57  Not charging  icl=100000   batt=-549000@100%   <- 65 W attached
14:16:20  Charging      icl=1450000  batt=+114000@100%
```

A full battery produces "starts, then stops" on its own: the charger terminates
and only resumes at the recharge threshold, and it does so for far longer than
2.3 seconds. Both explanations therefore fit the report, and the capture cannot
separate them because the pack stayed between 93 and 100 percent.

What the battery state cannot explain is the PD behaviour. Source capability
messages are sent by the source unprompted and TCPM negotiates regardless of
charge level, so the absence of any `PD RX` from this charger stands on its own.

The discriminating test is simply to repeat the plug event with the pack around
70 to 80 percent. Until then the hard resets are a measured fact whose
contribution to the reported experience is unquantified.

## Why the gentle path is not taken

`tcpm.c` has a softer route for precisely this case, which asks the source for
its capabilities instead of resetting it:

```c
if (!port->self_powered)
        upcoming_state = SNK_WAIT_CAPABILITIES_TIMEOUT;  /* Get_Source_Cap */
else
        upcoming_state = hard_reset_state(port);         /* hard reset */
```

`SNK_WAIT_CAPABILITIES_TIMEOUT` exists because a hard reset "might effectively
kill the machine's power source" on a bus-powered device. A device with its own
battery is not at that risk, so a `self-powered` port is sent straight to the
hard reset.

Our connector declares it, in `sm8150-oneplus-hotdog.dts`:

```
connector {
        compatible = "usb-c-connector";
        power-role = "dual";
        data-role = "dual";
        self-powered;
```

and the property is present at runtime under
`.../typec@1500/connector/self-powered`.

This is not a mistake. It is conventional and semantically right: 11 of the 47
Qualcomm device trees carrying a `usb-c-connector` declare it, including other
battery-powered handsets such as the Fairphone 3 and 4, the Pixel 4 and the
Xiaomi nabu. The behaviour that follows is the specified one.

## Where that leaves it

The interruption is the cost of being spec-compliant with a source that does
not answer PD. Two ways to remove it, neither obviously right:

- **Drop `self-powered`.** TCPM would send `Get_Source_Cap` rather than
  resetting, and the sink would never be turned off. It misdescribes the
  hardware, and it would change TCPM's behaviour elsewhere, so it is a
  behavioural preference expressed as a hardware claim.
- **Leave it.** Charging is correct within about 2.3 seconds of plugging in.

Deliberately not decided here. Worth revisiting if a cleaner mechanism appears
upstream, such as separating "a hard reset is survivable" from "prefer a hard
reset".

## The source that does no PD

The cable question is settled: the 65 W unit is a Lenovo laptop supply with a
USB-C output and nothing between it and the handset, so this is a C-to-C
attachment and a genuine PD source is expected. Comparing the two attachments
in the same log isolates the difference:

| | Lenovo laptop port, ts 4556 | Lenovo 65 W supply, ts 4608 |
| --- | --- | --- |
| CC | `CC2: 0 -> 5`, Rp-3.0A | `CC2: 0 -> 3`, Rp-default |
| polarity | 1 | 1 |
| `PD RX` | yes, 120 ms in | never |
| outcome | PD contract, Identity `17ef:a207` | two hard resets, gives up |

Two hypotheses die here. Orientation is not involved: both attach at polarity 1,
the same way round. And the PMIC decodes Rp-3.0A correctly when it is present,
fifty seconds earlier on the same port, so the `Rp-def` reading is a real
measurement rather than a decoding gap. `CC1` stays open in both, so there is no
e-marker.

A 65 W supply advertising Rp-default and then never initiating PD is not
compliant behaviour on its part. It costs nothing here, because BC1.2 detects it
as `DCP` and AICL still ramps to 1450 mA, but it is worth recording that the
receive path is demonstrably working on this port and this orientation.
