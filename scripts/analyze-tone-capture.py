#!/usr/bin/env python3
"""Measure a single tone inside a captured WAV file.

The analysis is deliberately dependency-free so that acoustic evidence can be
reproduced from a plain checkout. It reports, per channel, the level at the
expected frequency and the surrounding noise floor, which is what separates a
real acoustic capture from silence.

A Hann window is applied before the Goertzel evaluation and its coherent gain
is compensated, so the reported level is the amplitude of the tone rather than
a windowed approximation of it.
"""

import argparse
import cmath
import math
import statistics
import sys
import wave


def read_channels(path):
    with wave.open(path, "rb") as handle:
        params = handle.getparams()
        if params.sampwidth != 2:
            raise SystemExit(
                f"{path}: only 16-bit PCM is supported, got "
                f"{params.sampwidth * 8}-bit"
            )
        raw = handle.readframes(params.nframes)

    import array

    flat = array.array("h")
    flat.frombytes(raw)
    if sys.byteorder == "big":
        flat.byteswap()

    channels = [list(flat[c :: params.nchannels]) for c in range(params.nchannels)]
    return params.framerate, channels


def goertzel(samples, rate, freq, window):
    """Return the amplitude of `freq` in `samples`, in full-scale units."""
    n = len(samples)
    if n == 0:
        return 0.0
    k = freq * n / rate
    omega = 2.0 * math.pi * k / n
    coeff = 2.0 * math.cos(omega)
    s1 = s2 = 0.0
    for i, value in enumerate(samples):
        s0 = value * window[i] + coeff * s1 - s2
        s2 = s1
        s1 = s0
    real = s1 - s2 * math.cos(omega)
    imag = s2 * math.sin(omega)
    magnitude = abs(complex(real, imag))
    # 2/N normalises to amplitude; /0.5 compensates the Hann coherent gain.
    return magnitude * 2.0 / n / 0.5


def dbfs(amplitude, full_scale=32768.0):
    if amplitude <= 0:
        return float("-inf")
    return 20.0 * math.log10(amplitude / full_scale)


def rms_dbfs(samples, full_scale=32768.0):
    if not samples:
        return float("-inf")
    total = math.fsum(float(v) * float(v) for v in samples)
    value = math.sqrt(total / len(samples))
    if value <= 0:
        return float("-inf")
    return 20.0 * math.log10(value / full_scale)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("wav", help="captured WAV file (16-bit PCM)")
    parser.add_argument(
        "--freq", type=float, default=1000.0, help="expected tone in Hz"
    )
    parser.add_argument(
        "--min-margin",
        type=float,
        default=12.0,
        help="dB the tone must exceed the noise floor by to pass",
    )
    parser.add_argument(
        "--skip",
        type=float,
        default=0.0,
        help="seconds to discard from the start, to drop stream warm-up",
    )
    args = parser.parse_args()

    rate, channels = read_channels(args.wav)
    offset = int(args.skip * rate)

    # Probe frequencies well away from the tone and its first harmonics, so a
    # loud capture does not inflate its own reference floor through leakage.
    probes = [
        f
        for f in range(200, min(8000, rate // 2), 173)
        if abs(f - args.freq) > 150
        and abs(f - 2 * args.freq) > 150
        and abs(f - 3 * args.freq) > 150
    ]

    overall_pass = True
    for index, samples in enumerate(channels):
        samples = samples[offset:]
        if not samples:
            raise SystemExit(f"{args.wav}: channel {index} has no samples after --skip")
        n = len(samples)
        window = [0.5 - 0.5 * math.cos(2.0 * math.pi * i / n) for i in range(n)]

        tone = dbfs(goertzel(samples, rate, args.freq, window))
        floor_levels = [
            dbfs(goertzel(samples, rate, f, window)) for f in probes
        ]
        floor = statistics.median(floor_levels)
        margin = tone - floor
        ok = margin >= args.min_margin
        overall_pass = overall_pass and ok

        label = "ch%d" % index
        print(f"{label}: samples={n} duration={n / rate:.2f}s")
        print(f"{label}: rms={rms_dbfs(samples):.1f} dBFS")
        print(f"{label}: tone@{args.freq:.0f}Hz={tone:.1f} dBFS")
        print(f"{label}: noise-floor={floor:.1f} dBFS (median of {len(probes)} probes)")
        print(f"{label}: margin={margin:.1f} dB -> {'PASS' if ok else 'FAIL'}")

    print(f"result={'PASS' if overall_pass else 'FAIL'}")
    return 0 if overall_pass else 1


if __name__ == "__main__":
    sys.exit(main())
