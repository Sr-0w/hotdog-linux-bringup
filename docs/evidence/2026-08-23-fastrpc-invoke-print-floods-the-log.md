# A debug print on the FastRPC hot path fills 98% of the kernel log

Date: 2026-08-23

Reported from the phone's own console: a flood of

```
qcom,fastrpc-cb 2400000.remoteproc:glink-edge:fastrpc:compute-cb@1:
    invoke handle 3 pd 2 sid 1 addr 0xfea00000
```

for several seconds at every boot. It boots through it, so it reads as cosmetic.
It is not.

## Measured

```
lignes dmesg au total   1096
dont "invoke handle"    1077
```

**98% of the kernel ring buffer is one message.** Everything else — every driver
probe, every warning, anything that would explain a boot problem — is evicted
before it can be read. That makes it a diagnostic problem, not a cosmetic one.

## Where it comes from

`drivers/misc/fastrpc.c:1136`, in `fastrpc_invoke_send`:

```c
	dev_info(sctx->dev, "invoke handle %u pd %d sid %d addr 0x%llx\n",
		 handle, fl->pd, sctx->sid, msg->addr);
```

`git log -S` places it in our own `test-only: snapshot bootable Hotdog 6.16
baseline` commit — a local debug addition, not upstream code, left on the hot
path of every RPC call.

It floods precisely because the sensor work made FastRPC busy: `hexagonrpcd`
serves 441 registry entries and 66 config files to the SLPI at boot, and each
one is a chain of invokes.

## Fix

Demoted to `dev_dbg`, which compiles out unless dynamic debug is enabled, so the
message stays available when it is actually wanted:

```c
	dev_dbg(sctx->dev, "invoke handle %u pd %d sid %d addr 0x%llx\n",
		handle, fl->pd, sctx->sid, msg->addr);
```

Applied in `build/2026-08-20-smb5-v4-e566d5d4-src`. **It takes effect on the next
kernel build and flash** — the running 6.16.0-sm8150 still carries the
`dev_info`.

Not an upstream submission: the line does not exist upstream, so there is
nothing to send.
