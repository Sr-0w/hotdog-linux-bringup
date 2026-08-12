# NFC: controller bring-up and RF configuration - 2026-08-10/12

## Result

The NFC controller is described, the upstream driver binds it, and an `nfc0`
adapter appears. Revision `r144` now applies the board-specific OxygenOS NCI
configuration successfully. Power-on, every individual reader protocol and the
combined reader mask run without resetting the handset. No target has been
reported yet, so tag reading is not complete.

## Starting point

Nothing described NFC at all: no `nfc` class, no driver loaded, and no I2C
device beyond the touchscreen, Hall sensors, amplifiers, fuel gauge and cameras.

The stock device tree has it. On the bus mainline calls `i2c9`:

```
soc/i2c@a84000/nq@28   compatible = "qcom,nq-nci"
    qcom,nq-irq     = tlmm 47
    qcom,nq-ven     = tlmm 41
    qcom,nq-firm    = tlmm 48
    qcom,nq-esepwr  = tlmm 42
    qcom,nq-clkreq  = tlmm 113
```

`qcom,nq-nci` is the vendor binding for an NXP NQ part. Upstream has
`nxp,nxp-nci-i2c`, which wants the same interrupt, enable and firmware lines, and
the kernel here already builds `CONFIG_NFC_NXP_NCI_I2C` and the NCI core.

## The change

`0127` enables `i2c9` and describes the controller with the three lines the
upstream binding takes. The secure-element power and clock-request lines are left
out deliberately: nothing upstream consumes them, and the secure element is a
separate question from reader mode.

## Result on hardware

```
/sys/class/nfc/nfc0
/sys/class/nfc/nfc0/device/name -> nxp-nci-i2c

nxp_nci_i2c   12288  0
nxp_nci       12288  1 nxp_nci_i2c
nci           40960  2 nxp_nci,nxp_nci_i2c
```

`neard` sees the adapter and lists its protocols:

```
nfc0:  Protocols: [ Felica MIFARE Jewel ISO-DEP NFC-DEP ]
       Powered: No
```

## The pin configuration was wrong, and fixing it powers the controller

The first attempt invented the pin states: `bias-disable` with `output-low` on
the enable and firmware lines. Setting `Powered` then never returned, and one
attempt rebooted the handset.

The stock states say something different:

```
nfc_enable_active   pins = gpio41, gpio42, gpio48   bias-pull-up
nfc_int_active      pins = gpio47                   bias-pull-up
nfc_clk_req_active  pins = gpio113                  bias-pull-up
```

All pulled up, no driven levels, and the enable group covering the
secure-element line as well. Following that exactly:

```
Powered before: b false
Powered after:  b true
```

The controller now completes its NCI reset and powers on.

## Protocol-isolation result

A generic-netlink helper was added as
`helpers/hotdog-nfc-poll-mask.c`. It deliberately does not subscribe to target
events or print tag data. On the `r143` kernel, each of these discovery masks
powered the adapter, polled for at least five seconds and stopped cleanly:

| Test | Mask | Result |
|---|---:|---|
| Jewel | `0x02` | Stable |
| MIFARE | `0x04` | Stable |
| FeliCa | `0x08` | Stable |
| ISO 14443-A | `0x10` | Stable |
| NFC-DEP | `0x20` | Stable |
| ISO 14443-B | `0x40` | Stable |
| Combined reader | `0x5e` | Stable for eight seconds |
| All advertised protocols | `0x7e` | Stable for eight seconds |

The GPIO 47 interrupt count advanced during the tests, and USB networking plus
SSH remained available. `neard` can also start its initiator poll loop without
a reset. It did not expose a target object during the observation window.

This supersedes the earlier reset result below. The reset is no longer
reproducible after the intervening memory-reservation, UFS and power fixes.

## Historical reset result

Starting the RF poll loop reboots the handset, reproducibly, on every attempt
with the corrected pin configuration as well. Sometimes `StartPollLoop` blocks
and sometimes it returns before the reset lands, so the reboot is not simply the
call hanging.

Streaming `dmesg -w` to another machine while triggering it does not catch
anything either: the stream picks up again from the *next* boot, so nothing is
emitted between the RF field coming up and the system going down. That is the
same signature the camera rails had, where a PMIC-level reset leaves the kernel
no chance to write.

So the controller answers on I2C and initialises, and something about bringing
the RF field up takes the system down. No tag has been read.

