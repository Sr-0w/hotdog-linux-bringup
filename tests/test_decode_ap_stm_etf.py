import importlib.util
import io
import pathlib
import random
import sys
import tempfile
import unittest
import unittest.mock


ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "decode_ap_stm_etf.py"
SPEC = importlib.util.spec_from_file_location("decode_ap_stm_etf", SCRIPT)
decoder = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = decoder
SPEC.loader.exec_module(decoder)


PUBLIC_TS_V3_FULL = 0x123456789ABCDEF0
PUBLIC_TS_V3_PARTIAL_RAW = 0x5A
PUBLIC_TS_V3_RECONSTRUCTED = 0x123456789ABCDE5A

PUBLIC_TS_V4_FULL = 0x0F1E2D3C4B5A6978
PUBLIC_TS_V4_FULL_RAW = decoder.bin_to_gray(PUBLIC_TS_V4_FULL)
PUBLIC_TS_V4_PARTIAL_RAW = 0x3C
PUBLIC_TS_V4_RECONSTRUCTED = 0x0F1E2D3C4B5A69D7


def nibbles_to_bytes(nibbles):
    out = bytearray()
    for i in range(0, len(nibbles), 2):
        lo = nibbles[i]
        hi = nibbles[i + 1] if i + 1 < len(nibbles) else 0
        out.append(lo | (hi << 4))
    return bytes(out)


def stp_value(value, nibbles):
    return [(value >> shift) & 0xF for shift in range((nibbles - 1) * 4, -1, -4)]


def stp_data_packet(opcode, payload):
    value = int.from_bytes(payload, "little")
    return [opcode] + stp_value(value, len(payload) * 2)


def stp_data_packet_ts(extended_opcode, payload, timestamp_raw, timestamp_bits):
    return (
        [0xF, extended_opcode]
        + stp_value(int.from_bytes(payload, "little"), len(payload) * 2)
        + timestamp_nibbles(timestamp_raw, timestamp_bits)
    )


def timestamp_nibbles(raw, bits):
    if bits % 4:
        raise ValueError("synthetic timestamps are nibble-aligned")
    if bits == 56:
        count = 0xD
        nibble_count = 14
    elif bits == 64:
        count = 0xE
        nibble_count = 16
    else:
        nibble_count = bits // 4
        count = nibble_count
    return [count] + stp_value(raw, nibble_count)


def stm_prefix(master=0x40, channel=0x280A, version=3):
    nibbles = []
    nibbles += [0xF] * 21 + [0x0]  # ASYNC
    nibbles += [0xF, 0x0, 0x0, version]  # VERSION
    nibbles += [0xF, 0x0, 0x8] + [0] * 8  # FREQ 0
    nibbles += [0x1] + stp_value(master, 2)  # M8
    nibbles += [0xF, 0x3] + stp_value(channel, 4)  # C16
    return nibbles


def synthetic_marker_stream(payload=b"PUBLIC_STM_TEST\n", master=0x40, channel=0x280A):
    nibbles = stm_prefix(master=master, channel=channel, version=3)
    if payload:
        first = payload[:4]
        nibbles += stp_data_packet_ts(0x6, first, PUBLIC_TS_V3_FULL, 64)  # D32_TS
    cursor = 4
    while cursor + 4 <= len(payload):
        nibbles += stp_data_packet(0x6, payload[cursor : cursor + 4])
        cursor += 4
    if cursor < len(payload):
        nibbles += stp_data_packet(0x4, payload[cursor:])
    nibbles += [0xF, 0xE]  # FLAG
    return nibbles_to_bytes(nibbles)


def encode_etf_frames(trace_id, stream, pad_frames=1):
    payload = bytes(stream)
    frames = []
    cursor = 0
    current_trace_id = None

    while cursor < len(payload):
        frame = [0] * 16
        aux = 0
        slot = 0

        if current_trace_id != trace_id:
            frame[0] = (trace_id << 1) | 1
            frame[1] = payload[cursor]
            cursor += 1
            current_trace_id = trace_id
            slot = 2

        while slot < 15 and cursor < len(payload):
            if slot % 2 == 0:
                pair = slot // 2
                byte = payload[cursor]
                frame[slot] = byte & 0xFE
                if byte & 1:
                    aux |= 1 << pair
                cursor += 1
                if cursor < len(payload) and slot + 1 < 15:
                    frame[slot + 1] = payload[cursor]
                    cursor += 1
                    slot += 2
                else:
                    slot += 1
            else:
                frame[slot] = payload[cursor]
                cursor += 1
                slot += 1

        frame[15] = aux
        frames.append(bytes(frame))

    for _ in range(pad_frames):
        frame = bytearray(16)
        frame[0] = 1  # Source ID 0, followed by zero data bytes.
        frames.append(bytes(frame))
    return b"".join(frames)


