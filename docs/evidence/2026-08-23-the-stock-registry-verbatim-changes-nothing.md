# Serving OxygenOS's own registry verbatim changes nothing

Date: 2026-08-23

The strongest single elimination available, because it uses the device's own
known-good data rather than a reconstruction.

## The experiment

The phone still holds `/root/registry-backup-oos10` — the registry OxygenOS
10.0.13 wrote on this exact unit, when every sensor worked. Serving it
verbatim requires stopping the DSP's parser from regenerating it, which it
otherwise does on every boot (218 of 441 files rewritten). Emptying
`sensors/config/` of its JSON removes the parser's input entirely:

```
registre = celui d'OxygenOS (438 entrees)
config videe : 1 fichiers restants
```

After the reboot the registry was **untouched** — still 438 entries, so the
parser genuinely did not run.

## The result

```
accel / gyro / mag / proximity / ambient_light / rgb   no SUID
sars                                                   7335663959f5698867456bc70a6c70ca
```

Identical to every other configuration tried.

## What it eliminates

The entire registry and config layer, in one shot. Not "our reconstruction of
the registry is wrong", not "a group is missing or has a bad value", not "the
parser produces something subtly different from the vendor's" — the exact
bytes that worked on this hardware under OxygenOS do not work here.

Whatever differs is on the **environment** side: the kernel, the PD setup, or
something the AP provides or fails to provide. It is not sensor data.

Restored afterwards to 66 config files and 441 registry entries, with the
factory calibration intact.

## A related non-lead, recorded so it is not chased again

`dmesg` shows 1084 identical lines:

```
qcom,fastrpc-cb ...:compute-cb@1: invoke handle 3 pd 2 sid 1 addr 0xfee00000
```

which looks like the sensor PD repeatedly asking to map a register page, and
`0xfee00000` also appears in the coredump paired with a `0x1000` size. It is
neither. The line is a `dev_info` this project added to `fastrpc.c` at line
1136 that traces *every* FastRPC invoke, and `addr` is `ctx->buf->phys` — the
message buffer's physical address, the same for all calls. 1084 invokes is
`hexagonrpcd` serving files. Normal.