**Tested: the secure-element line is not it.** `gpio42` was grouped with the
enable pins only because the stock groups it, and nothing here drives a secure
element, so powering it was a candidate. Dropping it from the group and
retesting reboots the handset exactly as before.

The node still carries no regulators at all, and the stock `nq@28` node carries
none either, so whatever supplies the controller is always on from Linux's point
of view. That makes a described-supply gap unlikely and leaves the RF field
itself, or the driver's handling of it, as what takes the system down.

Those proposed isolation tests are now complete. They ruled out a
protocol-specific reset and confirmed that the IRQ is delivered.

## Power-cycle recovery weakness

Explicitly putting the adapter `DEV_DOWN` and then issuing `DEV_UP` causes the
next I2C transaction to fail with `-EREMOTEIO` (`-121`) until the handset is
rebooted. Unloading and reloading the modules does not recover that contaminated
state. Tests therefore stop RF polling but keep the controller powered. This is
separate from RF discovery and still needs a bounded reset-sequence fix in the
NXP I2C transport.

## OxygenOS configuration gap and r144 candidate

The OxygenOS vendor partition contains a PN553 firmware image plus separate
no-eSE NXP configuration files. The open NXP Android HAL applies the profile,
TVDD, four platform RF blocks, extended core settings, RF-field setting and core
configuration after `CORE_INIT` and before discovery. The generic upstream
`nxp-nci` driver performs none of that board-specific setup.

Revision `r144` is an experimental, reversible implementation of that missing
stage:

- the generic driver accepts a named configuration firmware and applies only
  complete, unfragmented NCI `CORE_SET_CONFIG` packets in `post_setup`;
- the device tree identifies the controller as `nxp,pn553` and names the Hotdog
  configuration;
- `helpers/extract-nxp-nci-config.py` reproducibly converts the local OxygenOS
  no-eSE files into a 791-byte, 14-command blob;
- the proprietary blob is isolated in the existing non-free device firmware
  package instead of embedding board data in the generic driver.

The first exact concatenation contained nine commands and was 771 bytes. Its
252-byte RF block contained 29 parameters in one `CORE_SET_CONFIG` command.
Opening the device with that blob blocked the NCI request before an error could
be logged and the hardware watchdog restarted the phone. Prefix isolation
showed that the profile and TVDD commands completed and that the first large RF
block was the first failing command.

The extractor now preserves every parameter byte and its order while splitting
multi-parameter commands at a 64-byte frame target. Parameters which cannot be
split remain intact. A byte-for-byte parameter-stream comparison between the
nine source commands and 14 generated commands passes.

On hardware the generated blob has SHA256
`2a0c2af4adade6d17b8fe7f734cd83d0dc5ce12cfa63cea2a3f6cf4b756951b8`.
The kernel reports:

```
nxp-nci_i2c 5-0028: applied NCI configuration nxp/pn553-hotdog.nci
```

Polling all advertised protocols (`0x7e`) for four seconds then stops cleanly.
`neard` reports the adapter as powered and polling and the GPIO 47 interrupt
count advances. It has not exposed a target object during the observation
window, so target discovery and reading remain the next hardware gate.

The driver object, strict patch checks and `r144` kernel package build pass.

No tag identifier, payload or captured private object is stored in this
repository. Private runtime observations remain in ignored local logs.

The kernel also logs, harmlessly and only at boot, `udevd: nxp-nci.ko error=No
such file or directory`, which is udev trying to load the module before the
module tree is mounted; it loads later on its own.

## The secure-element line is implicated in the reset after all

An earlier section here recorded that dropping `gpio42` from the enable pin
group changed nothing, and concluded the secure-element line was not involved.
That conclusion was drawn from a test at the *polling* stage. Measured at the
*power-on* stage, it is wrong.

Four runs, changing one thing at a time:

| Revision | `gpio42` pulled up | configuration blob present | powering the adapter |
| --- | --- | --- | --- |
| `r148` | no | no | fails with `-121`, no reboot |
| `r148` | no | yes | reboots |
| `r149` | yes | yes | reboots |
| `r149` | yes | no | reboots |

With `gpio42` in the group the handset resets whether or not a configuration is
applied, so the blob is not the trigger there. Without it, and with no
configuration to apply, the controller fails cleanly instead of taking the
system down.

