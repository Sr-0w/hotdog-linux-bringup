# Sensor DSP: the SLPI runs - 2026-08-10

## Result

The SLPI, the Hexagon island the motion sensors live behind, boots and runs on
the mainline stack, and its FastRPC channel appears. This is the foundation the
sensor work needs; no sensor is exposed yet.

## Starting point

`remoteproc` listed only the modem and the ADSP. The device tree explained why:

```
remoteproc@2400000: qcom,sm8150-slpi-pas  status=disabled
remoteproc@8300000: qcom,sm8150-cdsp-pas  status=disabled
```

Only three IIO devices existed, all unrelated to motion: three PMIC ADCs and the
two MXM1120 Hall sensors that serve the pop-up camera.

## The firmware was not packaged

`firmware-oneplus-hotdog` ships `a640_zap`, `adsp`, `cdsp`, `modem`, `venus` and
`wlanmdsp`, and no SLPI image. The upstream firmware repository has none either.

The handset carries its own copy. Its `modem` partition holds the vendor's
split-PIL form:

```
/mnt/mdm/image/slpi.mdt
/mnt/mdm/image/slpi.b00 .. slpi.b21
```

Squashing the `.mdt` ELF header and its twenty-two segments into a single image,
the way `pil-squasher` does and the way the other remote processors here are
packaged, gives a 6,172,380-byte `slpi.mbn` with 21 non-empty segments.

Note that the `dsp` partition's `sdsp` directory is a different thing: it holds
the FastRPC skeleton libraries that run *on* the SLPI once it is up, including
`libchre_slpi_skel.so` and `fastrpc_shell_2`. Those will matter for the sensor
daemon, not for booting the island.

## The change

`0125` enables the node. Everything else was already correct: upstream describes
the SLPI with its SMP2P interrupts and `memory-region`, and this board already
reserves the stock window at `0x98100000` for it.

```dts
&remoteproc_slpi {
	firmware-name = "qcom/sm8150/oneplus/hotdog/slpi.mbn";
	status = "okay";
};
```

## Result on hardware

```
remoteproc remoteproc0: slpi is available
remoteproc remoteproc0: Booting fw image qcom/sm8150/oneplus/hotdog/slpi.mbn, size 6172380
remoteproc remoteproc0: remote processor slpi is now up
```

```
remoteproc0: slpi   -> running
remoteproc1: modem  -> running
remoteproc2: adsp   -> running
```

FastRPC follows, registering three compute contexts and creating the sensor
channel:

```
/dev/fastrpc-adsp
/dev/fastrpc-sdsp
```

The `no reserved DMA memory for FASTRPC` notice is the same one the ADSP channel
already prints and has not prevented use there.

## Not yet done

No sensor is exposed. The next step is the userspace side: `hexagonrpcd` talks
to the sensor core over FastRPC and is what turns this into IIO devices.

The firmware also needs packaging. It is currently installed by hand at
`/usr/lib/firmware/qcom/sm8150/oneplus/hotdog/slpi.mbn`; the firmware aport
sources a fixed upstream tarball that does not carry it.
