# The sensor descriptor table

Date: 2026-08-23

Structural groundwork for whoever continues. This does not explain why the
accelerometer fails, but it names the data structure the answer lives in.

## Layout

Island data around `0x97aa4000` (physical; VA `0xe06b4000` under the
`fw seg12 = 0xe06a8000 ↔ cd 0x97a98000` mapping) holds an array of sensor
descriptors:

```
struct {
    sns_sensor_uid suid;      // 16 bytes
    uint32_t       struct_len; // 0x14 or 0x18
    void (*init)(...);
    void (*deinit)(...);
    ... 2-3 more entry points
};                             // stride 0x28 for the 0x18 form
```

Confirmed by cross-check rather than pattern-matching alone: the descriptor
at `0x97aa406c` carries the exact 16 bytes that `sns_lsm6dsm`'s init at
`0xb21c7b14` writes one at a time (`cd 4b 1a 6d 68 da 4a 77 85 ab 46 e2 cd a5
68 0b`), and `0x97aa4070` holds that init's address. The same holds for
`0x97aa4044` / `0xb21c7aa8`.

## Which sensors have static descriptors

Filtering the whole island segment for entries whose 16 SUID bytes are
neither zero, nor code pointers, nor island pointers — the filter matters,
because a naive scan matches every run of function pointers and also matches
float tables (`0x3f800000`, `0xbf800000` are 1.0f and -1.0f, and two `alsps`
coefficient blocks look like SUIDs without it):

| descriptor | init | driver |
| --- | --- | --- |
| `0x97aa401c` | `0xb21c75e4` | lsm6dsm |
| `0x97aa4044` | `0xb21c7aa8` | lsm6dsm |
| `0x97aa406c` | `0xb21c7b14` | lsm6dsm |
| `0x97aa4094` | `0xb21cbe18` | lsm6dsm |
| `0x97add0dc` | `0xb219b8a8` | framework |
| `0x97addbf4` | `0xb21b5798` | framework |

`resampler`, `timer`, `registry`, `interrupt`, `sars` and the ALS have **no**
static SUID anywhere — theirs are produced at run time.

## The discriminator that looked promising and is not one

"Only the failing driver has static SUIDs" was the obvious reading, and it is
wrong. Searching a live coredump for each of these SUIDs outside the island
segment:

```
framework A  0x97c20e3c  0x97f469a0     <- live band
framework B  0x97c21954  0x97f48520     <- live band
lsm6dsm a-d  0x982e70xx  0x9868e0xx     <- root-PD and sensor-PD static copies only
```

The live sensor objects sit around `0x97f4xxxx`–`0x97f5xxxx` (the ALS is at
`0x97f51f60`, the SAR at `0x97f57d00`). Both framework sensors with static
descriptors are there. All four LSM6DSM descriptors appear only as the two
static image copies, `0x3A7000` apart — the root-PD/sensor-PD offset.

So a static descriptor is instantiated perfectly well in general. The
LSM6DSM's four are simply never acted on.

## A convention trap worth writing down

A SUID has two representations and mixing them silently produces empty
results. `ssc-client.py` prints `"%016x%016x" % (high, low)` where `low` and
`high` are the two little-endian 64-bit halves — so the printed string is
**not** the byte order in memory. For the ALS:

```
memory bytes  62 61 43 54 52 4c 22 35 | 39 31 91 2c 43 5d 52 5f
printed form  5f525d432c913139 35224c5254436162
```

Searching a dump for the printed string, or feeding memory bytes to a
printed-form decoder, finds nothing and looks like a negative result. It cost
one wrong "the ALS SUID is absent" reading in this session's working notes.

## Where the answer must be

Nothing references these descriptors by address — no code immediate, no data
pointer, in either the image or a live dump. They are reached by base plus
index, with the base computed rather than stored. Finding the iterator, and
what it consults before calling each `init`, is the remaining work.
