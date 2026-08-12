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

## Attaching the sensors PD, reproduced exactly (r160)

`hexagonrpcd` is packaged and installed, the SLPI firmware is in place, and the
DSP's own files are served: `/usr/share/qcom/sdsp` holds 17 of them, including
`fastrpc_shell_2` and `map_SSC_SLPI_USER_AAAAAAAAQ.txt`. All three remote
processors are running, and `/dev/fastrpc-sdsp` exists.

Attaching still kills the DSP, reproducibly and identically whether the file
root is left at its default or pointed at `/usr/share/qcom/sdsp`:

```
Starting hexagonrpcd (INIT_ATTACH_SNS) on /dev/fastrpc-sdsp
Could not attach to FastRPC node: Broken pipe
```

The kernel shows what happens on the far side, in this order:

```
arm-smmu 15000000.iommu: Unhandled context fault: fsr=0x402, iova=0x1fffff000,
                         fsynr=0x330001, cbfrsynra=0x5a1, cb=11
arm-smmu 15000000.iommu: FSR = [Format=2 TF], SID=0x5a1
PDM: service 'sensor_process' crash: 'EX:sensor_process:0x1:frpck_0_0:0x58:PC=0xb218da68'
qcom_q6v5_pas 2400000.remoteproc: fatal error received
remoteproc remoteproc0: handling crash #1 in slpi
```

The SMMU fault comes first and the process crash follows, so the DSP is the
one making an unmapped access, not the host. `SID=0x5a1` is `compute-cb@1`,
the first FastRPC context bank, and `frpck_0_0` places the fault inside the
handling of the very FastRPC packet that `INIT_ATTACH_SNS` sends. The
`sensor_process` service therefore exists and is reached; it faults while
servicing the attach.

The host side of that attach carries almost nothing. `fastrpc_init_attach()`
sends a single 4-byte `client_id` to `FASTRPC_INIT_HANDLE` and maps no
buffers, which means the address the DSP reaches for is not one the host just
handed it. It is an address the DSP expects to already be mapped.

That is the useful part of the signature. `0x1fffff000` is the last page below
8 GB, and the FastRPC pool this board reserves caps its `alloc-ranges` at
`0xffffffff`, so nothing the driver can allocate ever lands in that context
bank at that address. The description is missing a region the DSP takes for
granted rather than getting a mapping wrong.

The node itself is otherwise correct: `qcom,non-secure-domain` is set, a
`memory-region` is attached, and the three context banks carry SIDs 0x5a1
through 0x5a3.

### Next

Find the reservation the stock tree makes for SLPI. The downstream kernel is
not in this checkout, so this needs the OxygenOS device tree or the downstream
source, and the specific question is which reserved region backs the sensors
PD and where it sits. Everything else on the path is confirmed working.

### The reserved-memory map is not the cause

The FastRPC pool caps its `alloc-ranges` at 4 GB while the fault lands at
`0x1fffff000`, which made the reservations the obvious suspect. They are
correct.

The node names in the generated tree are misleading and cost me a wrong first
reading: `memory@97300000` is the SLPI carveout, but its `reg` places it at
`0x98100000` for 20 MB, which is exactly stock's `pil_slpi_region`. The same
holds across the window, `memory@96e00000` sitting at stock's
`pil_video_region` address. Comparing the live stock device tree region by
region, the reservations match.

So the DSP is not being handed a differently placed carveout. The fault is in
what the attach packet points at, not in where the firmware lives.

## The fault address, measured (r167 and r168)

Instrumenting the invoke path settled it in one boot. `fastrpc_buf_alloc()`
folds the session identifier into the buffer address:

```c
buf->phys += ((u64)fl->sctx->sid << 32);
```

and `fastrpc_invoke_send()` passes that value to the DSP as `msg->addr`. The
identifier comes from the `reg` property of the context bank node, so
`compute-cb@1` gives sid 1. The trace shows exactly what that produces:

```
buffer dma 0xfffff000 size 0x204, sid 1
invoke handle 1 sc 0x10000 pd 2 sid 1 addr 0x1fffff000 size 0x1000
arm-smmu: Unhandled context fault: iova=0x1fffff000, SID=0x5a1
```

