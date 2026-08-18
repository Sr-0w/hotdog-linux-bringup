# The SD host sits in the modem's power domain

Date: 2026-08-18

## Summary

`sm8150.dtsi` puts `sdhc_2`, the SD card host, in power domain 0. On SM8150
that is `SM8150_MSS`, the modem subsystem. The SD host therefore votes
performance states on the modem's power domain and drops them when it
suspends, which is what has been killing the modem on nearly every suspend
cycle of this port.

Fixed by `arm64: dts: qcom: sm8150: put sdhc_2 in CX, not the modem's domain`.

## The defect

```dts
sdhc_2: mmc@8804000 {
        ...
        power-domains = <&rpmhpd 0>;
        operating-points-v2 = <&sdhc2_opp_table>;
```

```c
/* include/dt-bindings/power/qcom-rpmpd.h */
#define SM8150_MSS	0
#define SM8150_CX	7
```

Three things say this is a slip rather than a decision. Every other node in
`sm8150.dtsi` names its domain with a macro; only this one writes a bare `0`.
`sdhc_2` on sm8250 and sm8350 carries `RPMHPD_CX`. And the OPP table it points
at asks for `rpmhpd_opp_min_svs` upward, which are CX corners.

The wiring is visible in a running system:

```
mss                            off-0
    genpd:1:4080000.remoteproc     suspended
    8804000.mmc                    suspended
```

The SD host is sitting in `mss` next to the modem's own remoteproc.

The phone has no SD card slot, so nothing ever uses this controller. It still
probes, still attaches to the domain, and still runs its suspend callback.

## Measurement

`pm_test=devices`, configurations alternated one cycle for one, counting only
crashes whose SFR is the generic `Init: wdog or kernel error suspected` that
belongs to this defect:

| `sdhci_msm` on `8804000.mmc` | modem watchdog |
| --- | --- |
| bound | 6/10 |
| unbound | 0/10 |

Fisher exact p = 0.011.

It was reached by bisection, not by suspicion. A batch of ten devices picked
only for being safe to unbind gave 6/10 against 0/10, replicated at 4/10
against 0/10, pooled p = 0.0002. Splitting it cleared `i2c-qcom-cci` (3/4
against 4/4) and the six `geni_i2c` buses (2/6 against 3/6), leaving
`qcom-soundwire` and `sdhci_msm`, which together gave 5/6 against 0/6. The SD
host alone then reproduced the whole effect.

The SFR filter earned its place during these runs: it caught and excluded a
`err_qdi.c:1024:EF:wlan_process:WLAN` crash that would otherwise have been
counted as the defect.

## Why it fits everything else in the file

- The ADSP survives identical cycles. It is in `cx`, not `mss`.
- No AP-to-modem traffic is needed. Nothing is sent; a vote is withdrawn.
- `pm_test=freezer` is clean and `pm_test=devices` is not, because the vote is
  dropped by an ordinary `->suspend()` callback.
- No regulator, RPMh resource or interconnect path measured during
  `dpm_suspend` showed anything, because the change is a genpd performance
  state on `mss`, not a direct vote by the AP.
- The failure is probabilistic. Whether the modem dies depends on what it is
  doing when its domain corner drops, which is why rates swung between 0 and
  100 percent across sessions and why every small sample taken here misled.

## Verified on the phone

Flashed and booted. `pm_genpd_summary` now reads:

```
cx                             off-0
    8804000.mmc                    suspended
    genpd:0:4080000.remoteproc     suspended
    17300000.remoteproc            suspended
```

| test | before | after |
| --- | --- | --- |
| `pm_test=devices`, 15 cycles | 6/10, 4/10, 9/10, 13/15, 15/20 | **0/15** |
| real `s2idle`, 8 cycles | crashed on essentially every cycle | **2/8** |

The fifteen `pm_test=devices` cycles were completely clean, with `dmesg`
confirming fifteen suspend entries and zero crash handling. On real `s2idle`
the last five consecutive cycles were clean and returned in 25.9 s against a
25 s alarm, meaning the modem lived and `ath10k` never burned its 30 s QMI
timeout; a failing cycle shows up unmistakably as 56 s.

## What is left

Real `s2idle` still fails about one cycle in four, so this was one contributor
and not the only one. `pm_test=devices` is now clean while the full cycle is
not, which places the remainder in the phases `devices` does not reach:
`dpm_suspend_late`, `dpm_suspend_noirq` and `machine_suspend`. That is
consistent with the earlier observation that `pm_test=platform` also killed
the modem, which was recorded before this cause was known and cannot be
attributed to it alone.

## Note on flashing this port

The boot image is Android header **v2** with the DTB in its own section, not
header v0 with the DTB appended to the kernel. Building it the latter way
produces an image the bootloader rejects, which drops the phone into fastboot.
Recovering from that is straightforward, and it is also the only reliable way
found to reach fastboot on this device: `reboot bootloader` and
`LINUX_REBOOT_CMD_RESTART2` both come back into the OS, because the mainline
device tree has no reboot-reason plumbing. Exact arguments:

```
mkbootimg --header_version 2 --kernel Image --ramdisk ramdisk.gz --dtb dtb \
  --pagesize 0x1000 --base 0x0 --kernel_offset 0x8000 \
  --ramdisk_offset 0x1000000 --second_offset 0x0 --tags_offset 0x100 \
  --dtb_offset 0x1f00000 --cmdline "$(cat cmdline.txt)"
```

Build the kernel with `LOCALVERSION=` set, or `setlocalversion` appends a `+`
and the initramfs modules no longer match the kernel, which also fails to
boot.
