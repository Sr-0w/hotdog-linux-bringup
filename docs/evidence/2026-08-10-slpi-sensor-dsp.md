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

## Correction: hexagonrpcd was never exiting

Every earlier note in this file that says `hexagonrpcd` exits is wrong, and the
mistake was mine rather than the program's. I launched it as
`nohup ... &` inside `sudo sh -c` over SSH, so it died with the session, and
the PID check afterwards reported it gone. Run in the foreground it behaves
correctly:

```
timeout 90 hexagonrpcd -f /dev/fastrpc-sdsp -R /usr/share/qcom/sm8150/oneplus/hotdog -s
exit code 143, 1092 RPC calls
```

143 is SIGTERM, which is the timeout I imposed. It served the domain for the
full ninety seconds and was still going.

So the host side is finished: the heap is assigned, the domain attaches, the
registry is served and the conversation runs indefinitely. The refused write of
`sns_reg_version` and the unmapped `/proc/oppoVersion` node are both tolerated;
the DSP retries and carries on.

Note that a listener can only be registered once per DSP boot. A second
`hexagonrpcd` on the same boot fails with `Could not register ADSP default
listener` and does nothing useful, so each experiment needs a reboot. The SLPI
also refuses to stop and restart through sysfs, timing out and leaving itself
offline, so rebooting the handset is the only clean reset.

## Why no IIO devices appear, and what that changes

No sensor surfaces in `/sys/bus/iio` despite all of the above, and the reason
is structural rather than a bug. The stock device tree describes no sensors at
all: not by name, and not as children of the SLPI's own I2C buses at
`0x2680000` through `0x268c000`, which are empty. The DSP learns its parts from
the registry instead, which is why the registry names `bmi26x_0` and
`ak0991x_0` while the device tree names nothing.

That leaves two routes, and they are quite different in size.

Bridging the DSP's sensor service to userspace keeps the parts where the vendor
put them, but needs a client speaking the SSC protocol, which does not exist in
this stack.

Taking the sensors away from the DSP means describing the SLPI's QUPv3 wrapper
on the application processor, giving it the sensors' addresses out of the
registry, and using the mainline IIO drivers that already exist for these
parts. This is what sibling devices do: on sdm845 handsets the IMU is a plain
I2C device with a mainline driver, and `hexagonrpcd` is there for other
reasons.

The second route also puts the sensor clock controller back in scope, with the
difference that matters: if the AP owns that bus then powering and clocking it
is legitimately the AP's job, which it was not when I first wrote that driver.
The driver is still in `work/scc-sm8150/`.

## Route (a): bridging the sensor service, first findings

Taking the DSP's sensors to userspace means talking to the sensor service the
SLPI exposes, and the first question is whether it registers at all.

`qrtr-lookup` is not packaged here, so `helpers/qrtr-services.py` asks the name
server directly. Two details cost time and are worth recording: Python knows
`AF_QIPCRTR` but cannot marshal its addresses, so the socket calls go through
ctypes with a hand-built `sockaddr_qrtr`; and `bind()` rejects a node of zero,
because the kernel requires the caller's own node id. Here that is node 1.

With the domain attached and `hexagonrpcd` serving, the bus answers but lists
nothing:

```
local node 1 port 16398
total: 0
```

Probing nodes directly with `qmicli` shows which exist: node 0 is the modem and
answers `--dms-get-ids` with the IMEI, nodes 1 and 5 exist but carry no DMS,
and 2, 3, 4 and 6 are absent.

Two things are missing on the host that would explain an empty registry:

- no name server process is running
- `pd-mapper` is in the failed state

`pd-mapper` matters directly. It serves the protection-domain lookups that
subsystem services use to find each other, and the sensor service is exactly
the kind of client that needs it. Getting it running is the next step, before
any conclusion about whether the SLPI publishes a sensor service at all.

## The sensor service is published

The empty service list had two causes on the host, and both are fixable.

`pd-mapper` was failing with `no pd maps available`. It needs the protection
domain maps, and they are not in the vendor image; they live on the stock
`modem` partition, which is still on the handset:

```
/mnt/modemfw/image/  adspr.jsn adspua.jsn cdspr.jsn modemr.jsn modemuw.jsn
                     slpir.jsn slpius.jsn
```

`slpir.jsn` and `slpius.jsn` are the SLPI's. Installed alongside the firmware
in `/lib/firmware/qcom/sm8150/oneplus/hotdog/`, `pd-mapper` starts and stays
up.