The buffer is mapped at `0xfffff000`. The host sends `0x1fffff000`. The DSP
uses that verbatim, so it reaches for an address one bit above the mapping.
The transaction arrives in the right context bank, which is why only the
folded identifier is wrong rather than the session.

Sending the address that is actually mapped, for the sensors domain only,
removes the fault entirely. r168 shows the invoke at `0xfffff000` with no
context fault and no `sensor_process` crash following it, where every previous
run faulted within microseconds.

The handset still resets shortly afterwards and the console log ends on
unrelated DPU frame-done timeouts, so the cause of that reset is not captured
and is the next thing to chase. But the SMMU fault that had blocked every
attempt since this file was started is gone.

## Three addresses, one stall: the fault was a symptom, not the cause

Two more runs turned the diagnosis around. Feeding the sensors domain an
address it can genuinely reach does not fix anything; it makes things worse.

| Address sent | Outcome |
| --- | --- |
| `0x1fffff000`, the IOVA with the session id folded in | clean SMMU translation fault, `sensor_process` crashes, SLPI recovers, handset survives |
| `0xfffff000`, the IOVA that is actually mapped | no fault at all, interconnect stalls, watchdog resets the SoC |
| `0xfee00000`, the base of the reserved pool | no fault at all, interconnect stalls, watchdog resets the SoC |

In both of the working-address cases the console records the invoke, then DPU
frame-done timeouts within 50 to 900 ms, then nothing. The display stalling is
the visible edge of a bus that has stopped answering, and no translation fault
is reported because the access the DSP makes is legal.

So the SMMU fault that this file has chased from the start was never the
blocker. It was the DSP being stopped early, before it could do the thing that
actually hangs the machine. Correcting the address lets it proceed, and what
it does next is what needs finding.

That reframes the search. The question is no longer where the message buffer
lives. It is what the sensor protection domain touches once it starts, and the
candidates are the resources the SLPI owns rather than anything in FastRPC:
its own I2C buses, the sensor supply rails, and the clocks behind them, none
of which the mainline device tree describes yet.

Worth noting for whoever picks this up: the original faulting behaviour is the
safe one to experiment with, because the handset survives it. Both corrected
addresses require a reset to recover.

## What the protection domain reaches for: an undescribed clock controller

Following the reframing above, the question became what the sensor domain
touches once it starts. The stock device tree answers it.

The SLPI does not share the application processor's serial engines. It has its
own QUPv3 wrapper, `qcom,qupv3_3_geni_se@26c0000`, carrying serial engines 20
through 23 with their I2C buses at `0x2680000` and `0x268c000`, and its own
pin controller at `0x2b40000`. Mainline's `sm8150.dtsi` describes three QUPv3
wrappers, at `0x8c0000`, `0xac0000` and `0xcc0000`. It does not describe this
fourth one, nor the pin controller.

That alone is not the answer, because the stock node is `status = "disabled"`
too, with `qcom,subsys-name = "slpi"`: the AP leaves it alone on OxygenOS as
well, and the DSP drives it. What matters is what it is clocked from:

```
qcom,qupv3_3_geni_se@26c0000
	clock-names = "corex", "core2x";
	clocks = <&scc 4>, <&scc 3>;
```

and that provider is

```
qcom,scc@2b10000
	compatible = "qcom,scc-sm8150-v2";
	reg = <0x2b10000 0x30000>;
```

the sensor clock controller. Mainline has no driver for it and no node at that
address. `drivers/clk/qcom` carries `lpasscc` and `nsscc` variants, which are
different blocks entirely; there is no `scc` for any SoC.

This fits every observation. The access that stalls is a register write to a
peripheral, not a DMA transfer, which is why no translation fault is ever
reported. An unclocked block on the interconnect never returns, which is why
the bus stops answering and the display is the first thing to notice. And it
only happens once the message address is correct, because until then the DSP
faulted before reaching this point.

### The work

The downstream kernel carries `drivers/clk/qcom/scc-sm8150.c`, 745 lines
describing 25 clocks. That is the shape of the missing piece, and the same
approach that worked for IPA applies: take the register offsets and parent
topology, express them in mainline's `clk_regmap` idiom rather than
transcribing, and add the node.

