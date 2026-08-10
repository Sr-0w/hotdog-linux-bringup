# NFC: the controller is described and binds - 2026-08-10

## Result

The NFC controller is described, the upstream driver binds it, and an `nfc0`
adapter appears. Powering the adapter does not complete, so no tag has been read
yet.

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

## Where it stops now

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

Worth trying next, in rough order of cost: bringing the field up with a single
technology selected rather than the full initiator sweep, since `StartPollLoop`
asks for everything the adapter advertises; checking whether the interrupt is
actually being delivered on GPIO 47 before the field comes up, by watching the
count in `/proc/interrupts`; and comparing against the stock's NCI init sequence,
which the vendor driver in the published kernel spells out.

The kernel also logs, harmlessly and only at boot, `udevd: nxp-nci.ko error=No
such file or directory`, which is udev trying to load the module before the
module tree is mounted; it loads later on its own.