The second was simpler: no name server. The `qrtr` package was not installed,
which is also why `qrtr-lookup` was missing and why the helper written to
replace it saw nothing. `sendto` succeeded and no reply ever came because
there was nothing to reply.

With both in place the bus lists services across three nodes, and the one that
matters is there:

```
Service Version Instance Node Port
    400       1        0    9   12   Snapdragon Sensor Core service
```

Node 0 is the modem with its usual thirty-odd services, node 5 carries SLIMbus
and thermal, and node 9 is the sensor core.

So the DSP is up, attached, served its registry, and publishing the service its
sensors live behind. What remains for this route is a client that speaks it:
subscribe to the sensors over QMI service 400 and present them to Linux.

## A client for the sensor service

`helpers/ssc-client.py` speaks to service 400. It finds the service through
`qrtr-lookup`, binds an `AF_QIPCRTR` socket, and sends a QMI request carrying a
protobuf `sns_client_request_msg`, which is how this service works: QMI
envelope, protobuf payload.

The transport is proven. A request reaches the sensor core and it answers:

```
sensor core at node 9 port 12
bound to node 1 port 16399
sent 52 bytes asking for 'accel'
reply txn=1 msg=0x0020 tlvs={2: 4}
  result: failure, error 19
```

That is a well-formed QMI response to our transaction, so the socket, the
addressing, the envelope and the service are all correct. What the service
rejects is the content.

The request is a SUID lookup: ask the well-known lookup sensor for the
identifiers of sensors providing a named data type, then subscribe to those.
It is encoded as `sns_client_request_msg { suid, msg_id = 512, request }` with
the payload nested inside `sns_std_request` alongside a suspend config. An
earlier version put the payload beside that structure rather than inside it,
which was wrong and is fixed; the error did not change, so the nesting was not
the cause.

Error 19 is what remains to explain. Worth checking next, in rough order of
likelihood: whether the lookup SUID constant is right for this generation,
whether the service expects the client to register before issuing requests, and
whether `sns_suid_req` on this version requires the `default_only` field that
is currently omitted.

The helper is small and readable, and every layer below the protobuf content is
verified working, so this is a question of getting one message right rather
than of building a stack.

## Error 19 fixed: the payload is a counted array

`QMI_ERR_ARG_TOO_LONG`. The payload in `sns_client_req_msg_v01` is a
variable-length array, so the QMI encoding puts a `uint16` count inside the
TLV before the bytes. The client was writing the protobuf straight into the
TLV value, so the service read the head of the protobuf as that count:

```
0a 14 ...   ->  0x140a = 5130, against a maximum of 1000
```

Which is exactly what it complained about. With the count prefix the service
accepts the request:

```
reply txn=1 msg=0x0020 tlvs={2: 4, 16: 8, 17: 4}
  result: ok, error 0
  tlv 0x10: 1701000000000000     client id
  tlv 0x11: 00000000
```

The client id increments across runs, so the front end is alive and allocating.

Two further corrections were made while chasing the missing answer, both real
even though neither changed the outcome. The listen loop treated a receive
timeout as the end of the conversation, so it only ever waited five seconds
when the answer to a lookup arrives asynchronously as an indication. And
`sns_std_suspend_config.client_proc_type` was set to 1, which is the SSC
itself; APSS is 0, and asking as the SSC would have had any answer delivered
to the DSP rather than to us.

## Where it stops, measured rather than guessed

No indication ever arrives. Counting FastRPC traffic across a request says why
it is not worth looking for one:

```
calls before: 1092
calls after:  1092   delta 0
```

The sensor domain is alive and working on this boot, having made those 1092
calls reading its registry, and `hexagonrpcd` is still serving. But a request
that the QMI front end accepts produces no DSP activity at all.

So the message is well-formed enough for QMI and does not reach the sensor
logic behind it. The front end lives in the SLPI's root protection domain and
the sensors live in the sensor domain, and something between the two is not
carrying this request.

What to establish next, in order: whether the lookup SUID constant
(0xABABABABABABABAB twice) is right for this generation, since a wrong SUID
would be silently dropped exactly like this; and whether the service expects
a registration or handshake message before it will route requests to a
domain.

## What is eliminated, and a correction to my own reasoning

The lookup SUID is right. `libsns_api.so`, pulled out of the stock vendor
image, carries exactly sixteen bytes of `0xAB` at offset 10400 and exports
`sns_suid_sensor_suid_low_default` and `sns_suid_sensor_suid_high_default`.
The constant this client uses is the one the vendor library uses.

