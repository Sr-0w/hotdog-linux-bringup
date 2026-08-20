#!/usr/bin/env python3
"""Offline tests for helpers/qdssc-client.py."""

from __future__ import annotations

import contextlib
import importlib.util
import io
from pathlib import Path
import struct
import sys
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "helpers/qdssc-client.py"
ENDPOINTS = [(51, 1, 90, 9, 14)]


def load_tool_module():
    spec = importlib.util.spec_from_file_location("qdssc_client", SCRIPT)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class FakeTransport:
    def __init__(self, responses):
        self.responses = list(responses)
        self.sent = []
        self.closed = False

    def send(self, node, port, packet):
        self.sent.append((node, port, packet))

    def recv(self):
        if not self.responses:
            raise AssertionError("unexpected QMI request")
        response = self.responses.pop(0)
        if isinstance(response, Exception):
            raise response
        return response

    def close(self):
        self.closed = True


def qmi_response(module, txn, msg_id, result=0, error=0, state=None):
    tlvs = module.tlv(2, struct.pack("<HH", result, error))
    if state is not None:
        tlvs += module.tlv(0x10, struct.pack("<I", state))
    return struct.pack("<BHHH", 2, txn, msg_id, len(tlvs)) + tlvs


def qmi_response_with_tlvs(txn, msg_id, tlvs, msg_type=2):
    return struct.pack("<BHHH", msg_type, txn, msg_id, len(tlvs)) + tlvs


def qmi_response_with_result_payload(module, txn, msg_id, result_payload,
                                     state=None):
    tlvs = module.tlv(2, result_payload)
    if state is not None:
        tlvs += module.tlv(0x10, struct.pack("<I", state))
    return qmi_response_with_tlvs(txn, msg_id, tlvs)


def success(module, txn, msg_id, state=None):
    return qmi_response(module, txn, msg_id, state=state)


def qmi_error(module, txn, msg_id, error):
    return qmi_response(module, txn, msg_id, result=1, error=error)


