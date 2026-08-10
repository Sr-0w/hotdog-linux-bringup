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

## The sensor process exists, and attaching to it crashes the island

`hexagonrpcd` is the userspace half. It is a file server: it hands the DSP the
files it asks for from `-R DIR`, and `-s` attaches to the sensors protection
domain. Installed and pointed at the new channel:

```
hexagonrpcd -f /dev/fastrpc-sdsp -d sdsp -s
Starting hexagonrpcd (INIT_ATTACH_SNS) on /dev/fastrpc-sdsp
Could not attach to FastRPC node: Broken pipe
```

The kernel side of that attempt is the interesting part:

```
arm-smmu 15000000.iommu: Unhandled context fault: fsr=0x402, iova=0x1fffff000,
                         fsynr=0x330001, cbfrsynra=0x5a1, cb=11
PDM: service 'sensor_process' crash:
     'EX:sensor_process:0x1:frpck_0_0:0x58:PC=0xb218da68'
qcom_q6v5_pas 2400000.remoteproc: fatal error received
remoteproc remoteproc0: crash detected in slpi: type fatal error
remoteproc remoteproc0: recovering slpi
```

Two things follow from this. The SLPI genuinely runs a `sensor_process`
protection domain, so the firmware is the right one and the island is doing what
it should. And the attach fails because that process takes an SMMU fault, at
`iova=0x1fffff000` on stream `0x5a1`.

That stream is not a mystery: `sm8150.dtsi` gives the SLPI's FastRPC node
`qcom,non-secure-domain` and three compute contexts at `0x5a1`, `0x5a2` and
`0x5a3`, and the fault is on the first of them. So the description is right and
the DSP is reaching for an address the host has not mapped into that context.

The kernel does say, for both the SLPI and the ADSP channels:

```
qcom,fastrpc ...fastrpcglink-apps-dsp: no reserved DMA memory for FASTRPC
```

Whether that is the cause or incidental is not established. The ADSP channel
fails differently, with `Operation not permitted` rather than a crash, so the
two are not the same problem.

Recovery is clean: remoteproc restarts the island by itself and it returns to
`running` with the system otherwise unaffected.

## Where the sensor work stands

| Step | State |
| --- | --- |
| SLPI firmware extracted and squashed | done |
| SLPI node enabled, island boots | done |
| FastRPC sensor channel present | done |
| `sensor_process` PD exists on the DSP | confirmed by its crash signature |
| Attaching from the host | faults the SMMU and crashes the PD |
| Sensors exposed as IIO | not reached |

The next thing to establish is what `iova=0x1fffff000` is, and whether the
FastRPC reserved-memory region the driver asks for is what is missing. The
vendor's own SLPI userspace is available for reference in the handset's `dsp`
partition, under `sdsp`, including `fastrpc_shell_2` and
`libchre_slpi_skel.so`.

## The FastRPC heap was genuinely missing, and it is not the fault

The stock device tree carries an `adsp_region` as a `shared-dma-pool` of 16 MB
with `alloc-ranges` capped at `0xffffffff`. The DSPs address 32 bits, the fault
was at `0x1fffff000` which is above 4 GB, and the kernel was saying `no reserved
DMA memory for FASTRPC`, so describing the same pool looked like the answer.

`0126` adds it and points the SLPI's FastRPC node at it. The first attempt was
rejected outright:

```
OF: reserved mem: node fastrpc-shared-pool compatible matching fail
```

because a `reusable` `shared-dma-pool` is CMA and `CONFIG_CMA` was not set.
Enabling `CONFIG_CMA` and `CONFIG_DMA_CMA` fixes that, and the region is now
placed and handed over as intended:

```
OF: reserved mem: initialized node fastrpc-shared-pool, compatible id shared-dma-pool
OF: reserved mem: 0x00000000fee00000..0x00000000ffdfffff (16384 KiB) map reusable
qcom,fastrpc ...fastrpcglink-apps-dsp: assigned reserved memory node fastrpc-shared-pool
```

The pool sits at `0xfee00000`, comfortably below 4 GB.

**The attach still fails.** Same stream `0x5a1`, same `sensor_process` crash,
same `PC`, and `FSYNR0` reporting `PLVL=1` so nothing is mapped at the target at
all.

The fault address is *not* constant, which corrects a conclusion recorded here
earlier. Attaching plainly faults at `0x1fffff000`; attaching with the vendor's
`fastrpc_shell_2` supplied through `-c` faults at `0x1ff7ff040` instead. Both sit
just under 8 GB, so the DSP is reaching into the top of a large aperture rather
than at one fixed sentinel.

That is not the host allocator's doing either: `fastrpc.c` already sets a 32-bit
DMA mask on both the context banks and the rpmsg device, so anything Linux hands
out stays below 4 GB. Whatever the sensor process dereferences up there, it is
computing itself.

The pool change is kept regardless. The kernel asks for that region, the stock
describes it, and `assigned reserved memory node` is the correct state rather
than the informational complaint that preceded it.

## Where to look next

The fault addresses are the lead. Both land just under 8 GB, and they move with
what the host does, so the question is what the sensor process computes up there
and who maps it on the stock system. The 32-bit DMA mask the driver already sets
means it is not simply Linux handing out an unreachable buffer.

The vendor's SLPI userspace is now staged on the handset at
`/usr/share/qcom/sdsp`, copied from the `dsp` partition, so `-c` and `-R` can be
pointed at it without remounting anything.

The vendor's own SLPI userspace is on the handset, in the `dsp` partition under
`sdsp`: `fastrpc_shell_2`, `libchre_slpi_skel.so`, and the CHRE drivers. The
sensor registry that the stock sensor stack reads is a separate matter and lives
in the vendor partition.
