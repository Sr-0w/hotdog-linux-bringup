# The OxygenOS vendor partition is recoverable, and it is the reference

Date: 2026-08-24

The reference implementation for everything the sensor core expects was sitting
in the download package the whole time. Recovering it is worth writing down
because two obvious routes fail.

## Why the obvious routes fail

**The phone no longer has it.** `vendor`, `vendor_a` and `system_a` still appear
under `/dev/disk/by-partlabel`, but they are dangling: this device uses Android
dynamic partitions, so those lived inside `super`, and the postmarketOS install
replaced `super` with a nested GPT. `opproduct_a` and `opproduct_b` survive as
real ext4 volumes; the vendor tree does not.

**The ADB dump does not contain it either** — it holds `dumpsys` output and
`/vendor/etc/sensors`, not the libraries.

## Where it is

`cache/oos10.0.13-hd1913-ops/super.img`, from the MSM download-mode package —
4.7 GB, and it is an **Android sparse image**, which is why a naive parse of its
liblp metadata lands at offset `0x38` instead of `0x1000` and produces extents
that decode to nothing.

[`android-sparse-read.py`](../../helpers/android-sparse-read.py) indexes the
sparse chunks once and then reads any byte range on demand, so recovering a
987 MB partition does not require writing out 15 GB first. With that, the liblp
metadata parses cleanly:

```
geometrie a 0x1000, en-tete a 0x3000
system_a    2355167232 octets   secteur 2048
product_a   1395171328 octets   secteur 4603904
vendor_a     987041792 octets   secteur 7329792
odm_a           933888 octets   secteur 9259008
```

`vendor_a` is ext4 — the magic is at `0x438`, which is offset `0x38` inside the
superblock at 1024, not at 1024 itself. `debugfs` reads it without mounting or
root.

## What it contains

```
/vendor/bin/sensors.qti                     the HAL
/vendor/bin/sscrpcd
/vendor/bin/init.qcom.sensors.sh
/vendor/lib64/libsnsapi.so                  1.4 MB, the SSC API
/vendor/lib64/libsensorndkbridge.so
/vendor/lib64/hw/android.hardware.sensors@1.0-impl.so
```

This is the client that made proximity work on this exact firmware. Comparing
how it builds a proximity request against what this port sends is the
outstanding question, and it is now answerable without the phone.

## Two things it already corrected

**A missing registry input.** `sns_reg.conf` asks for the key `project` from
`/sys/project_info/project_name`, which the OPLUS downstream kernel exposes from
SMEM — `char project_name[8]`, `19801` on this unit — and which mainline does
not have. The key was silently unanswered. It now points at
`/proc/oppoVersion/prjName`, which this port already provisions, and the log
shows the file being read twice as often as before.

**Backup files inside the config directory.** `hexagonrpcd`'s log shows the
parser opening `tcs3701.json.avant-dri` and `tcs3701.json.avant-hwid` — copies
this investigation left beside the real configuration, which the parser
enumerates and applies. The same hygiene failure had already been found and
fixed for `sensors/registry/`, and repeated here. Moved out; 65 JSON files
remain, matching the vendor set exactly.

Neither changed proximity. Both were real defects that contaminated every test
run while they were present.
