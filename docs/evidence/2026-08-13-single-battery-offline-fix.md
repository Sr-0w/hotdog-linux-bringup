# Single battery indicator offline fix

Date: 2026-08-13

GitHub issue [#2](https://github.com/Sr-0w/hotdog-linux-bringup/issues/2)
reports two Plasma battery indicators with state-of-charge values that differ
by one percentage point.

## Root cause

The mainline device tree enabled two independent fuel gauges:

- the PM8150B integrated fuel gauge, exposed as `qcom-battery`;
- the factory-programmed external BQ27411-compatible gauge on I2C8.

The earlier packaging workaround assigned `UPOWER_IGNORE=1` to
`qcom-battery`. UPower 1.90.9 does not consume that udev property, so the rule
was installed correctly but could not affect device enumeration.

## Fix

Kernel revision `6.16.0-r177` disables only `&pm8150b_fg` and retains
`&pm8150b_charger`. The BQ27411-compatible device remains enabled as the sole
battery telemetry source. Device package revision `3-r23` removes the
ineffective udev rule.

The build validator now requires all of the following in the compiled DTB:

- the PM8150B SMB5 charger is enabled and references the battery profile;
- the PM8150B fuel gauge is disabled and has no stale battery/charger links;
- the I2C8 BQ27411-compatible gauge remains present and enabled.

## Offline validation

The complete 149-patch kernel stack built successfully with pmbootstrap and
the package validator passed both before and after packaging. The resulting
artifacts are:

| Artifact | SHA-256 |
| --- | --- |
| `linux-oneplus-hotdog-mainline616-6.16.0-r177.apk` | `abe5588a606841b0227debbe6dfbcb6edde6dec47d3912fe0e77819ee178b433` |
| packaged `sm8150-oneplus-hotdog.dtb` | `67b1939f4d95e2a5dd2522ca1aa28cda1f650e434cb8888de7ea7f1c933413dc` |
| `device-oneplus-hotdog-3-r23.apk` | `d9dcfb4bedf8a0ab2e94bf36605389648014dc9a17921276544d99778e20d74f` |

Direct inspection of the packaged DTB returned `okay` for the SMB5 charger,
`disabled` for the PM8150B fuel gauge, and `ti,bq27411` for the enabled I2C8
gauge. Both stale PM8150B gauge links were absent. An exact archive scan of
all `device-oneplus-hotdog` `3-r23` subpackages found no
`90-hotdog-single-battery.rules` payload. The complete public-tree validation
also passed.

This remains an offline candidate. The GitHub issue stays open until a later
boot confirms that Plasma shows one battery and that charging plus BQ27411
telemetry still work.
