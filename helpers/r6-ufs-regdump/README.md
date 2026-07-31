# R6 UFS revision probe

This temporary out-of-tree module reads the SM8150 UFS controller revision
from the known-working Linux 4.14 R6 rescue kernel. It is a diagnostic aid for
matching downstream QMP calibration tables to the mainline driver; it is not a
runtime dependency.

The probe deliberately uses the native UFS clock-gating API:

1. locate the live `1d84000.ufshc` platform device;
2. obtain its `ufs_hba` driver data;
3. call `ufshcd_hold()`;
4. read only `REG_UFS_HW_VERSION`;
5. call `ufshcd_release()`.

Do not replace this sequence with raw `ioremap()` reads. A read-only direct
access to the clock-gated host window stopped the rescue kernel before the
first register value could be printed.

Build against the exact configured R6 kernel tree:

```sh
make -C /path/to/r6-kernel \
    O=/path/to/exact-r6-build-output \
    ARCH=arm64 LLVM=1 \
    M="$PWD/helpers/r6-ufs-regdump" modules
```

The resulting module must have the same vermagic and symbol CRCs as the
running R6 image before it is loaded.
