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

## Status

The fix is committed and the device tree builds. It has not yet run on the
phone: the DTB ships inside the boot image, so verifying it needs a rebuild
and a flash. The unbind measurement above is the evidence that the mechanism
is real; confirming the DT change itself is the next step.
