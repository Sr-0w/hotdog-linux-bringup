# R6 UFS state probe

This temporary out-of-tree module captures a read-only SM8150 UFS reference
from the known-working Linux 4.14 R6 rescue kernel. It records the controller
revision and state, a bounded set of host and QMP PHY registers, and local
UniPro attributes needed to compare the downstream configuration with the
direct-mainline path. It is a diagnostic aid, not a runtime dependency.

The probe deliberately uses the native UFS clock-gating API:

1. locate the live `1d84000.ufshc` platform device;
2. obtain its `ufs_hba` driver data;
3. call `ufshcd_hold()`;
4. read only a fixed whitelist of host and PHY registers;
5. issue local `DME_GET` commands through the serialized UFS core API;
6. call `ufshcd_release()`.

Do not replace this sequence with raw `ioremap()` reads. A read-only direct
access to the clock-gated host window stopped the rescue kernel before the
first register value could be printed.

Build against the exact configured R6 kernel tree:

```sh
make -C /path/to/r6-kernel \
    O=/path/to/exact-r6-build-output \
    ARCH=arm64 LLVM=1 LLVM_IAS=1 \
    CROSS_COMPILE=aarch64-linux-gnu- LOCALVERSION= \
    M="$PWD/helpers/r6-ufs-regdump" modules
```

The captured R6 image reports `4.14.357-openela-perf`. Disable
`CONFIG_LOCALVERSION_AUTO` in the module build output before `prepare`; an
otherwise identical build appends the Git revision and will be rejected by
the running kernel. Verify both the release and symbol versions before loading:

```sh
modinfo -F vermagic helpers/r6-ufs-regdump/hotdog_r6_ufs_regdump.ko
modprobe --dump-modversions \
    helpers/r6-ufs-regdump/hotdog_r6_ufs_regdump.ko
```
