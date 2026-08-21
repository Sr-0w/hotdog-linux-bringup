# `reboot bootloader` returns to the OS because PM8150 declares no reboot modes

Date: 2026-08-21

This is the S65 blocker, and it is one missing device-tree property.

## What S65 hit

Two remote attempts to reach fastboot issued `LINUX_REBOOT_CMD_RESTART2`
with `bootloader`, and both times the phone rebooted straight back into
postmarketOS with a new boot id and working SSH. No fastboot serial appeared
within 120 s on either `18d1:d001` or `18d1:d00d`. The flash never started,
`boot_b` was never touched, and the readback still matched the rollback
`d881abaf…`.

## Why

On Qualcomm the reboot reason is a value the kernel leaves in the PMIC before
resetting, and the bootloader reads it. Mainline does this through
`drivers/power/reset/qcom-pon.c`, which is bound on this phone:

```
/sys/bus/platform/drivers/pm8916-pon/c440000.spmi:pmic@0:pon@800
```

The driver takes a per-compatible shift, then registers with the generic
reboot-mode framework:

```c
{ .compatible = "qcom,pm8998-pon", .data = (void *)GEN2_REASON_SHIFT },   /* 1 */
...
regmap_update_bits(..., pon->baseaddr + PON_SOFT_RB_SPARE,   /* 0x8f */
                   GENMASK(7, pon->reason_shift),
                   magic << pon->reason_shift);
```

and `reboot_mode_register()` builds its table **from the device tree**, taking
every property whose name begins with `mode-`. `pm8150.dtsi` has none:

```dts
pon: pon@800 {
        compatible = "qcom,pm8998-pon";
        reg = <0x0800>;
        /* no mode-bootloader, no mode-recovery */
```

So the table is empty, no magic is ever written, `PON_SOFT_RB_SPARE` stays at
zero, and the bootloader sees a normal boot. Read live from the phone through
regmap debugfs, with the reboot pending:

```
/sys/kernel/debug/regmap/0-00/registers
  088f: 00
```

Every other mainline PMIC using the same compatible carries the properties —
`pm6125.dtsi`, `pm6150.dtsi`, `pm6350.dtsi`, `pm660.dtsi`, `pm8998.dtsi` all
have `mode-bootloader = <0x2>` and `mode-recovery = <0x1>`. `pm8150.dtsi` is
the only one without them.

## The fix

```dts
pon: pon@800 {
        compatible = "qcom,pm8998-pon";
        reg = <0x0800>;
        mode-bootloader = <0x2>;
        mode-recovery = <0x1>;
```

Compiled and verified in the hotdog DTB:

```
pon@800 {
        compatible = "qcom,pm8998-pon";
        reg = <0x800>;
        mode-bootloader = <0x02>;
        mode-recovery = <0x01>;
```

The values are the ones every other board uses, and they match the downstream
`PON_RESTART_REASON_BOOTLOADER = 0x02` / `_RECOVERY = 0x01`. With
`GEN2_REASON_SHIFT` of 1 the driver writes `0x04` into `0x88f` under mask
`0xfe`.

## There is no userspace shortcut

Setting the register by hand would have unblocked the hardware path without a
flash, so it was checked. It cannot be done on this build:

```
-r--------  /sys/kernel/debug/regmap/0-00/registers
```

The regmap debugfs node is read-only because `CONFIG_REGMAP_ALLOW_WRITE_DEBUGFS`
is off, and there is no `/sys/kernel/debug/spmi`. Reading works — that is how
`088f: 00` above was obtained — but writing does not. The device-tree fix is
the only route.

## The ordering problem this creates

The fix ships in a boot image, and S65 wanted fastboot in order to flash a boot
image. That circle does not have to be closed with fastboot: `boot_b` is an
ordinary partition and the phone runs as root, so the image can be written from
the running system and the existing readback and rollback hashes still apply.

That is a destructive write to the partition the phone boots from, so it is a
decision for the lease protocol rather than something to do in passing. Noting
it here so the next lease does not plan around a fastboot gate it cannot reach.

## Where the fix was placed, and what it costs

Two trees carry it now, both as the same two-line change:

- `build/2026-08-14-smb5-dwc3-icl-src`, commit `37ded7e3c731`, the tree the
  current baseline is built from;
- `hotdog-r6-rebaseline-sensors-slpi-kernel-v1` on
  `bringup/sensors-slpi-kernel-v1`, commit `ae4fb94f7746`, whose parent is
  `b7b59cea4027` — the exact PDR base that the S63 composition was built on.

So a fresh composition off that branch picks the fix up with no further action.
The S63 build output was deliberately not touched: `source-composed-v2` still
reads `fcd868bc8099` with a clean tree, and every payload hash recorded by the
S64 audit stands.

The cost is honest: this changes the DTB, so folding it into the sensor line
means an S66 rebuild rather than the documentation-only microfix S64 called
for. The trade is one rebuild against needing physical bootloader entry for
every flash cycle from here on, and the remote ETM work will take several
cycles.

## What this does not solve

The first flash. The fix travels inside a boot image, so it only takes effect
once that image is running. Getting S63 or S66 onto the phone the first time
still needs either physical bootloader entry, or a write to `boot_b` from the
running system — which the phone permits, being root with the partition
exposed, and which the existing readback and rollback hashes already cover.
That first write is a protocol decision, not a technical obstacle.

## What an S66 actually costs, measured

The fix was applied to a scratch copy of the S63 `source-composed-v2` and the
hotdog device tree rebuilt from it, then compared against the S63 artifact
node for node. Normalising away `phandle` values and the `__symbols__` block —
their build emits symbols, a plain `dtc` run does not — the delta is:

```
> mode-bootloader = <0x02>;
> mode-recovery = <0x01>;
   total additions: 2
   real removals:   0
```

and the remote-ETM node is untouched:

```
compatible = "qcom,coresight-remote-etm";
qcom,remote-pid = <0x03>;
```

So an S66 is S63 plus two device-tree properties and nothing else. Note the
byte-level hashes will differ from this scratch build (`3698a557…` against the
S63 `9fa1971c…`) purely because of the symbol table; a rebuild through the
normal pipeline is what produces the comparable artifact.

Scope of a rebuild, since only the device tree moved:

- **unchanged**, hashes carry over from S63: `Image` `4e788900…`,
  `System.map` `26def628…`, `config` `74767448…`, both modules, and the whole
  rootfs `pmOS_root` `4cecfb95…`;
- **changed**: the DTB, the raw and AVB boot images, `pmOS_boot` (p1 carries
  copies of boot.img and the DTB), and therefore `full.img`.

The kernel itself does not need recompiling — `kernel-out` from S63 is intact
and only `dtbs` has to be remade.