class ApStmEtfDecoderTests(unittest.TestCase):
    def test_deformats_synthetic_core_sight_frames_with_atid0_padding(self):
        stream = b"\xff" * 10 + b"\x0f" + b"pub"
        frames = encode_etf_frames(7, stream)

        streams = decoder.deformat_tmc_etf(frames)

        self.assertEqual(streams[0].trace_id, 0)
        self.assertEqual(streams[0].data, b"\x00" * 14)
        self.assertEqual(decoder.classify_stream(streams[0]), "zero-padding")
        self.assertEqual(streams[1].trace_id, 7)
        self.assertEqual(streams[1].data, stream)

    def test_decodes_p_basic_packet_subset_and_hw_override_channel(self):
        packets = decoder.decode_stm(synthetic_marker_stream())

        self.assertEqual(packets[0].kind, "ASYNC")
        self.assertEqual(packets[1].kind, "VERSION")
        self.assertEqual(packets[3].kind, "M8")
        self.assertEqual(packets[3].master, 0x40)
        self.assertEqual(packets[4].kind, "C16")
        self.assertEqual(packets[4].master, 0x40)
        self.assertEqual(packets[4].channel, 0x280A)
        self.assertEqual(packets[4].channel & 0xFF, 0x0A)
        self.assertEqual(decoder.payload_from_packets(packets), b"PUBLIC_STM_TEST\n")

    def test_little_endian_payload_reconstruction(self):
        packets = decoder.decode_stm(nibbles_to_bytes(stm_prefix() + stp_data_packet(0x6, b"ABCD")))

        data_packets = [packet for packet in packets if packet.kind == "D32"]
        self.assertEqual(data_packets[0].value, 0x44434241)
        self.assertEqual(data_packets[0].payload, b"ABCD")

    def test_timestamp_reconstruction_natural_v3_full64_then_partial8(self):
        nibbles = stm_prefix(version=3)
        nibbles += stp_data_packet_ts(0x6, b"ABCD", PUBLIC_TS_V3_FULL, 64)
        nibbles += stp_data_packet_ts(0x4, b"\n", PUBLIC_TS_V3_PARTIAL_RAW, 8)

        packets = decoder.decode_stm(nibbles_to_bytes(nibbles))
        ts_packets = [packet for packet in packets if packet.timestamp_raw is not None]

        self.assertEqual(ts_packets[0].timestamp_raw, PUBLIC_TS_V3_FULL)
        self.assertEqual(ts_packets[0].timestamp_bits, 64)
        self.assertEqual(ts_packets[0].timestamp, PUBLIC_TS_V3_FULL)
        self.assertEqual(ts_packets[1].timestamp_raw, PUBLIC_TS_V3_PARTIAL_RAW)
        self.assertEqual(ts_packets[1].timestamp_bits, 8)
        self.assertEqual(ts_packets[1].timestamp, PUBLIC_TS_V3_RECONSTRUCTED)

    def test_timestamp_reconstruction_gray_v4_full64_then_partial8(self):
        nibbles = stm_prefix(version=4)
        nibbles += stp_data_packet_ts(0x6, b"WXYZ", PUBLIC_TS_V4_FULL_RAW, 64)
        nibbles += stp_data_packet_ts(0x4, b"\n", PUBLIC_TS_V4_PARTIAL_RAW, 8)

        packets = decoder.decode_stm(nibbles_to_bytes(nibbles))
        ts_packets = [packet for packet in packets if packet.timestamp_raw is not None]

        self.assertEqual(ts_packets[0].timestamp_raw, PUBLIC_TS_V4_FULL_RAW)
        self.assertEqual(ts_packets[0].timestamp_bits, 64)
        self.assertEqual(ts_packets[0].timestamp, PUBLIC_TS_V4_FULL)
        self.assertEqual(ts_packets[1].timestamp_raw, PUBLIC_TS_V4_PARTIAL_RAW)
        self.assertEqual(ts_packets[1].timestamp_bits, 8)
        self.assertEqual(ts_packets[1].timestamp, PUBLIC_TS_V4_RECONSTRUCTED)
        self.assertEqual(decoder.bin_to_gray(PUBLIC_TS_V4_RECONSTRUCTED) & 0xFF, 0x3C)

    def test_partial_timestamp_before_full_timestamp_is_none(self):
        nibbles = stm_prefix(version=3)
        nibbles += stp_data_packet_ts(0x4, b"\n", 0xA5, 8)

        packets = decoder.decode_stm(nibbles_to_bytes(nibbles))
        ts_packets = [packet for packet in packets if packet.timestamp_raw is not None]

        self.assertEqual(ts_packets[0].timestamp_raw, 0xA5)
        self.assertEqual(ts_packets[0].timestamp_bits, 8)
        self.assertIsNone(ts_packets[0].timestamp)

    def test_empty_capture_is_rejected_and_cli_exits_two(self):
        with self.assertRaises(decoder.DecodeError):
            decoder.deformat_tmc_etf(b"")
        with unittest.mock.patch("pathlib.Path.read_bytes", return_value=b""):
            with unittest.mock.patch("sys.stdout", new=io.StringIO()):
                with unittest.mock.patch("sys.stderr", new=io.StringIO()):
                    self.assertEqual(decoder.main(["ignored.bin"]), 2)

    def test_all_zero_formatter_capture_is_rejected_and_cli_exits_two(self):
        with self.assertRaises(decoder.DecodeError):
            decoder.deformat_tmc_etf(b"\x00" * 32)
        with unittest.mock.patch("pathlib.Path.read_bytes", return_value=b"\x00" * 32):
            with unittest.mock.patch("sys.stdout", new=io.StringIO()):
                with unittest.mock.patch("sys.stderr", new=io.StringIO()):
                    self.assertEqual(decoder.main(["ignored.bin"]), 2)

    def test_zero_padding_only_capture_has_no_useful_stp_stream(self):
        frames = encode_etf_frames(0, b"\x00" * 14, pad_frames=0)
        streams = decoder.deformat_tmc_etf(frames)
        self.assertEqual(decoder.classify_stream(streams[0]), "zero-padding")

        with unittest.mock.patch("pathlib.Path.read_bytes", return_value=frames):
            with unittest.mock.patch("sys.stdout", new=io.StringIO()):
                with unittest.mock.patch("sys.stderr", new=io.StringIO()):
                    self.assertEqual(decoder.main(["ignored.bin"]), 2)

    def test_hash_mismatch_exit_code(self):
        frames = encode_etf_frames(1, synthetic_marker_stream())
        with unittest.mock.patch("pathlib.Path.read_bytes", return_value=frames):
            with unittest.mock.patch("sys.stdout", new=io.StringIO()):
                self.assertEqual(
                    decoder.main(["ignored.bin", "--expect-sha256", "00" * 32]), 2
                )

    def test_non_multiple_16_capture_is_rejected(self):
        with self.assertRaises(decoder.DecodeError):
            decoder.deformat_tmc_etf(b"\x00")

    def test_malformed_frame_is_rejected(self):
        with self.assertRaises(decoder.DecodeError):
            decoder.deformat_tmc_etf(bytes([0x02]) + b"\x00" * 15)

    def test_unknown_reserved_opcode_is_rejected(self):
        with self.assertRaises(decoder.DecodeError):
            decoder.decode_stm(nibbles_to_bytes([0x2]))

    def test_timestamp_size_0xf_is_rejected(self):
        nibbles = stm_prefix()
        nibbles += [0xF, 0x4] + stp_value(ord("A"), 2) + [0xF]

        with self.assertRaises(decoder.DecodeError):
            decoder.decode_stm(nibbles_to_bytes(nibbles))

    def test_payload_bounds_are_checked(self):
        nibbles = stm_prefix() + [0x6, 0x1, 0x2]  # D32 with only two value nibbles.

        with self.assertRaises(decoder.DecodeError):
            decoder.decode_stm(nibbles_to_bytes(nibbles))

    def test_cli_marker_mismatch_exits_one(self):
        frames = encode_etf_frames(1, synthetic_marker_stream())
        with unittest.mock.patch("pathlib.Path.read_bytes", return_value=frames):
            with unittest.mock.patch("sys.stdout", new=io.StringIO()):
                self.assertEqual(
                    decoder.main(["ignored.bin", "--expect-marker", "not-the-marker"]), 1
                )

    def test_cli_marker_match_exits_zero(self):
        frames = encode_etf_frames(1, synthetic_marker_stream())
        with tempfile.TemporaryDirectory() as tmpdir:
            capture = pathlib.Path(tmpdir) / "synthetic-etf.bin"
            capture.write_bytes(frames)
            with unittest.mock.patch("sys.stdout", new=io.StringIO()):
                self.assertEqual(
                    decoder.main([str(capture), "--expect-marker", "PUBLIC_STM_TEST"]), 0
                )

    def test_deterministic_fuzz_has_no_unbounded_loop(self):
        rng = random.Random(0)
        for _ in range(128):
            size = rng.randrange(0, 80)
            blob = bytes(rng.randrange(256) for _ in range(size))
            try:
                decoder.decode_stm(blob)
            except decoder.DecodeError:
                pass


if __name__ == "__main__":
    unittest.main()
