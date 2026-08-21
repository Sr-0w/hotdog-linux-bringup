# Two service-registry locators run at once, and it is not the blocker

Date: 2026-08-21

Tested without a flash, on the running baseline, while the S63 image waits on a
protocol decision.

## The anomaly

The phone runs **both** protection-domain mappers at the same time. The
in-kernel one is loaded:

```
lsmod: qcom_pd_mapper 28672 0
kallsyms: qcom_pdm_drv, qcom_pdm_probe [qcom_pd_mapper]
```

and `/etc/local.d/50-slpi-control.start` starts the userspace `pd-mapper` on
top of it, which `rc-update` also had in the `boot` runlevel. QRTR shows the
consequence — the servreg locator, service 64, registered twice on node 1:

```
64  1  1  1  16393  Service registry locator service
64  1  1  1  16396  Service registry locator service
```

The sensor PD resolves its registry entry through that service at creation, so
two answering locators is a plausible way to get the wrong answer.

## The in-kernel mapper already knows SM8150

Worth recording, because it removes a difference that looked significant. The
baseline module carries the same SLPI domains as the one S63 builds:

```
baseline qcom_pd_mapper.ko      S63 qcom_pd_mapper.ko
  msm/slpi/root_pd                msm/slpi/root_pd
  msm/slpi/sensor_pd              msm/slpi/sensor_pd
  slpi_root_pd                    slpi_root_pd
  slpi_sensor_pd                  slpi_sensor_pd
  sm8150_domains, qcom,sm8150
```

So `soc: qcom: pd-mapper: add SM8150 SLPI domains` is already in the kernel the
phone boots; S63 does not change that surface.

## The test

Removed `pd-mapper` from the `boot` runlevel and neutralised the line in the
boot hook, leaving only the in-kernel locator, then rebooted. It behaved
exactly as intended:

```
pd-mapper userspace: absent
64  1  1  1  16393  Service registry locator service     (once, not twice)
400 ... node 9 port 12                                   (sensor core present)
```

and the sensors are unchanged:

```
accel  gyro  proximity  ambient_light  mag       -- all still no SUID
```

## Verdict

A real duplicate, cleanly removed, with no effect on sensor registration. It is
not the blocker. The original configuration was restored afterwards so the next
lease finds the environment it expects; `/root/50-slpi-control.start.orig`
holds the untouched hook either way.

Whether to keep two locators at all is a separate question — the in-kernel
mapper covers the same domains, so the userspace one is redundant on this
kernel — but that is a change to the team's baseline, not a debugging step.
