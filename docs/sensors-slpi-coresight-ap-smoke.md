# Sensors SLPI CoreSight AP smoke helper

`scripts/sensors-slpi-coresight-ap-smoke.sh` is a bounded Hardware Lab helper
for the e566 `6.16.0-sm8150` hotdog kernel. It exercises only the AP-side STM
path through an ETF sink.

It does not enable QDSSC, does not touch remoteproc, does not reboot and does
not flash. The helper requires a reviewed `stm_p_basic.ko` path and SHA256 at
runtime; no module binary is committed here.

Example, after QA and with an explicit phone lease:

```sh
sudo ./scripts/sensors-slpi-coresight-ap-smoke.sh \
  --module /private/qa/stm_p_basic.ko \
  --module-sha256 7aa1932d5672e7b0674c27c9524446155992f4385f80063c4858737f07bf82c3 \
  --sink tmc_etf0 \
  --capture-out /private/run/hotdog-ap-stm-etf0.bin
```

Safety properties:

- attests `hostname=hotdog`, `uname -m=aarch64` and `uname -r=6.16.0-sm8150`;
- validates the exact module hash and vermagic before loading;
- rejects invalid sink names and `tmc_etr*` sink arguments before any module
  load attempt;
- pre-enumerates the existing CoreSight topology before module load; if STM/ETF
  devices are already visible, it requires exactly one `stm0`, one STM class
  `stm0` and the requested `tmc_etf*` sink to exist exactly once before
  `stm_p_basic` can be loaded;
- accepts explicit `tmc_etf*` sinks even when they expose `buffer_size`, refuses
  `tmc_etr*`, reports any other ETF candidates without touching them, and never
  writes `buffer_size`;
- refuses pre-enabled STM/ETF paths and pre-existing smoke policies;
- creates one `stm0:p_basic.ap-smoke/default` policy with one master and one
  channel;
- writes a single AP marker through `/dev/stm0`;
- captures at most 4096 bytes from the selected ETF device;
- rollback order is source, sink, policy, `rmmod stm_p_basic`, `modprobe -r
  stm_core` for modules introduced by the script;
- pre-existing modules are not unloaded.

The capture file remains private lab evidence until reviewed. Loading an
out-of-tree module can taint the kernel; `rmmod` removes the module but does not
clear that taint. If a clean-taint proof is required for a later lease, schedule
a separate pre-test reboot before running the smoke.

The only supported path where module mutation precedes complete CoreSight
topology validation is the cold case where no STM/ETF topology is visible and
`stm_core`/`stm_p_basic` are not already loaded. In that case the script loads
`stm_core`, immediately repeats topology enumeration, and only then permits the
reviewed `stm_p_basic.ko` load.

## Runtime command set

The target environment is postmarketOS with BusyBox 1.38 userland and `bash`
available. The script uses shell builtins plus these external commands:

- `awk`
- `date`
- `dd`
- `find`, only as `find ROOT -print`
- `hostname`
- `insmod`
- `lsmod`
- `mkdir`
- `modinfo`
- `modprobe`
- `rmdir`
- `rmmod`
- `sed`
- `sha256sum`
- `sort`
- `timeout`
- `uname`
- `wc`

When tests override the configfs root with a fixture path, the script also uses
`rm` to remove regular mock files before `rmdir`. On the real `/sys/kernel/config`
path it does not use `rm` for policy cleanup.