`gpio42` is `qcom,nq-esepwr` in the stock tree, the secure element's power line.
The stock groups it with the enable pins, but the stock also runs a HAL that
owns the secure element; nothing here does. Pulling it up on this system appears
to be enough to collapse something.

`r149` is therefore reverted to the `r148` pin group.

## What is still unexplained

On `r148`, with no configuration applied, powering the adapter fails with
`NFC: Read failed with error -121` and four interrupts arrive on GPIO 47. So the
controller signals, and the I2C read that follows is not answered.

That is a different failure from the reset, and it is the one to solve next: the
driver's IRQ thread treats `-EREMOTEIO` as a hard fault and latches
`phy->hard_fault`, after which every later interrupt is dropped. Whether the
first read is genuinely unanswered, or arrives while the driver is still in
`NXP_NCI_MODE_COLD` where the handler returns `-EREMOTEIO` unconditionally, has
not been separated yet.

## The power-on is marginal, and the reset destroys the evidence

`0134` prints the driver mode and the latch state next to any failing read, to
separate a genuinely unanswered read from an interrupt arriving in
`NXP_NCI_MODE_COLD`. It cannot be read, because the case it was meant to
diagnose takes the log with it.

Across repeated runs on the same kernel and the same pin group, with no
configuration blob present, powering the adapter does one of two things:

- fails with `NFC: Read failed with error -121` after four interrupts, and the
  system stays up; or
- resets the handset before anything is written to the log.

Both were observed on `r148`, and `r150` with the instrumentation reset before
printing a single line. So the power-on is marginal rather than deterministic,
and the reset path leaves nothing behind, exactly as the camera rails did.

That means the next step is not another device-tree variant. It is a channel
that survives the reset: a serial console on the debug connector, or ramoops
proven to retain across this particular reset, since `pstore` did not survive
the camera-rail resets either.

Two things are worth separating while that is set up. The `-121` case is
recoverable and cheap to reproduce; the driver latches `phy->hard_fault` on it
and drops every later interrupt, so one marginal read ends the session even when
the controller is otherwise healthy. Removing that latch, or resetting it on the
next power cycle, is a small change worth making on its own merits regardless of
what causes the first failure.

## The reset is a Geni I2C wedge, captured through ramoops

The reset does leave evidence after all. `ramoops@a9800000` is described and
`CONFIG_PSTORE_CONSOLE` is set, and `/sys/fs/pstore/console-ramoops-0` survives
this reset with the console output that preceded it:

```
[ 78.112662] geni_i2c a84000.i2c: Timeout abort_m_cmd
[ 80.630661] geni_i2c a80000.i2c: Timeout abort_m_cmd
[ 80.633753] power_supply bq27411-0: driver failed to report `status' property: -110
```

`a84000` is `i2c9`, the NFC bus. The Geni controller times out and then cannot
even abort the command. Two and a half seconds later `a80000`, which is `i2c8`
and carries the fuel gauge, times out the same way and the gauge fails with
`-110`.

Both sit on the same QUPv3 wrapper: `i2c8` is SE0 and `i2c9` is SE1 of wrapper 1.
So an NFC transaction wedges the serial engine hard enough to take the
neighbouring engine with it, and the watchdog resets the handset.

That changes the diagnosis entirely. The trigger is neither the configuration
blob nor the secure-element line, both of which were suspected here in turn: it
is the I2C transport. The earlier `-121` and the resets are the same fault seen
at different points, depending on whether the controller happens to recover
before the wrapper locks up.

Worth noting that this also invalidates an earlier conclusion recorded above,
that the reset leaves nothing behind. It leaves a complete console log; the
mistake was checking `dmesg` after the reboot rather than `pstore`.

## What to change next

The bus is described here with `clock-frequency = <400000>` and with `dmas`
deleted, which forces FIFO mode. Neither was measured against the stock, and
either could be wrong for this part:

- the NXP NCI read is a two-stage transfer, a header read followed by a payload
  read, and Geni's handling of that pattern at 400 kHz has not been checked;
- other buses on this board that needed care, `i2c4` and `i2c8`, both run at
  100 kHz with DMA deleted, and `i2c9` was given 400 kHz without a reason;
- the stock device tree's own clock-frequency for this bus has not been read.

Dropping `i2c9` to 100 kHz is the cheapest next test and matches what every
other troublesome bus on this handset already does.
