# DSI transport errors desynchronise the DSC stream

Date: 2026-08-17

## Status

Characterised, not fixed. The internal display degrades into unreadable noise
after a burst of DSI transport errors. The driver has no recovery path for this
error class, so the corruption persists until the panel is fully
re-initialised. The trigger is spontaneous: it is not caused by brightness
changes, user interaction or compositor load.

## Visible failure

Three horizontal bands: RGB noise top and bottom, a regularly striped middle
band whose vertical period matches the DSC slice structure. The panel is
`samsung,oneplus-dsc` in command mode, so it receives a compressed stream; once
the decoder loses synchronisation the image stays broken and eventually goes
uniformly white.

## Instrumentation

Kernel `6.16.0-sm8150 #186` carries
`drm/msm/dsi: report raw FIFO and timeout status on error`, which prints the raw
`REG_DSI_FIFO_STATUS` and `REG_DSI_TIMEOUT_STATUS` values next to the aggregated
state mask. Before that patch the only evidence was a bare `status=5`.

```text
dsi_err_worker: status=5 fifo=88881010 timeout=00000001
```

`status=5` is `DSI_ERR_STATE_TIMEOUT` (`0x1`) | `DSI_ERR_STATE_FIFO` (`0x4`).

Observed `fifo` values over one session:

| value | count | decode |
|---|---|---|
| `88881010` | 41 | DLN0-3 `HS_FIFO_UNDERFLOW`, `DLN0_LP_FIFO_EMPTY`, `0x10` reserved |
| `99991010` | 8 | as above plus DLN0-3 `HS_FIFO_EMPTY` |
| `88881310` | 1 | as `88881010` plus `CMD_DMA_FIFO_RD/WR_WATERMARK_REACH` |

The invariant across every sample is `0x88880000`: all four high-speed data
lanes underflow simultaneously. A signal-integrity fault on one differential
pair would affect one lane, not four at once.

## Burst structure

Bursts are strikingly uniform in size and irregular in spacing:

```text
t=65.1-66.1    (10 errors)
t=443.7-444.1  (11)
t=450.5-451.4  (11)
t=530.9-532.1  (11)
t=640.1-640.9  (11)
```

## What was eliminated

Each of the following was tested and refuted by measurement, not reasoning:

- **Brightness DCS commands.** 400 back-to-back `SET_DISPLAY_BRIGHTNESS`
  writes through sysfs produced zero errors. An earlier 30-write test appeared
  to produce 11 errors, but that was a spontaneous burst falling inside the
  sample window.
- **Low-power command mode.** `samsung_oneplus_dsc_bl_update_status()` already
  clears `MIPI_DSI_MODE_LPM` before sending brightness, so the command goes out
  in high speed. `DLN0_LP_FIFO_EMPTY` marks an idle LP FIFO, not an LP
  transmission.
- **User or compositor activity.** During a five-minute window with nothing
  running but one `dmesg` sample per minute, a burst of 11 errors occurred:
  `uptime=631 errors=43` then `uptime=691 errors=54`.
- **DPU starvation at the interface.** `encoder-0/status` reports
  `underrun: 0` across the entire session while vsync counts normally in
  `INTF_MODE_CMD`. The DPU never reports failing to feed its interface.
- **Controller soft reset as recovery.** See below.

## Rejected fix: soft reset on any FIFO error

`dsi_err_worker()` only calls `dsi_sw_reset()` for
`DSI_ERR_STATE_MDP_FIFO_UNDERFLOW`, leaving every other FIFO error
uncorrected. Extending that to the whole FIFO class looked defensible and was
built as `#185`.

It made the system materially worse. One DSI error at t=58 triggered the new
reset path, which broke the DPU command-mode CTL start handshake, and from then
on every frame failed:

```text
[drm:_dpu_encoder_phys_cmd_wait_for_ctl_start:653] [dpu error]enc33 intf1 ctl start interrupt wait failed
[drm:dpu_kms_wait_for_commit_done:524] [dpu error]wait for commit done returned -22
```

These repeated about eleven times per second and made Plasma unusable. The
patch was reverted; the upstream restriction to MDP underflow exists for a
reason. The instrumentation half was kept.

## Working recovery

A full panel re-initialisation clears the degraded state durably. After the
suspend/resume cycle at t=1110 the error count stayed frozen at 54 from
uptime 1219 to 1922, roughly twelve minutes, against a largest previously
observed inter-burst gap of 378 seconds.

This is a usable workaround today: a suspend/resume cycle restores the display
without a reboot.

## Panel and clock reference

```text
DSC 1.1, slice 720x65, 2 slices per line, 8 bpp, block prediction on
command mode, MIPI_DSI_MODE_NO_EOT_PACKET | MIPI_DSI_CLOCK_NON_CONTINUOUS
disp_cc_mdss_pclk0_clk  144506775 Hz
disp_cc_mdss_byte0_clk  108380081 Hz   (867 Mbps/lane, 3.47 Gbps over 4 lanes)
DPU core_clk_rate       426746880 Hz of max_core_clk_rate 460000000 Hz
```

The link carries 3.235 Gbps of payload over 3.47 Gbps of capacity, so the DSI
side is not oversubscribed.

## Next step

The failure sits between the DSI controller and the PHY: the DPU reports no
underrun, the link has margin, and `DSI_ERR_STATE_PLL_UNLOCKED` is never set.
Instrumenting the DSI PHY and the controller's own data path at burst time is
the next useful measurement.