class QdsscClientTests(unittest.TestCase):
    def setUp(self):
        self.module = load_tool_module()

    def run_client(self, argv, responses, endpoints=None):
        fake = FakeTransport(responses)
        args = self.module.build_parser().parse_args(argv)
        endpoint_rows = ENDPOINTS if endpoints is None else endpoints
        out = io.StringIO()
        err = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = self.module.run(
                args,
                endpoint_provider=lambda: endpoint_rows,
                transport_factory=lambda: fake,
            )
        return rc, out.getvalue(), err.getvalue(), fake

    def run_main(self, argv, responses=None, endpoints=None):
        fake = FakeTransport(responses or [])
        endpoint_rows = ENDPOINTS if endpoints is None else endpoints
        out = io.StringIO()
        err = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = self.module.main(
                argv,
                endpoint_provider=lambda: endpoint_rows,
                transport_factory=lambda: fake,
            )
        return rc, out.getvalue(), err.getvalue(), fake

    def read_with_first_response(self, first_response):
        m = self.module
        return [
            first_response,
            success(m, 2, m.QMI_GET_ENTITY, state=0),
            success(m, 3, m.QMI_GET_ENTITY, state=0),
            success(m, 4, m.QMI_GET_ENTITY, state=0),
            success(m, 5, m.QMI_GET_ENTITY, state=0),
        ]

    def sent_packets(self, fake):
        return [packet for _, _, packet in fake.sent]

    def test_default_mode_only_sends_gets(self):
        m = self.module
        responses = [
            success(m, 1, m.QMI_GET_SWT, state=0),
            success(m, 2, m.QMI_GET_ENTITY, state=0),
            success(m, 3, m.QMI_GET_ENTITY, state=0),
            success(m, 4, m.QMI_GET_ENTITY, state=0),
            success(m, 5, m.QMI_GET_ENTITY, state=0),
        ]
        rc, output, _stderr, fake = self.run_client([], responses)

        expected = [
            "00010020000000",
            "0002002200070001040001000000",
            "000300220007000104000b000000",
            "000400220007000104000c000000",
            "000500220007000104000d000000",
        ]
        self.assertEqual(rc, 0, output)
        self.assertEqual([packet.hex() for packet in self.sent_packets(fake)],
                         expected)
        self.assertTrue(fake.closed)

    def test_enable_and_disable_are_mutually_exclusive(self):
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            with self.assertRaises(SystemExit) as raised:
                self.module.build_parser().parse_args([
                    "--enable", "--disable", "--instance", "90",
                ])
        self.assertEqual(raised.exception.code, 2)

    def test_mutating_mode_requires_explicit_instance(self):
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            with self.assertRaises(SystemExit) as raised:
                self.module.main(["--disable"],
                                 endpoint_provider=lambda: ENDPOINTS,
                                 transport_factory=lambda: FakeTransport([]))
        self.assertEqual(raised.exception.code, 2)

    def test_mutating_mode_rejects_duplicate_instance_argument(self):
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            with self.assertRaises(SystemExit) as raised:
                self.module.main(["--disable", "--instance", "90",
                                  "--instance", "90"],
                                 endpoint_provider=lambda: ENDPOINTS,
                                 transport_factory=lambda: FakeTransport([]))
        self.assertEqual(raised.exception.code, 2)
        self.assertIn("duplicate --instance value", err.getvalue())

    def test_mutating_mode_rejects_multiple_instances(self):
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            with self.assertRaises(SystemExit) as raised:
                self.module.main(["--enable", "--instance", "8",
                                  "--instance", "12"],
                                 endpoint_provider=lambda: ENDPOINTS,
                                 transport_factory=lambda: FakeTransport([]))
        self.assertEqual(raised.exception.code, 2)
        self.assertIn("exactly one --instance", err.getvalue())

    def test_instance_validation_is_strict(self):
        parser = self.module.build_parser()
        args = parser.parse_args(["--instance", "0x5a"])
        self.assertEqual(args.instance, [90])
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            with self.assertRaises(SystemExit) as raised:
                parser.parse_args(["--instance", "-1"])
        self.assertEqual(raised.exception.code, 2)

    def test_disable_order_and_payloads_are_exact(self):
        m = self.module
        responses = [
            success(m, 1, m.QMI_SET_ENTITY),
            success(m, 2, m.QMI_SET_ENTITY),
            success(m, 3, m.QMI_SET_ENTITY),
            success(m, 4, m.QMI_SET_ENTITY),
            success(m, 5, m.QMI_SET_SWT),
            success(m, 6, m.QMI_GET_SWT, state=0),
            success(m, 7, m.QMI_GET_ENTITY, state=0),
            success(m, 8, m.QMI_GET_ENTITY, state=0),
            success(m, 9, m.QMI_GET_ENTITY, state=0),
            success(m, 10, m.QMI_GET_ENTITY, state=0),
        ]
        rc, output, _stderr, fake = self.run_client(
            ["--disable", "--instance", "90"], responses)

        expected = [
            "00010023000e000104000100000002040000000000",
            "00020023000e000104000b00000002040000000000",
            "00030023000e000104000c00000002040000000000",
            "00040023000e000104000d00000002040000000000",
            "0005002100070001040000000000",
            "00060020000000",
            "0007002200070001040001000000",
            "000800220007000104000b000000",
            "000900220007000104000c000000",
            "000a00220007000104000d000000",
        ]
        self.assertEqual(rc, 0, output)
        self.assertEqual([packet.hex() for packet in self.sent_packets(fake)],
                         expected)
        self.assertIn("set software trace=disabled: result=0 error=0",
                      output)

    def test_enable_order_and_payloads_are_exact(self):
        m = self.module
        responses = [
            success(m, 1, m.QMI_SET_SWT),
            success(m, 2, m.QMI_SET_ENTITY),
            success(m, 3, m.QMI_SET_ENTITY),
            success(m, 4, m.QMI_SET_ENTITY),
            success(m, 5, m.QMI_SET_ENTITY),
            success(m, 6, m.QMI_GET_SWT, state=1),
            success(m, 7, m.QMI_GET_ENTITY, state=1),
            success(m, 8, m.QMI_GET_ENTITY, state=1),
            success(m, 9, m.QMI_GET_ENTITY, state=1),
            success(m, 10, m.QMI_GET_ENTITY, state=1),
        ]
        rc, output, _stderr, fake = self.run_client(
            ["--enable", "--instance", "90"], responses)

        expected = [
            "0001002100070001040001000000",
            "00020023000e000104000100000002040001000000",
            "00030023000e000104000b00000002040001000000",
            "00040023000e000104000c00000002040001000000",
            "00050023000e000104000d00000002040001000000",
            "00060020000000",
            "0007002200070001040001000000",
            "000800220007000104000b000000",
            "000900220007000104000c000000",
            "000a00220007000104000d000000",
        ]
        self.assertEqual(rc, 0, output)
        self.assertEqual([packet.hex() for packet in self.sent_packets(fake)],
                         expected)
        self.assertIn("set software trace=enabled: result=0 error=0", output)

    def test_qmi_error94_is_reported_and_nonzero(self):
        m = self.module
        responses = [
            qmi_error(m, 1, m.QMI_SET_ENTITY, 94),
            success(m, 2, m.QMI_SET_ENTITY),
            success(m, 3, m.QMI_SET_ENTITY),
            success(m, 4, m.QMI_SET_ENTITY),
            success(m, 5, m.QMI_SET_SWT),
            success(m, 6, m.QMI_GET_SWT, state=0),
            success(m, 7, m.QMI_GET_ENTITY, state=0),
            success(m, 8, m.QMI_GET_ENTITY, state=0),
            success(m, 9, m.QMI_GET_ENTITY, state=0),
            success(m, 10, m.QMI_GET_ENTITY, state=0),
        ]
        rc, output, _stderr, _fake = self.run_client(
            ["--disable", "--instance", "90"], responses)

        self.assertEqual(rc, 1)
        self.assertIn("error=94 (NOT_SUPPORTED)", output)

    def test_partial_failure_still_attempts_global_swt_disable(self):
        m = self.module
        responses = [
            TimeoutError("mock receive timeout"),
            success(m, 2, m.QMI_SET_ENTITY),
            success(m, 3, m.QMI_SET_ENTITY),
            success(m, 4, m.QMI_SET_ENTITY),
            success(m, 5, m.QMI_SET_SWT),
            success(m, 6, m.QMI_GET_SWT, state=0),
            success(m, 7, m.QMI_GET_ENTITY, state=0),
            success(m, 8, m.QMI_GET_ENTITY, state=0),
            success(m, 9, m.QMI_GET_ENTITY, state=0),
            success(m, 10, m.QMI_GET_ENTITY, state=0),
        ]
        rc, output, _stderr, fake = self.run_client(
            ["--disable", "--instance", "90"], responses)
        msg_ids = [
            m.split_qmi(packet)[2] for packet in self.sent_packets(fake)
        ]

        self.assertEqual(rc, 1)
        self.assertIn("transport-error=mock receive timeout", output)
        self.assertEqual(len(msg_ids), 10)
        self.assertEqual(msg_ids[4], m.QMI_SET_SWT)

    def test_malformed_set_response_is_not_cleared_by_final_get(self):
        m = self.module
        responses = [
            qmi_response_with_tlvs(1, m.QMI_SET_ENTITY, b""),
            success(m, 2, m.QMI_SET_ENTITY),
            success(m, 3, m.QMI_SET_ENTITY),
            success(m, 4, m.QMI_SET_ENTITY),
            success(m, 5, m.QMI_SET_SWT),
            success(m, 6, m.QMI_GET_SWT, state=0),
            success(m, 7, m.QMI_GET_ENTITY, state=0),
            success(m, 8, m.QMI_GET_ENTITY, state=0),
            success(m, 9, m.QMI_GET_ENTITY, state=0),
            success(m, 10, m.QMI_GET_ENTITY, state=0),
        ]
        rc, output, _stderr, _fake = self.run_client(
            ["--disable", "--instance", "90"], responses)

        self.assertEqual(rc, 1)
        self.assertIn("missing QMI result TLV", output)
        self.assertIn("software trace: result=0 error=0 state=disabled",
                      output)

    def test_final_get_state_must_confirm_disable(self):
        m = self.module
        responses = [
            success(m, 1, m.QMI_SET_ENTITY),
            success(m, 2, m.QMI_SET_ENTITY),
            success(m, 3, m.QMI_SET_ENTITY),
            success(m, 4, m.QMI_SET_ENTITY),
            success(m, 5, m.QMI_SET_SWT),
            success(m, 6, m.QMI_GET_SWT, state=1),
            success(m, 7, m.QMI_GET_ENTITY, state=0),
            success(m, 8, m.QMI_GET_ENTITY, state=0),
            success(m, 9, m.QMI_GET_ENTITY, state=0),
            success(m, 10, m.QMI_GET_ENTITY, state=0),
        ]
        rc, output, _stderr, _fake = self.run_client(
            ["--disable", "--instance", "90"], responses)

        self.assertEqual(rc, 1)
        self.assertIn("final state: disabled not confirmed", output)

    def test_strict_parser_rejects_short_header(self):
        with self.assertRaisesRegex(RuntimeError, "short QMI header"):
            self.module.split_qmi(b"\x02")

    def test_strict_parser_rejects_header_length_mismatch(self):
        m = self.module
        malformed = struct.pack("<BHHH", 2, 1, m.QMI_GET_SWT, 8)
        malformed += m.tlv(2, struct.pack("<HH", 0, 0))
        responses = self.read_with_first_response(malformed)
        rc, output, _stderr, _fake = self.run_client([], responses)

        self.assertEqual(rc, 1)
        self.assertIn("QMI length mismatch", output)

    def test_strict_parser_rejects_trailing_bytes(self):
        m = self.module
        malformed = success(m, 1, m.QMI_GET_SWT, state=0) + b"\x00"
        responses = self.read_with_first_response(malformed)
        rc, output, _stderr, _fake = self.run_client([], responses)

        self.assertEqual(rc, 1)
        self.assertIn("QMI length mismatch", output)

    def test_strict_parser_rejects_truncated_tlv_header(self):
        m = self.module
        malformed = struct.pack("<BHHH", 2, 1, m.QMI_GET_SWT, 1) + b"\x02"
        responses = self.read_with_first_response(malformed)
        rc, output, _stderr, _fake = self.run_client([], responses)

        self.assertEqual(rc, 1)
        self.assertIn("truncated QMI TLV header", output)

    def test_strict_parser_rejects_truncated_tlv_value(self):
        m = self.module
        body = b"\x02\x04\x00\x00"
        malformed = struct.pack("<BHHH", 2, 1, m.QMI_GET_SWT,
                                len(body)) + body
        responses = self.read_with_first_response(malformed)
        rc, output, _stderr, _fake = self.run_client([], responses)

        self.assertEqual(rc, 1)
        self.assertIn("truncated QMI TLV value type 2", output)

    def test_strict_parser_requires_result_tlv(self):
        m = self.module
        malformed = qmi_response_with_tlvs(
            1, m.QMI_GET_SWT, m.tlv(0x10, struct.pack("<I", 0)))
        responses = self.read_with_first_response(malformed)
        rc, output, _stderr, _fake = self.run_client([], responses)

        self.assertEqual(rc, 1)
        self.assertIn("missing QMI result TLV", output)

    def test_strict_parser_requires_result_tlv_length_four(self):
        m = self.module
        malformed = qmi_response_with_tlvs(
            1, m.QMI_GET_SWT, m.tlv(2, b"\x00\x00"))
        responses = self.read_with_first_response(malformed)
        rc, output, _stderr, _fake = self.run_client([], responses)

        self.assertEqual(rc, 1)
        self.assertIn("malformed QMI result TLV length 2", output)

    def test_read_response_rejects_six_byte_result_tlv(self):
        m = self.module
        malformed = bytes.fromhex(
            "02010020001000"
            "020600000000000000"
            "10040000000000")
        responses = self.read_with_first_response(malformed)
        rc, output, _stderr, _fake = self.run_client([], responses)

        self.assertEqual(rc, 1)
        self.assertIn("malformed QMI result TLV length 6", output)

    def test_result_tlv_lengths_must_be_exactly_four(self):
        m = self.module
        for length in (0, 1, 3, 5, 6):
            with self.subTest(length=length):
                malformed = qmi_response_with_result_payload(
                    m, 1, m.QMI_GET_SWT, bytes(length), state=0)
                responses = self.read_with_first_response(malformed)
                rc, output, _stderr, _fake = self.run_client([], responses)

                self.assertEqual(rc, 1)
                self.assertIn("malformed QMI result TLV length %d" % length,
                              output)

    def test_disable_six_byte_result_tlv_keeps_nonzero_after_safe_get(self):
        m = self.module
        malformed_set_entity = bytes.fromhex(
            "02010023000900"
            "020600000000000000")
        responses = [
            malformed_set_entity,
            success(m, 2, m.QMI_SET_ENTITY),
            success(m, 3, m.QMI_SET_ENTITY),
            success(m, 4, m.QMI_SET_ENTITY),
            success(m, 5, m.QMI_SET_SWT),
            success(m, 6, m.QMI_GET_SWT, state=0),
            success(m, 7, m.QMI_GET_ENTITY, state=0),
            success(m, 8, m.QMI_GET_ENTITY, state=0),
            success(m, 9, m.QMI_GET_ENTITY, state=0),
            success(m, 10, m.QMI_GET_ENTITY, state=0),
        ]
        rc, output, _stderr, fake = self.run_client(
            ["--disable", "--instance", "90"], responses)
        msg_ids = [
            m.split_qmi(packet)[2] for packet in self.sent_packets(fake)
        ]

        self.assertEqual(rc, 1)
        self.assertIn("malformed QMI result TLV length 6", output)
        self.assertIn("software trace: result=0 error=0 state=disabled",
                      output)
        self.assertEqual(msg_ids, [
            m.QMI_SET_ENTITY,
            m.QMI_SET_ENTITY,
            m.QMI_SET_ENTITY,
            m.QMI_SET_ENTITY,
            m.QMI_SET_SWT,
            m.QMI_GET_SWT,
            m.QMI_GET_ENTITY,
            m.QMI_GET_ENTITY,
            m.QMI_GET_ENTITY,
            m.QMI_GET_ENTITY,
        ])

    def test_recv_oserror_is_reported_nonzero(self):
        m = self.module
        responses = [
            OSError("mock recv error"),
            success(m, 2, m.QMI_GET_ENTITY, state=0),
            success(m, 3, m.QMI_GET_ENTITY, state=0),
            success(m, 4, m.QMI_GET_ENTITY, state=0),
            success(m, 5, m.QMI_GET_ENTITY, state=0),
        ]
        rc, output, _stderr, _fake = self.run_client([], responses)

        self.assertEqual(rc, 1)
        self.assertIn("transport-error=mock recv error", output)

    def test_qrtr_lookup_timeout_is_reported(self):
        m = self.module
        error = m.subprocess.TimeoutExpired(["qrtr-lookup"], timeout=20)
        with patch.object(m.subprocess, "run", side_effect=error):
            with self.assertRaisesRegex(RuntimeError, "qrtr-lookup timed out"):
                m.endpoints()

    def test_qrtr_lookup_failure_is_reported(self):
        m = self.module
        error = m.subprocess.CalledProcessError(
            1, ["qrtr-lookup"], stderr="mock failure")
        with patch.object(m.subprocess, "run", side_effect=error):
            with self.assertRaisesRegex(RuntimeError, "qrtr-lookup failed"):
                m.endpoints()

    def test_no_qdssc_service_is_nonzero(self):
        rc, _output, stderr, fake = self.run_main([], endpoints=[])

        self.assertEqual(rc, 1)
        self.assertIn("QDSSC service is not registered", stderr)
        self.assertEqual(self.sent_packets(fake), [])

    def test_unknown_instance_is_nonzero(self):
        rc, _output, stderr, fake = self.run_main(
            ["--disable", "--instance", "91"], endpoints=ENDPOINTS)

        self.assertEqual(rc, 1)
        self.assertIn("requested QDSSC instance", stderr)
        self.assertEqual(self.sent_packets(fake), [])

    def test_duplicate_service_row_is_rejected(self):
        rc, _output, stderr, fake = self.run_main(
            ["--disable", "--instance", "90"],
            endpoints=[ENDPOINTS[0], ENDPOINTS[0]])

        self.assertEqual(rc, 1)
        self.assertIn("duplicate QDSSC service row", stderr)
        self.assertEqual(self.sent_packets(fake), [])

    def test_duplicate_qrtr_endpoint_is_rejected(self):
        endpoints = [
            (51, 1, 90, 9, 14),
            (51, 1, 91, 9, 14),
        ]
        rc, _output, stderr, fake = self.run_main(
            ["--disable", "--instance", "90"], endpoints=endpoints)

        self.assertEqual(rc, 1)
        self.assertIn("duplicate QDSSC QRTR endpoint", stderr)
        self.assertEqual(self.sent_packets(fake), [])

    def test_ambiguous_instance_selection_is_rejected(self):
        endpoints = [
            (51, 1, 90, 9, 14),
            (51, 1, 90, 9, 15),
        ]
        rc, _output, stderr, fake = self.run_main(
            ["--disable", "--instance", "90"], endpoints=endpoints)

        self.assertEqual(rc, 1)
        self.assertIn("matched 2 endpoints", stderr)
        self.assertEqual(self.sent_packets(fake), [])


if __name__ == "__main__":
    unittest.main()
