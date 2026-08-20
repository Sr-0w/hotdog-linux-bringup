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
- refuses ETR sinks and never writes `buffer_size`;
- refuses pre-enabled STM/ETF paths and pre-existing smoke policies;
- creates one `stm0:p_basic.ap-smoke/default` policy with one master and one
  channel;
- writes a single AP marker through `/dev/stm0`;
- captures at most 4096 bytes from the selected ETF device;
- rollback order is source, sink, policy, `stm_p_basic`, `stm_core`;
- pre-existing modules are not unloaded.

The capture file remains private lab evidence until reviewed.