The target is right. `qrtr-lookup` shows exactly one registration of service
400, instance 0 on node 9 port 12, and that is what the client addresses.
Instance 90 in the protection domain maps belongs to the service registry
notification service, not to the sensor core.

The framing is right. The service answers with a well-formed response, and
dumping every byte that arrives on the socket over twenty-five seconds shows
that response and nothing else:

```
<- 32 octets: 0201002000190002040000000000100800190100000000000011040000000000
   type 2 (response), txn 1, msg 0x0020
   result ok, client id 0x119
```

And a correction. An earlier note here counted FastRPC invocations across a
request, found no change, and concluded the sensor logic never saw the
message. That measurement was worthless for the question: the instrumentation
counts `fastrpc_invoke_send`, and the sensor QMI path runs over GLINK and
QRTR, not FastRPC. Those counters were never going to move. The conclusion
drawn from it should be disregarded.

## The likeliest remaining cause, and it reopens something closed

The QMI front end accepts requests and allocates client ids, but no sensor
answers a lookup. The simplest explanation left is that the sensor framework
never finished starting, and there is a candidate reason already recorded in
this file and wrongly dismissed:

```
Tried to open /persist/sensors/registry/registry/../sns_reg_version for writing
```

`hexagonrpcd` serves read-only and refuses that write, and the DSP retries it
forever. It was noted as tolerated because nothing crashed. Tolerated is not
the same as harmless: if the framework cannot stamp its registry version it
may never declare itself initialised, which would leave exactly this
signature, a live service with no sensors behind it.

So write support in `hexagonrpcd` is back on the list, and it is a real piece
of work rather than a flag. `struct hexagonfs_file_ops` has no write
operation at all, `apps_std_fopen_with_env` rejects the `w` and `a` modes
outright, and the `apps_std` method table has no `fwrite` entry, so the
interface definition for it has to be established as well.

## The file server is now complete enough for registry regeneration

The missing file operations were implemented in stages. `hexagonrpcd` now
accepts registry payload writes, creates files and directories, removes stale
files, renames temporary files into place and serves every requested file. The
relevant project commits are:

```
e1d5b3b hexagonrpcd: support DSP registry renames
7ade110 hexagonrpcd: accept sensor registry payloads
3d14a02 hexagonrpcd: implement DSP file removal
cc5bd07 hexagonrpcd: create files, and serve every request
```

Starting from an empty generated registry produced 438 files, 1,169 writes and
65 renames. This closes the earlier hypothesis that a read-only registry kept
the framework from initialising. It does not: after successful regeneration,
the SSC still returns only infrastructure SUIDs (`suid`, `registry`, `timer`,
`interrupt`, `async_com_port`, `resampler`, and `diag_sensor`). Requests for
`accel`, `gyro`, `mag`, `proximity`, `ambient_light`, `pressure`,
`sensor_temperature`, and `dae` return no physical SUID.

The selected stock descriptions identify the handset parts and transports:

| Part | Function | Transport |
| --- | --- | --- |
| LSM6DSM | accelerometer and gyroscope | SPI instance 2, 9.6 MHz, IRQ 132 |
| MMC5603x | magnetometer | I2C instance 1, address `0x30`, 400 kHz |
| TCS3701 | ambient light and proximity | I2C instance 3, address `0x39`, IRQ 117 |

The generated files preserve those values. The stock configuration directory
also contains descriptions for many parts not fitted to hotdog, so a NACK from
an arbitrary probe is not by itself evidence that one of these three devices
failed.

## QDSSC tracing is present but detailed entities are disabled

The SLPI publishes Qualcomm Debug Subsystem Control as QMI service 51 for both
the sensor root and user protection domains. `helpers/qdssc-client.py` queries
these endpoints and defaults to read-only operation. Global software tracing
can be enabled, but this firmware returns QMI error 94 (`NOT_SUPPORTED`) for
the detailed TDS, ULog, profiling, and DIAG entity controls. The encoding was
checked against Qualcomm's generated service source: entity id and state are
both four-byte TLVs, so error 94 is a firmware response rather than a malformed
request.

CoreSight ETR and STM were also armed. The resulting 80-byte trace contained
only the empty-stream barrier and no sensor data. This path therefore cannot
explain the missing physical SUIDs on this firmware build.

