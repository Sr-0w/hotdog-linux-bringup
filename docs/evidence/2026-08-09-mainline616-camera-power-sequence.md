# Sony camera power sequencing

## Result

Kernel package `r92` can enable the previously failing PM8009 camera rails
without resetting the handset. The reset was not caused by PM8009 LDO1, LDO3
or LDO4 themselves. It was caused by the order used by the diagnostic helper:
VDIG was enabled before the module's external analogue gates.

The primary PM8150 retained the following reason after the old sequence:

```text
PON_OFF_REASON=0x80
FAULT_REASON1=0x40
```

The Qualcomm PON definitions decode this as UVLO. There was no ramoops record,
kernel panic or watchdog signature.

## Hardware validation

The `r92` helper separates the slot power-up into five reversible stages. Slot
0, on CCI bus 5, completed every stage during one boot:

```text
stage 1: VIO and VANA source prepared
stage 2: VANA physically enabled
stage 3: VDIG enabled after VANA
stage 4: MCLK running
slot powered, MCLK at 24000000 Hz, scanning bus
no device answered on this bus
```

The boot ID remained `943cf68a-622f-4f86-8b85-4d0a3fe7bfee`, USB networking
and SSH remained available, and every test unloaded the helper cleanly. This
is direct hardware evidence that LDO1 can be enabled safely with the module
rails sequenced correctly.

## IMX586 identification, revisions `r96` and `r97`

The OxygenOS sensor-module sequence was completed with the prerequisite shared
analogue rail that the module binary assumes is already on. Revision `r96`
enabled the PM8150L BOB supply and GPIO 11 before applying the six module-local
steps below. An exact 3.300 V regulator request failed with `-EINVAL`: the BOB
uses a 3.000 V base and 32 mV steps, so 3.300 V is not representable.

Revision `r97` requests the board requirement as the inclusive 3.300--3.320 V
range. The regulator framework selects 3.320 V, after which the complete slot
0 sequence succeeds without a reset:

```text
IMX586 prerequisite: VANA enabled=1 voltage=3320000 uV, GPIO11 logical=1
VDIG 1104000 load 1100000 mode=2
custom2, VIO 1800000, MCLK 19200000, reset released
IMX586 model register 0x0016 = 0x0586 (matched)
```

This identifies the main camera on CCI0 master 1 (mainline `i2c-5`) at 7-bit
address `0x1a`. The handset stayed on the same boot and the `r97` module was
unloaded cleanly. Sensor identity, bus, voltage and power ordering are now
hardware facts rather than inferred wiring.

## SM8150 C-PHY support, revision `r98`

The IMX586 module uses three C-PHY trios rather than four D-PHY lanes. The
existing CAMSS support accepted only D-PHY endpoints and programmed the SM8150
CSIPHY with two-phase tables even when downstream firmware described C-PHY.
Revision `r98` carries the SM8150 three-phase register table from Qualcomm's
GPL downstream kernel and propagates the bus type through the CAMSS pipeline.
It also selects C-PHY in the CSID, validates three-trio endpoint mappings and
widens the settle counter so the hardware value is not truncated.

The complete postmarketOS package passed the strict pmbootstrap build. Runtime
validation follows with the real IMX586 driver; that test will also calibrate
the initial C-PHY link frequency and settle time against hardware errors.

## OxygenOS module sequence

The remaining identification failure led to the exact OnePlus sensor-module
data in the mounted OxygenOS vendor image:

```text
lib64/camera/com.qti.sensormodule.ofilm_imx586.bin
lib64/camera/com.qti.sensormodule.semco_2nd_lens_imx586.bin
lib64/camera/com.qti.sensormodule.semco_imx586.bin
lib64/camera/com.qti.sensormodule.semco_imx586_no_otp.bin
```

All four variants encode the same power-up order:

1. `CUSTOM_GPIO1` high (TLMM GPIO 29)
2. VDIG enabled, then wait 1 ms
3. `CUSTOM_GPIO2` high (PM8150L GPIO 1)
4. VIO enabled, then wait 1 ms
5. MCLK at 19.2 MHz, then wait 1 ms
6. reset released, then wait 1 ms

They identify the sensor at 7-bit address `0x1a`, register `0x0016`, expected
value `0x0586`. Notably, the module sequence does not enable the VANA/BOB path
or TLMM GPIO 11 during power-up. That exact sequence is the input for `r93`.

## Artifacts

- package: `linux-oneplus-hotdog-mainline616-6.16.0-r92.apk`
- package SHA-256: `7933a6164112dfc60465ed8e6d167b007a3df5312cc869b`
- boot image: `images/pmos-experiments/2026-08-09-r92-camera-power-sequence/boot.img`
- boot image SHA-256: `e7f81ca2583dc1e5b1a4de5279410df1add4fe3ba823aded73047711a6ca46ec`
- `r97` package: `linux-oneplus-hotdog-mainline616-6.16.0-r97.apk`
- `r97` package SHA-256: `5d4dc5cca431c55b9d192401cc2c596fb648714c133e74610a5377458c18b9a8`
- `r98` package: `linux-oneplus-hotdog-mainline616-6.16.0-r98.apk`
- `r98` package SHA-256: `0ac76a0a69a2d2afc8dba3d9caa0fc11e0935cae2df391d56e461a64d2078470`
