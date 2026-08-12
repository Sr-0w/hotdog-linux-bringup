#!/usr/bin/env python3
"""Build an NXP NCI RF configuration blob from Android HAL config files."""

import argparse
import pathlib
import re
import sys


BASE_KEYS = (
    "NXP_ACT_PROP_EXTN",
    "NXP_NFC_PROFILE_EXTN",
    "NXP_EXT_TVDD_CFG_2",
)
RF_KEYS = (
    "NXP_RF_CONF_BLK_1",
    "NXP_RF_CONF_BLK_2",
    "NXP_RF_CONF_BLK_3",
    "NXP_RF_CONF_BLK_4",
    "NXP_CORE_CONF_EXTN",
)
TRAILING_BASE_KEYS = ("NXP_CORE_RF_FIELD",)
TRAILING_RF_KEYS = ("NXP_CORE_CONF",)

DEFAULT_MAX_FRAME_SIZE = 258


def parse_arrays(path: pathlib.Path, wanted: tuple[str, ...]) -> dict[str, bytes]:
    text = path.read_text(encoding="utf-8")
    text = re.sub(r"#.*$", "", text, flags=re.MULTILINE)
    arrays: dict[str, bytes] = {}

    for match in re.finditer(
        r"(?m)^\s*([A-Za-z0-9_]+)\s*=\s*\{(.*?)\}", text, re.DOTALL
    ):
        name, body = match.groups()
        if name not in wanted:
            continue
        values = []
        for token in body.replace("\n", " ").split(","):
            token = token.strip()
            if not token:
                continue
            if not re.fullmatch(r"(?:0[xX])?[0-9A-Fa-f]{1,2}", token):
                raise ValueError(f"{path}: invalid byte {token!r} in {name}")
            values.append(int(token, 16))
        arrays[name] = bytes(values)

    return arrays


def validate_frame(name: str, frame: bytes) -> None:
    if len(frame) < 3:
        raise ValueError(f"{name}: NCI frame is shorter than its header")
    if frame[0] & 0x10 or frame[0] & 0xE0 != 0x20:
        raise ValueError(f"{name}: only complete NCI command packets are allowed")
    if frame[2] != len(frame) - 3:
        raise ValueError(
            f"{name}: payload length says {frame[2]}, frame contains {len(frame) - 3}"
        )


def parse_parameters(name: str, frame: bytes) -> list[bytes]:
    payload = frame[3:]
    expected_count = payload[0]
    parameters = []
    offset = 1

    while offset < len(payload):
        id_size = 2 if payload[offset] == 0xA0 else 1
        length_offset = offset + id_size
        if length_offset >= len(payload):
            raise ValueError(f"{name}: truncated parameter at payload offset {offset}")

        end = length_offset + 1 + payload[length_offset]
        if end > len(payload):
            raise ValueError(f"{name}: truncated parameter value at payload offset {offset}")

        parameters.append(payload[offset:end])
        offset = end

    if len(parameters) != expected_count:
        raise ValueError(
            f"{name}: parameter count says {expected_count}, parsed {len(parameters)}"
        )

    return parameters


def split_frame(name: str, frame: bytes, max_frame_size: int) -> list[bytes]:
    if frame[0] != 0x20 or frame[1] != 0x02:
        return [frame]

    parameters = parse_parameters(name, frame)
    frames = []
    chunk = []
    chunk_size = 4

    for parameter in parameters:
        parameter_frame_size = 4 + len(parameter)
        if parameter_frame_size > 258:
            raise ValueError(f"{name}: parameter is too large for one NCI control packet")

        if chunk and chunk_size + len(parameter) > max_frame_size:
            payload = bytes((len(chunk),)) + b"".join(chunk)
            frames.append(bytes((0x20, 0x02, len(payload))) + payload)
            chunk = []
            chunk_size = 4

        chunk.append(parameter)
        chunk_size += len(parameter)

    if chunk:
        payload = bytes((len(chunk),)) + b"".join(chunk)
        frames.append(bytes((0x20, 0x02, len(payload))) + payload)

    return frames


def take(arrays: dict[str, bytes], keys: tuple[str, ...]) -> list[tuple[str, bytes]]:
    result = []
    for key in keys:
        if key not in arrays:
            raise ValueError(f"required array {key} is missing")
        validate_frame(key, arrays[key])
        result.append((key, arrays[key]))
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True, type=pathlib.Path)
    parser.add_argument("--rf-config", required=True, type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument(
        "--max-frame-size",
        type=int,
        default=DEFAULT_MAX_FRAME_SIZE,
        help="maximum output NCI frame size when a command has multiple parameters",
    )
    args = parser.parse_args()

    if not 4 <= args.max_frame_size <= 258:
        parser.error("--max-frame-size must be between 4 and 258")

    try:
        base = parse_arrays(args.config, BASE_KEYS + TRAILING_BASE_KEYS)
        rf = parse_arrays(args.rf_config, RF_KEYS + TRAILING_RF_KEYS)
        frames = (
            take(base, BASE_KEYS)
            + take(rf, RF_KEYS)
            + take(base, TRAILING_BASE_KEYS)
            + take(rf, TRAILING_RF_KEYS)
        )
    except (OSError, ValueError) as error:
        print(error, file=sys.stderr)
        return 1

    output_frames = []
    for name, frame in frames:
        output_frames.extend(split_frame(name, frame, args.max_frame_size))

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(b"".join(output_frames))

    print(f"wrote {args.output} ({args.output.stat().st_size} bytes)")
    for name, frame in frames:
        split = split_frame(name, frame, args.max_frame_size)
        print(f"  {name}: {len(frame)} input bytes -> {len(split)} frame(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