Whether the AP must also describe the QUPv3 wrapper and pin controller is a
separate question to settle once the clocks exist. Stock disables both, which
suggests the clocks alone may be enough.

## The heap was never assigned to the DSP (r172)

The clock controller was a false trail. The answer was in the hypervisor, and
the downstream driver states it plainly. `adsprpc.c` assigns the FastRPC range
before the DSP may touch it:

```c
int srcVM[1]  = { VMID_HLOS };
int destVM[3] = { VMID_HLOS, VMID_SSC_Q6, VMID_ADSP_Q6 };
hyp_assign_phys(range.addr, range.size, srcVM, 1, destVM, destVMperm, 3);
```

Mainline reads the same thing from `qcom,vmids` and builds its `vmperms` with
RWX, but our node declared none, so `vmcount` was zero and no assignment ever
happened. The sensor domain held no rights over the heap at all.

That explains the signature exactly, including the part that never fit. A
hypervisor refusal is not a translation fault, so the SMMU reports nothing;
the transaction simply never completes, the interconnect stops answering, and
the watchdog resets the SoC. It also explains why correcting the address made
things worse: with a wrong address the DSP faulted early and harmlessly, and
with the right one it reached memory it had no permission to touch.

Adding `qcom,vmids = <0x3 0x5 0x6>` changes everything:

```
invoke handle 1   pd 2 sid 1 addr 0xfee00000
invoke handle 0   pd 2 sid 1 addr 0xfee00000
invoke handle 3   pd 2 sid 1 addr 0xfee01000
... dozens more
```

The attach completes and the protection domain holds a conversation. SLPI stays
`running` indefinitely where it previously died within four seconds. No SMMU
fault, no crash, no reset.

## What it asks for now

`hexagonrpcd` exits because the DSP requests files the host does not serve:

```
/mnt/vendor/persist/sensors/registry/sns_reg_config
/sys/devices/soc0/hw_platform
/sys/devices/soc0/platform_subtype
```

The first is the sensor registry from the stock `persist` partition, which is
still on the handset. The other two are SoC identification nodes that Android
exposes and mainline does not. Serving all three is what remains.

## Feeding the domain: 1092 calls

With the heap assigned, the remaining work is serving the DSP its files, and
the layout is a pmaports convention rather than something to derive. Sibling
devices state it in a `hexagonrpcd.confd`:

```
device-oneplus-fajita:  hexagonrpcd_fw_dir="/usr/share/qcom/sdm845/OnePlus/oneplus6"
device-xiaomi-elish:    hexagonrpcd_fw_dir="/usr/share/qcom/sm8250/xiaomi/elish/"
firmware-google-sargo:  /usr/share/qcom/sdm670/Google/sargo/sensors/registry
```

So the root is configured per device and passed as `-R`, with the DSP binaries
under `dsp/sdsp/` and the sensor registry under `sensors/registry`. I had been
passing the wrong root throughout.

The registry itself is on the handset, on the stock `persist` partition:
`/persist/sensors/registry/registry`, 438 entries. Reading it names the parts
this handset actually carries, `bmi26x_0` for the IMU and `ak0991x_0` for the
magnetometer.

Laid out correctly, the conversation goes from 42 calls to **1092**. The domain
attaches, reads its registry and works.

## The two things still in the way

```
Tried to open /persist/sensors/registry/registry/../sns_reg_version for writing
Could not open /proc/oppoVersion/modemType
```

The first is not a missing file. `hexagonrpcd` finds it and refuses, because it
serves read-only; the DSP wants to update the registry version and retries
forever. The second is an OPPO-specific proc node that the file service does
not map, and putting a copy under the served root does not satisfy it, so its
path handling differs from the registry's.

Both are `hexagonrpcd` questions rather than kernel ones, which is a much
better place to be than where this file started.

## Correction on the clock controller

The sensor clock controller was a false trail, and the evidence above supersedes
it. The block is disabled in the stock tree and the AP never drives it; what
was missing was the heap assignment, not a clock provider.
