#!/usr/bin/env python3
"""Convert a packed MIPI RAW10 Bayer frame to a viewable PNG preview."""

from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
from PIL import Image


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path, help="packed RAW10 input frame")
    parser.add_argument("output", type=Path, help="output PNG path")
    parser.add_argument("--width", type=int, required=True)
    parser.add_argument("--height", type=int, required=True)
    parser.add_argument(
        "--stride",
        type=int,
        help="bytes per input row; defaults to the packed payload width",
    )
    parser.add_argument(
        "--pattern",
        choices=("RGGB", "GRBG", "GBRG", "BGGR"),
        default="GRBG",
        help="Bayer order at the top-left pixel (default: GRBG)",
    )
    parser.add_argument(
        "--black-percentile",
        type=float,
        default=0.5,
        help="percentile mapped to black (default: 0.5)",
    )
    parser.add_argument(
        "--white-percentile",
        type=float,
        default=99.5,
        help="percentile mapped to white (default: 99.5)",
    )
    parser.add_argument(
        "--no-auto-white-balance",
        action="store_true",
        help="do not apply gray-world channel gains",
    )
    return parser.parse_args()


def unpack_raw10(data: bytes, width: int, height: int, stride: int) -> np.ndarray:
    if width <= 0 or height <= 0 or width % 4:
        raise ValueError("width and height must be positive; width must be divisible by 4")

    payload = width * 5 // 4
    if stride < payload:
        raise ValueError(f"stride {stride} is smaller than RAW10 payload {payload}")
    expected = stride * height
    if len(data) < expected:
        raise ValueError(f"input has {len(data)} bytes; expected at least {expected}")

    rows = np.frombuffer(data, dtype=np.uint8, count=expected).reshape(height, stride)
    groups = rows[:, :payload].reshape(height, width // 4, 5).astype(np.uint16)
    low = groups[:, :, 4]

    image = np.empty((height, width), dtype=np.uint16)
    image[:, 0::4] = (groups[:, :, 0] << 2) | (low & 0x03)
    image[:, 1::4] = (groups[:, :, 1] << 2) | ((low >> 2) & 0x03)
    image[:, 2::4] = (groups[:, :, 2] << 2) | ((low >> 4) & 0x03)
    image[:, 3::4] = (groups[:, :, 3] << 2) | ((low >> 6) & 0x03)
    return image


def bayer_masks(shape: tuple[int, int], pattern: str) -> tuple[np.ndarray, ...]:
    colors = {
        "RGGB": ((0, 0), (0, 1), (1, 1)),
        "GRBG": ((0, 1), (0, 0), (1, 0)),
        "GBRG": ((1, 0), (0, 0), (0, 1)),
        "BGGR": ((1, 1), (0, 1), (0, 0)),
    }
    red_pos, green_pos, blue_pos = colors[pattern]
    yy, xx = np.indices(shape)
    red = (yy % 2 == red_pos[0]) & (xx % 2 == red_pos[1])
    blue = (yy % 2 == blue_pos[0]) & (xx % 2 == blue_pos[1])
    green = ~red & ~blue
    assert green[green_pos[0], green_pos[1]]
    return red, green, blue


def interpolate_channel(values: np.ndarray, mask: np.ndarray) -> np.ndarray:
    height, width = values.shape
    accum = np.zeros_like(values, dtype=np.float32)
    weights = np.zeros_like(values, dtype=np.float32)
    kernel = ((1, 2, 1), (2, 4, 2), (1, 2, 1))

    for ky, row in enumerate(kernel):
        dy = ky - 1
        src_y = slice(max(0, -dy), min(height, height - dy))
        dst_y = slice(max(0, dy), min(height, height + dy))
        for kx, weight in enumerate(row):
            dx = kx - 1
            src_x = slice(max(0, -dx), min(width, width - dx))
            dst_x = slice(max(0, dx), min(width, width + dx))
            source_mask = mask[src_y, src_x]
            accum[dst_y, dst_x] += values[src_y, src_x] * source_mask * weight
            weights[dst_y, dst_x] += source_mask * weight

    channel = np.divide(accum, weights, out=np.zeros_like(accum), where=weights > 0)
    channel[mask] = values[mask]
    return channel


def render_preview(
    bayer: np.ndarray,
    pattern: str,
    black_percentile: float,
    white_percentile: float,
    auto_white_balance: bool,
) -> tuple[np.ndarray, dict[str, float]]:
    black = float(np.percentile(bayer, black_percentile))
    white = float(np.percentile(bayer, white_percentile))
    if white <= black:
        raise ValueError(f"invalid auto levels: black={black}, white={white}")

    linear = np.clip((bayer.astype(np.float32) - black) / (white - black), 0.0, 1.0)
    masks = bayer_masks(bayer.shape, pattern)
    channels = [interpolate_channel(linear, mask) for mask in masks]

    gains = [1.0, 1.0, 1.0]
    if auto_white_balance:
        references = [float(np.percentile(linear[mask], 90.0)) for mask in masks]
        target = references[1]
        gains = [min(4.0, max(0.25, target / max(value, 1e-6))) for value in references]
        for channel, gain in zip(channels, gains, strict=True):
            channel *= gain

    rgb = np.stack(channels, axis=-1)
    rgb = np.clip(rgb, 0.0, 1.0) ** (1.0 / 2.2)
    preview = np.rint(rgb * 255.0).astype(np.uint8)
    stats = {
        "minimum": float(bayer.min()),
        "maximum": float(bayer.max()),
        "mean": float(bayer.mean()),
        "black": black,
        "white": white,
        "red_gain": gains[0],
        "green_gain": gains[1],
        "blue_gain": gains[2],
    }
    return preview, stats


def main() -> int:
    args = parse_args()
    payload = args.width * 5 // 4
    stride = args.stride if args.stride is not None else payload
    bayer = unpack_raw10(args.input.read_bytes(), args.width, args.height, stride)
    preview, stats = render_preview(
        bayer,
        args.pattern,
        args.black_percentile,
        args.white_percentile,
        not args.no_auto_white_balance,
    )

    args.output.parent.mkdir(parents=True, exist_ok=True)
    Image.fromarray(preview, mode="RGB").save(args.output)
    print(
        "RAW10 "
        f"width={args.width} height={args.height} stride={stride} pattern={args.pattern} "
        + " ".join(f"{key}={value:.3f}" for key, value in stats.items())
    )
    print(f"PNG path={args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
