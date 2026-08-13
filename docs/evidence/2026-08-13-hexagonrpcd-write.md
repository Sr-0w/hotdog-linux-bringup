# Writable file service for hexagonrpcd - 2026-08-13

## Why

The sensor DSP asks to write `sns_reg_version` and `hexagonrpcd` refuses,
because it serves read-only. `apps_std_fopen_with_env` rejects the `w` and `a`
modes outright, `struct hexagonfs_file_ops` has no write operation at all, and
the `apps_std` method table has no `fwrite` entry.

That refusal was noted earlier as tolerated, on the grounds that nothing
crashed. It is worth being precise about why that is not good enough: a sensor
framework that cannot stamp its registry version may never declare itself
initialised, which would leave a live QMI service with no sensors behind it.
That is exactly the signature being chased.

## The ABI, established rather than guessed

The method definitions live in `hexagonrpcd/interfaces/apps_std.def` behind

```
HEXAGONRPC_DEFINE_REMOTE_METHOD(msg_id, name, in_nums, in_bufs, out_nums, out_bufs)
```

and the counts are not obvious from the names. `listener.c` settles it:

```c
if (inbufs[0].s != 4U * (def->in_nums + def->in_bufs + def->out_bufs))
```

So the first input buffer holds `in_nums` scalar words, then one size word per
input buffer, then one per output buffer, all `uint32`. And `out[0].s =
def->out_nums * 4`, so `out_nums` is a word count too.

Checking that against `fread`, declared `(4, apps_std_fread, 1, 0, 2, 1)`: its
implementation reads `inbufs[0]` as `{fd, buf_size}`, which is one scalar plus
one output-buffer size. It fits.

`fwrite` is therefore `(5, apps_std_fwrite, 1, 1, 2, 0)`: the file descriptor
as its scalar, the data as an input buffer, and `{written, is_eof}` out. The
message id follows `fread` in the interface, which is where the read and write
pair sit.

## The change

Five files, 87 lines.

- `struct hexagonfs_file_ops` gains a `write`, and `hexagonfs_write()` mirrors
  `hexagonfs_read()`, returning `-EROFS` where a backing type has none.
- `hexagonfs_mapped.c` implements it against the underlying descriptor, and
  opens files read-write with a fallback to read-only, so a read-only mount or
  an unwritable file still opens as before.
- `apps_std.c` gains `apps_std_fwrite` and wires it into the table at the slot
  after `fread`, and stops rejecting the `w` and `a` open modes.

Packaged as `aports/main/hexagonrpcd` against upstream 0.4.0. Two build notes:
`linux-headers` is needed for `misc/fastrpc.h`, and the man page needs a `-doc`
subpackage. The upstream `hexagonfs` test is skipped in the package because it
takes its sample file by a path relative to the source tree while meson runs it
from the build directory; it passes when run by hand against this build.

## Status

Built, packaged and installed. Whether it unblocks the sensors is not yet
shown: the QMI service still accepts requests and allocates client ids without
any sensor answering a lookup.

## The served tree is built in code, not mounted

A long detour was caused by assuming `-R` is a chroot. It is not.
`rpcd_builder.c` builds a virtual tree with fixed mount points, and the paths
the DSP uses map to quite different places under the root:

| Path the DSP opens | Backed by |
| --- | --- |
| `/persist/sensors/registry/registry` | `<root>/sensors/registry/` |
| `/vendor/etc/sensors/sns_reg_config` | `<root>/sensors/sns_reg.conf` |
| `/vendor/etc/sensors/config` | `<root>/sensors/config/` |
| `/sys/devices/soc0` | `<root>/socinfo/` |
| `/usr/lib/qcom/adsp` | `<root>/dsp/<dsp>/` |
| `/vendor/etc/acdbdata` | `<root>/acdb/` |

Files placed anywhere else are invisible, which is why copies under
`<root>/sys/devices/soc0` were never found no matter how correct they looked.

Two entries the DSP needs were missing from that tree entirely and are added
here: `sns_reg_version` beside the registry, which is the file it writes, and
`/proc/oppoVersion`, which it polls.

## One unknown method should not end the service

With the version stamp writable the DSP progresses further and calls apps_std
method 24, which nothing implements. The listener treated that as fatal and
tore down the whole file service:

```
Unsupported method: 24 (18020000)
```

The error result is already returned to the DSP on the following pass, so
failing the call and continuing is both correct and what the DSP expects. With
that change the service survives, the domain completes its 1092-call registry
read, and the unknown method is logged once instead of being terminal.

## Where it stands

Every file the DSP asked for at the start is now served, and it has moved on to
asking for different ones:

```
/mnt/vendor/persist/sensors/registry/file<N>
/sys/project_info/project_name
```

The numbered files are ones it wants to create, which the mapped backend does
not do: it opens existing paths and has no `O_CREAT`. That is the next piece.

The sensor lookup still returns no indication. The specific blocker is that the
sensor framework has not finished initialising, and the evidence for that is
the sequence of files it is still working through rather than anything in the
QMI exchange, which is accepted and answered correctly every time.

## File creation, and every request now served

The DSP creates files under the directories it is served, so `mapped_openat`
takes a create flag plumbed from the open mode in `apps_std_fopen_with_env`
through `hexagonfs_openat` and the `openat` operation. Non-creating callers
pass false.

That alone was not enough, because the parent was a virtual directory with two
fixed children and nothing can be created in one. `/persist/sensors/registry`
is now mapped to `<root>/sensors/` as a whole, which gives the DSP a real
directory holding `registry/`, `sns_reg_version`, `sns_reg.conf` and room for
the numbered files it wants. `/sys/project_info` is mapped as well.

The result is that nothing is missing any more:

```
manquants: 0
```

Every path the DSP has asked for across all of these runs is served: the
registry and its 438 entries, the version stamp it writes, `sns_reg_config`
taken from the vendor image, the socinfo attributes under `<root>/socinfo`,
`/proc/oppoVersion`, `/sys/project_info`, and `file1` and `file2`, which exist
on neither the stock persist partition nor the vendor image because the DSP
makes them itself.

`hexagonrpcd` also runs on the ADSP domain alongside the sensor one, in case
the sensor framework depended on it. It does not change the outcome.

## Blocker

With every requested file served, the QMI exchange accepted and answered, and
the lookup SUID confirmed against the vendor library, the sensor framework
still publishes no sensors and answers no SUID lookup, and what it is waiting
on is not visible from the host side.