## A controlled SLPI coredump exposes the firmware's own ULogs

Triggering the SLPI watchdog produced a complete 20-segment ELF32 remoteproc
coredump while the main Linux kernel remained alive:

```
logs/2026-08-13-sensors-registry-regeneration/03-slpi-devcoredump.elf
size:   20,885,487 bytes
sha256: 72766b3659e2212034b1d6b6edb05abc354b483daf74000d5d8defecc0ce2cf6
```

Releasing the devcoredump caused the existing recovery policy to reboot the
handset. It returned on the same `#177-smb5-v3-ba989060` kernel and republished
SSC service 400, so the capture did not leave the SLPI or phone damaged.

`helpers/slpi-ulog-coredump.py` parses the ELF load segments, locates Qualcomm
ULog v4 headers, reconstructs wrapped RAM rings, and decodes printf records. It
does not guess image relocations: they must be supplied explicitly. The capture
contains 51 valid logs, including `I2C`, `I2C_error`, `SPI`, `SPI_error`,
`gpi_err`, and `PMIC Log`. Reproduction commands are:

```sh
helpers/slpi-ulog-coredump.py DUMP --list
helpers/slpi-ulog-coredump.py DUMP --log I2C \
  --relocation I2C=0x185c5000
helpers/slpi-ulog-coredump.py DUMP --log I2C_error \
  --relocation I2C_error=0x185c5000
helpers/slpi-ulog-coredump.py DUMP --log 'PMIC Log' \
  --relocation 'PMIC Log=0x18e00000'
```

The error ring records six failed transactions. Each consists of `ERROR nack`,
two `ERROR DMA EVT OTHER during data phase` callbacks, and a cancellation. The
first three use context `0xb0028f20`; the last three use `0xb0028f98`.

The PMIC ring establishes ordering that kernel logs could not show:

```
592345176 sensor_vddio MId=2
592433921 sensor_vdd   MId=2
594276495 first I2C NACK
594392710 sensor_vdd   MId=0
594653863 sensor_vddio MId=0
```

Both sensor rails are therefore requested and active well before the first
NACK. Missing regulator votes are eliminated as the immediate cause.

The surviving 4 KiB I2C ring contains the final probes at addresses `0x2c` and
`0x28`. It contains no confirmable transaction to the fitted MMC5603x at
`0x30` or TCS3701 at `0x39`; the much earlier startup traffic has rolled out of
the ring. The next capture must happen immediately after the sensor process
starts, before those transactions are overwritten. Until that capture exists,
the NACKs must not be attributed to any fitted hotdog sensor.

## OxygenOS 10 firmware reproduces the same transport failure

The HD1913 OxygenOS 10.0.13 EU unbrick image was decrypted locally and its
`NON-HLOS.bin` sparse FAT image extracted. Reassembling `slpi.mdt` and
`slpi.b00` through `slpi.b20` at their ELF program-header offsets produced:

```
source NON-HLOS.bin sha256:
7920f87d8544d17efbe93ec9d7365190a43016eb9d286b1361de5fc96ca6a7b9

reassembled slpi-oos10.0.13.mbn:
size:   6,263,044 bytes
sha256: 1b17eb7bd003af9092e074645d88b92474a1cf3c2ad97356bdd3b36430c8e249
image:  SLPI.HY.2.2-00083-SM8150AZL-1
```

This is a genuinely different image from the firmware normally used by the
port (`SLPI.HY.2.2-00121-SM8150AZL-1`, sha256
`2022ea3bebe093b8910ad2369b3cf339214ebc2709cd852bcd5c58d39fb2cc26`).
It was installed only for a controlled remoteproc restart. The old image
booted, then its sensor process watchdog fired during initialisation with:

```
qmi_decode_string_elem: String len 128 >= Max Len 65
USER-PD DOG detects stalled initialization, triage with IMAGE OWNER
```

Its coredump is preserved locally:

```
logs/2026-08-13-sensors-slpi-oos10-comparison/01-slpi-oos10-stalled-init.elf
size:   20,956,178 bytes
sha256: 4b6afcb4a2c980688d6a325986e75145d6e54f9f4311b243666eb45c1fccf038
```

Most importantly, the OxygenOS 10 ULogs reproduce the same failures as the
newer firmware:

