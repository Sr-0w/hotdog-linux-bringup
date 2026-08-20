# Display regression 01 — transient scanout corruption recovered

Date: 2026-08-20

Canonical state: `TRANSIENT_RECOVERED / NEEDS_FOLLOWUP`

This record covers the read-only Hardware Lab diagnosis of boot
`e566d5d4-r2`. It does not establish a permanent display failure or a
permanent success claim.

## Observed episode

- The Samsung command-mode DSC panel entered visibly corrupted scanout during
  the `e566d5d4-r2` session.
- A user lock/unlock immediately restored normal scanout. No rollback, reflash,
  or additional reboot was recommended or performed for this episode.
- The post-recovery attestation kept the same boot, reported `aarch64` on
  `hotdog`, `DSI-1` connected and enabled, a valid display mode, maximum
  backlight, and `remoteproc0=slpi:running`.
- The Hardware Lab counted 48 `dsi_err_worker` status-5 FIFO/timeout events in
  the captured session. The traces also show repeated Samsung DSC panel
  initialization at 90 Hz. No DPU underrun was observed.
- USB `18d1:d001` was the running pmOS CDC-NCM gadget identity. It is not
  evidence of bootloader fastboot; bounded fastboot probes did not establish a
  fastboot device.

## Source and artifact comparison

The r2 artifact was built as `e566d5d4-r2` and has AVB image SHA256
`d881abafd3496a24cd4620e5adb4f56afbf4279e6c7136ac9197af0ab726b1f6`.
Its component manifest records:

| Component | Validated baseline v16 | r2 artifact |
|---|---|---|
| Kernel | `9871837071bfb350d380e730f719c88b5cb45f3dd7928dc9f5b080b6b4747bc9` | `83451554de054acf484ea00b5889c603a348263370190c0b103799470dd9271d` |
| DTB | `ed287502b67dc42e01bd9349091182994338da8da1a8d95cd24ca120b1ef4a1b` | `c11594377d6cc98fe6b111d816e6887190d871ec08bfb8d4e24e4ed68a86d432` |
| Ramdisk | `0ced7954e5c46ccf506a44289e6acecc13bbbdd5408382cf55b3221d52c1db23` | unchanged |
| Command line | `ca5e8152fe855f3d0b16faa25dc048d8a06f4aa3c510f02db51cd6c953162d70` | unchanged |

The static audit found no display-related DRM/DSI/panel source or configuration
delta relevant to this episode. The r4/v4 line adds general tracing/debug
coverage; that addition does not prove causality for the scanout corruption.
The component hash changes above must not be misrepresented as a display fix.

## Evidence and limits

The raw, local-only captures are retained under
`logs/2026-08-20-display-regression-01/`. Relevant sanitized evidence files
include `final-attestation-summary.txt`, `post-dmesg-display-filtered.txt`,
`post-dmesg-display-key-lines.txt`, `v4-r2-artifact-summary.txt`,
`v16-v4-component-hashes.txt`, and `v16-v4-cmdline-hashes.txt`.

The corresponding local artifact manifest is
`images/pmos-experiments/2026-08-20-smb5-v4-e566d5d4-r2/MANIFEST.md`, with
component hashes in its `SHA256SUMS`. Raw dumps, USB metadata, boot IDs,
serials, credentials and photos remain local and are not part of this record.

## Follow-up gate

Keep the aggregate display state `Partial`. The 60/90 Hz paths and recovery
after lock/unlock are useful validated functions, but DSI transport/DSC
instability remains an open regression. The next diagnostic should preserve
the same source/config baseline, capture the complete DSI worker and panel
reinitialization sequence, and change one variable at a time. Do not label the
display `Broken` or `Working` absolutely, and do not recommend rollback or
reflash solely from this episode.
