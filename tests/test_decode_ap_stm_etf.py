import importlib.util
import io
import pathlib
import sys
import unittest
import unittest.mock


ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "decode_ap_stm_etf.py"
SPEC = importlib.util.spec_from_file_location("decode_ap_stm_etf", SCRIPT)
decoder = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = decoder
SPEC.loader.exec_module(decoder)


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
        frame[0] = 1  # source ID 0, followed by zero data bytes.
        frames.append(bytes(frame))
    return b"".join(frames)


class ApStmEtfDecoderTests(unittest.TestCase):
    def test_deformats_synthetic_core_sight_frames(self):
        stream = b"\xff" * 10 + b"\x0f" + b"pub"
        frames = encode_etf_frames(7, stream)

        streams = decoder.deformat_tmc_etf(frames)

        self.assertEqual(streams[0].trace_id, 0)
        self.assertEqual(streams[0].data, b"\x00" * 14)
        self.assertEqual(streams[1].trace_id, 7)
        self.assertEqual(streams[1].data, stream)

    def test_decodes_p_basic_packet_subset(self):
        payload = b"PUBLIC_STM_TEST\n"
        nibbles = []
        nibbles += [0xF] * 21 + [0x0]  # ASYNC
        nibbles += [0xF, 0x0, 0x0, 0x3]  # VERSION 3
        nibbles += [0xF, 0x0, 0x8] + [0] * 8  # FREQ 0
        nibbles += [0x1] + stp_value(0x40, 2)  # M8
        nibbles += [0xF, 0x3] + stp_value(0x280A, 4)  # C16
        nibbles += stp_data_packet(0xA, payload[:4]) + [0x1, 0x2]  # D32_MTS + TS
        cursor = 4
        while cursor + 4 <= len(payload):
            nibbles += stp_data_packet(0x6, payload[cursor : cursor + 4])
            cursor += 4
        if cursor < len(payload):
            nibbles += stp_data_packet(0x4, payload[cursor:])
        nibbles += [0xF, 0xE]  # FLAG

        packets = decoder.decode_stm(nibbles_to_bytes(nibbles))

        self.assertEqual(packets[0].kind, "ASYNC")
        self.assertEqual(packets[1].kind, "VERSION")
        self.assertEqual(packets[3].kind, "M8")
        self.assertEqual(packets[3].master, 0x40)
        self.assertEqual(packets[4].kind, "C16")
        self.assertEqual(packets[4].channel, 0x280A)
        self.assertEqual(decoder.payload_from_packets(packets), payload)

    def test_cli_marker_check_fails_closed(self):
        payload = b"PUBLIC_STM_TEST\n"
        nibbles = [0xF] * 21 + [0x0]
        nibbles += [0xF, 0x0, 0x0, 0x3]
        nibbles += [0x1] + stp_value(0x40, 2)
        nibbles += [0xF, 0x3] + stp_value(0x280A, 4)
        nibbles += stp_data_packet(0x6, payload[:4])
        nibbles += [0xF, 0xE]
        frames = encode_etf_frames(1, nibbles_to_bytes(nibbles))

        tmp = self.enterContext(
            unittest.mock.patch("pathlib.Path.read_bytes", return_value=frames)
        )
        self.assertIsNotNone(tmp)
        with unittest.mock.patch("sys.stdout", new=io.StringIO()):
            self.assertEqual(
                decoder.main(["ignored.bin", "--expect-marker", "not-the-marker"]), 1
            )


if __name__ == "__main__":
    unittest.main()