```
npa_create_sync_client("/icb/arbiter", "I2C_QUP_DDR", NPA_CLIENT_VECTOR)
FAILED ... resource "/icb/arbiter" failed client create (error: 4)
npa_create_sync_client("/icb/arbiter", "SPI_QUP_DDR", NPA_CLIENT_VECTOR)
FAILED ... resource "/icb/arbiter" failed client create (error: 4)
spi_plat_init: npa_create_sync_client_ex failed
```

The original firmware was restored and its hash rechecked before restarting
the SLPI. Firmware-version mismatch is therefore eliminated: the missing
condition is in the platform environment presented to both firmware builds.

## Mainline drops the SLPI proxy power votes

The downstream SM8150 SLPI node describes `vdd_cx` and `vdd_mx` and sets
`qcom,keep-proxy-regs-on`. Mainline represents the same resources as the `lcx`
and `lmx` RPMh power domains, but the generic PAS handover callback releases
all proxy power domains. Runtime evidence on the validated `#177` kernel makes
the mismatch visible:

```
/sys/class/remoteproc/remoteproc0/state: running

/sys/kernel/debug/pm_genpd/pm_genpd_summary:
lcx  off-0   genpd:0:2400000.remoteproc suspended
lmx  off-0   genpd:1:2400000.remoteproc suspended
```

An isolated diagnostic kept the SM8150 SLPI `lcx`/`lmx` votes after handover
and released them on remoteproc stop. It was built on the exact validated SMB5
v3 source tree as `#178-slpi-pds-r176`:

```
Image sha256:
ed2fb2f5e116b28a3c4fedded7e5a0eea2b1b661d051f16dd4ec039b0185de02

AVB boot image sha256:
b7d32ecbebf3878548f5beadff08ba4fb470e3c0e8b80425dee9aa53b7c9ed32
```

The phone booted normally and the intended runtime state was confirmed:

```
lcx  on   genpd:0:2400000.remoteproc active
lmx  on   genpd:1:2400000.remoteproc active
```

SSC service 400 still returned no SUID for `accel`, `gyro`, `mag`,
`proximity`, `ambient_light`, `pressure`, `sensor_temperature`, or `dae`.
A 20,885,487-byte coredump was captured with sha256
`7e45ca33719fd6fd9715608f54f8c77fcfb865b7c2fe9ab9864a55f7b23c712f`.
Its retained transport rings still contain the six known I2C NACK sequences,
but the early NPA client-creation records had already rolled out. Releasing
the dump left SLPI offline, and its attempted recovery timed out while the
rest of Linux remained reachable.

The diagnostic therefore failed its hardware gate and was removed from the
shipped patch series. The handset was restored to the exact validated
`#177-smb5-v3-ba989060` image (sha256
`7ac65591ecda2adf00efb3a35134ef6872a0cf044c73698a1b6785532ecf6e6d`),
with SLPI running again. Host-side proxy-domain retention is not the missing
condition that makes the physical sensor drivers publish their SUIDs.

## Current boundary

The host and DSP plumbing is now validated end to end: firmware boot, FastRPC,
the writable file server, registry regeneration, QRTR, SSC requests and ULog
forensics all work. Physical sensors remain **not working** because their
drivers do not publish SUIDs. Firmware-version mismatch, missing sensor-rail
votes, and dropped host proxy-domain votes are ruled out. The next work must
identify why the SLPI-side `/icb/arbiter` rejects the I2C and SPI QUP clients,
then repeat the early coredump and physical-SUID gate.

## The rejected ICB routes are now identified exactly

The ICB implementation source establishes that client-creation error `4` is
`ICBARB_ERROR_NO_ROUTE_TO_SLAVE`: `ul_get_route()` returned no route for at
least one requested master/slave pair. This is not a generic allocation or
initialisation error.

Reverse engineering the two callers in the captured sensor user PD locates
their constant 16-byte route vectors. I2C and SPI both pass the same two
`ICBArb_MasterSlaveType` entries:

```
master 0x29 -> slave 0
master 0x27 -> slave 0
```

The Qualcomm ICB ABI maps these values to:

```
ICBID_MASTER_QUP_1 -> ICBID_SLAVE_EBI1
ICBID_MASTER_QUP_2 -> ICBID_SLAVE_EBI1
```

So both serial transports fail to acquire their QUP-to-DDR paths. The two
independent firmware versions request identical routes and fail identically.
The next discriminating control is to run the current firmware and sensor
userspace on the known downstream 4.14 kernel and stock DTBO. A success there
would isolate a host-kernel/platform difference; the same rejection there
would move the investigation back inside the DSP configuration rather than
mainline.
