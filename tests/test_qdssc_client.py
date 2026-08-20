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
        out = io.StringIO()
        err = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = self.module.run(
                args,
                endpoint_provider=lambda: endpoints or ENDPOINTS,
                transport_factory=lambda: fake,
            )
        return rc, out.getvalue(), err.getvalue(), fake

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

        expected = [m.qmi_request(1, m.QMI_GET_SWT)]
        for txn, entity in enumerate(m.ENTITIES.values(), start=2):
            expected.append(
                m.qmi_request(txn, m.QMI_GET_ENTITY,
                              m.entity_payload(entity))
            )
        self.assertEqual(rc, 0, output)
        self.assertEqual(self.sent_packets(fake), expected)
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

        expected = []
        for txn, entity in enumerate(m.ENTITIES.values(), start=1):
            expected.append(
                m.qmi_request(txn, m.QMI_SET_ENTITY,
                              m.entity_payload(entity, 0))
            )
        expected.append(m.qmi_request(5, m.QMI_SET_SWT, m.swt_payload(0)))
        expected.append(m.qmi_request(6, m.QMI_GET_SWT))
        for txn, entity in enumerate(m.ENTITIES.values(), start=7):
            expected.append(
                m.qmi_request(txn, m.QMI_GET_ENTITY,
                              m.entity_payload(entity))
            )
        self.assertEqual(rc, 0, output)
        self.assertEqual(self.sent_packets(fake), expected)
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
            m.qmi_request(1, m.QMI_SET_SWT, m.swt_payload(1)),
        ]
        for txn, entity in enumerate(m.ENTITIES.values(), start=2):
            expected.append(
                m.qmi_request(txn, m.QMI_SET_ENTITY,
                              m.entity_payload(entity, 1))
            )
        expected.append(m.qmi_request(6, m.QMI_GET_SWT))
        for txn, entity in enumerate(m.ENTITIES.values(), start=7):
            expected.append(
                m.qmi_request(txn, m.QMI_GET_ENTITY,
                              m.entity_payload(entity))
            )
        self.assertEqual(rc, 0, output)
        self.assertEqual(self.sent_packets(fake), expected)
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
            RuntimeError("mock receive failure"),
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
        self.assertIn("transport-error=mock receive failure", output)
        self.assertEqual(msg_ids[4], m.QMI_SET_SWT)

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


if __name__ == "__main__":
    unittest.main()
