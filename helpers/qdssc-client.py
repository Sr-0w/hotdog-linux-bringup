#!/usr/bin/env python3
"""Inspect or configure Qualcomm Debug Subsystem Control over QRTR.

The SLPI firmware exposes QDSSC (QMI service 51) once for the sensor root PD
and once for the sensor user PD.  This helper intentionally defaults to
read-only GET queries.  Mutating modes require exactly one explicit
``--instance``, exactly one matching QRTR endpoint and must be used only while
holding the phone lease:

* prepare and verify the AP trace sink before ``--enable``;
* capture only non-private diagnostic data;
* run ``--disable`` after capture to clear the same controls.

Within one QDSSC instance the enable order is global SWT first, then detailed
entities, so the entity streams have a software-trace path to feed.  Rollback
uses the reverse contract: disable entities first, then global SWT.  QMI
result/error fields are always printed; firmware errors such as error 94 are
reported directly and are not translated into success.
"""

import argparse
import ctypes
import ctypes.util
import os
import socket
import struct
import subprocess
import sys


AF_QIPCRTR = 42
QDSSC_SERVICE = 51
QMI_GET_SWT = 0x0020
QMI_SET_SWT = 0x0021
QMI_GET_ENTITY = 0x0022
QMI_SET_ENTITY = 0x0023

ENTITIES = {
    "tds": 1,
    "ulog": 11,
    "prof": 12,
    "diag": 13,
}

QMI_ERRORS = {
    94: "NOT_SUPPORTED",
}

libc = ctypes.CDLL(ctypes.util.find_library("c") or "libc.musl-aarch64.so.1",
                   use_errno=True)


class SockaddrQrtr(ctypes.Structure):
    _fields_ = [("sq_family", ctypes.c_uint16),
                ("sq_node", ctypes.c_uint32),
                ("sq_port", ctypes.c_uint32)]


def fail(what):
    raise OSError(ctypes.get_errno(), "%s: %s" %
                  (what, os.strerror(ctypes.get_errno())))


class QmiResponse:
    def __init__(self, txn, msg_id, tlvs):
        self.txn = txn
        self.msg_id = msg_id
        self.tlvs = tlvs
        self.result, self.error = qmi_result(tlvs, required=True)

    def ok(self):
        return self.result == 0


class QrtrTransport:
    def __init__(self):
        self.fd = libc.socket(AF_QIPCRTR, socket.SOCK_DGRAM, 0)
        if self.fd < 0:
            fail("socket")
        try:
            self._bind()
            libc.setsockopt(self.fd, socket.SOL_SOCKET, socket.SO_RCVTIMEO,
                            struct.pack("qq", 2, 0), 16)
        except Exception:
            self.close()
            raise

    def _bind(self):
        for candidate in range(12):
            address = SockaddrQrtr(AF_QIPCRTR, candidate, 0)
            if libc.bind(self.fd, ctypes.byref(address),
                         ctypes.sizeof(address)) == 0:
                return
        fail("bind")

    def send(self, node, port, packet):
        destination = SockaddrQrtr(AF_QIPCRTR, node, port)
        buf = ctypes.create_string_buffer(packet)
        if libc.sendto(self.fd, buf, len(packet), 0,
                       ctypes.byref(destination),
                       ctypes.sizeof(destination)) < 0:
            fail("sendto")

    def recv(self):
        rx = ctypes.create_string_buffer(4096)
        n = libc.recvfrom(self.fd, rx, len(rx), 0, None, None)
        if n < 0:
            fail("recvfrom")
        return rx.raw[:n]

    def close(self):
        if self.fd >= 0:
            libc.close(self.fd)
            self.fd = -1


def endpoints():
    try:
        listing = subprocess.run(["qrtr-lookup"], capture_output=True,
                                 text=True, timeout=20,
                                 check=True).stdout
    except subprocess.TimeoutExpired as error:
        raise RuntimeError("qrtr-lookup timed out") from error
    except subprocess.CalledProcessError as error:
        stderr = error.stderr.strip() if error.stderr else ""
        message = "qrtr-lookup failed"
        if stderr:
            message += ": %s" % stderr
        raise RuntimeError(message) from error

    found = []
    for line in listing.splitlines():
        fields = line.split()
        if len(fields) >= 5 and fields[0] == str(QDSSC_SERVICE):
            found.append(tuple(map(int, fields[:5])))
    return found


def qmi_request(txn, msg_id, tlvs=b""):
    return struct.pack("<BHHH", 0, txn, msg_id, len(tlvs)) + tlvs


def tlv(number, payload):
    return struct.pack("<BH", number, len(payload)) + payload


def swt_payload(state):
    return tlv(1, struct.pack("<I", state))


def entity_payload(entity, state=None):
    payload = tlv(1, struct.pack("<I", entity))
    if state is not None:
        payload += tlv(2, struct.pack("<I", state))
    return payload


def split_qmi(buf):
    if len(buf) < 7:
        raise RuntimeError("short QMI header")
    msg_type, txn, msg_id, length = struct.unpack_from("<BHHH", buf)
    if len(buf) != 7 + length:
        raise RuntimeError("QMI length mismatch: header=%d actual=%d" %
                           (length, len(buf) - 7))
    body = buf[7:7 + length]
    values = {}
    offset = 0
    while offset < len(body):
        if offset + 3 > len(body):
            raise RuntimeError("truncated QMI TLV header at offset %d" %
                               offset)
        number, size = struct.unpack_from("<BH", body, offset)
        offset += 3
        if offset + size > len(body):
            raise RuntimeError("truncated QMI TLV value type %d" % number)
        if number in values:
            raise RuntimeError("duplicate QMI TLV type %d" % number)
        values[number] = body[offset:offset + size]
        offset += size
    return msg_type, txn, msg_id, values


def qmi_result(response_tlvs, required=False):
    if 2 not in response_tlvs:
        if required:
            raise RuntimeError("missing QMI result TLV")
        return 0, 0
    result = response_tlvs[2]
    if len(result) != 4:
        if required:
            raise RuntimeError("malformed QMI result TLV length %d" %
                               len(result))
        return 0, 0
    return struct.unpack("<HH", result)


def transact(transport, node, port, txn, msg_id, tlvs=b""):
    packet = qmi_request(txn, msg_id, tlvs)
    transport.send(node, port, packet)
    decoded = split_qmi(transport.recv())
    msg_type, response_txn, response_id, response_tlvs = decoded
    if msg_type != 2:
        raise RuntimeError("unexpected QMI message type %d" % msg_type)
    if response_txn != txn or response_id != msg_id:
        raise RuntimeError("unexpected QMI response")
    qmi_result(response_tlvs, required=True)
    return QmiResponse(response_txn, response_id, response_tlvs)


def state_from_response(response):
    values = response.tlvs if isinstance(response, QmiResponse) else response
    value = values.get(0x10)
    if value is None or len(value) < 4:
        return "not returned"
    return "enabled" if struct.unpack_from("<I", value)[0] else "disabled"


def result_text(response):
    text = "result=%d error=%d" % (response.result, response.error)
    if response.error in QMI_ERRORS:
        text += " (%s)" % QMI_ERRORS[response.error]
    return text


def report_response(label, response, include_state=False):
    text = "  %s: %s" % (label, result_text(response))
    if include_state:
        text += " state=%s" % state_from_response(response)
    print(text)


def qmi_call(transport, node, port, txn, msg_id, payload, label,
             include_state=False):
    try:
        response = transact(transport, node, port, txn, msg_id, payload)
    except OSError as error:
        print("  %s: transport-error=%s" % (label, error))
        return None, False
    except Exception as error:
        print("  %s: response-error=%s" % (label, error))
        return None, False

    report_response(label, response, include_state)
    return response, response.ok()


def query_state(transport, node, port, txn):
    ok = True
    response, success = qmi_call(transport, node, port, txn, QMI_GET_SWT,
                                 b"", "software trace", True)
    ok = ok and success and state_from_response(response) != "not returned"
    txn += 1

    for name, entity in ENTITIES.items():
        response, success = qmi_call(transport, node, port, txn,
                                     QMI_GET_ENTITY,
                                     entity_payload(entity),
                                     "%-5s" % name, True)
        ok = ok and success and state_from_response(response) != "not returned"
        txn += 1

    return txn, ok


def confirm_state(transport, node, port, txn, wanted):
    ok = True
    response, success = qmi_call(transport, node, port, txn, QMI_GET_SWT,
                                 b"", "software trace", True)
    ok = ok and success and state_from_response(response) == wanted
    txn += 1

    for name, entity in ENTITIES.items():
        response, success = qmi_call(transport, node, port, txn,
                                     QMI_GET_ENTITY,
                                     entity_payload(entity),
                                     "%-5s" % name, True)
        ok = ok and success and state_from_response(response) == wanted
        txn += 1

    if not ok:
        print("  final state: %s not confirmed" % wanted)
    return txn, ok


def inspect_endpoint(transport, node, port, instance, mode):
    print("instance=%d node=%d port=%d" % (instance, node, port))
    txn = 1

    if mode == "read":
        _, ok = query_state(transport, node, port, txn)
        return ok

    ok = True
    if mode == "enable":
        response, success = qmi_call(transport, node, port, txn, QMI_SET_SWT,
                                     swt_payload(1),
                                     "set software trace=enabled")
        ok = ok and success
        txn += 1

        for name, entity in ENTITIES.items():
            response, success = qmi_call(transport, node, port, txn,
                                         QMI_SET_ENTITY,
                                         entity_payload(entity, 1),
                                         "%-5s set=enabled" % name)
            ok = ok and success
            txn += 1

        _, confirmed = confirm_state(transport, node, port, txn, "enabled")
        return ok and confirmed

    if mode == "disable":
        for name, entity in ENTITIES.items():
            response, success = qmi_call(transport, node, port, txn,
                                         QMI_SET_ENTITY,
                                         entity_payload(entity, 0),
                                         "%-5s set=disabled" % name)
            ok = ok and success
            txn += 1

        response, success = qmi_call(transport, node, port, txn, QMI_SET_SWT,
                                     swt_payload(0),
                                     "set software trace=disabled")
        ok = ok and success
        txn += 1

        _, confirmed = confirm_state(transport, node, port, txn, "disabled")
        return ok and confirmed

    raise RuntimeError("unknown mode %s" % mode)


def parse_instance(value):
    try:
        instance = int(value, 0)
    except ValueError as error:
        raise argparse.ArgumentTypeError("invalid instance: %s" %
                                         value) from error
    if instance < 0 or instance > 0xffffffff:
        raise argparse.ArgumentTypeError(
            "instance must be in range 0..0xffffffff")
    return instance


def build_parser():
    parser = argparse.ArgumentParser()
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--enable", action="store_true",
                       help="enable software, ULog, and DIAG tracing")
    group.add_argument("--disable", action="store_true",
                       help="disable entity tracing, then software tracing")
    parser.add_argument("--instance", type=parse_instance, action="append",
                        help="limit the operation to a QDSSC instance")
    return parser


def validate_qdssc_endpoints(found):
    rows = []
    seen_rows = set()
    seen_endpoints = set()

    for entry in found:
        if len(entry) != 5:
            raise RuntimeError("malformed QDSSC service row: %r" %
                               (entry,))
        service, version, instance, node, port = tuple(map(int, entry))
        if service != QDSSC_SERVICE:
            continue

        row = (service, version, instance, node, port)
        if row in seen_rows:
            raise RuntimeError(
                "duplicate QDSSC service row: instance=%d node=%d port=%d" %
                (instance, node, port))
        seen_rows.add(row)

        endpoint = (node, port)
        if endpoint in seen_endpoints:
            raise RuntimeError(
                "duplicate QDSSC QRTR endpoint: node=%d port=%d" %
                (node, port))
        seen_endpoints.add(endpoint)
        rows.append(row)

    return rows


def normalize_instances(requested, mutating):
    if not requested:
        return []

    seen = set()
    for instance in requested:
        if instance in seen:
            raise RuntimeError("duplicate --instance value: %d" % instance)
        seen.add(instance)

    if mutating and len(requested) != 1:
        raise RuntimeError(
            "--enable/--disable require exactly one --instance")

    return requested


def selected_endpoints(found, requested, mutating=False):
    found = validate_qdssc_endpoints(found)
    if not found:
        raise RuntimeError("QDSSC service is not registered")
    requested = normalize_instances(requested, mutating)

    if not requested:
        return found

    requested = set(requested)
    instances = {entry[2] for entry in found}
    missing = sorted(requested - instances)
    if missing:
        raise RuntimeError(
            "requested QDSSC instance(s) not registered: %s" %
            ", ".join(map(str, missing)))
    targets = [entry for entry in found if entry[2] in requested]
    if mutating and len(targets) != 1:
        raise RuntimeError(
            "requested QDSSC instance matched %d endpoints; expected one" %
            len(targets))
    return targets


def run(args, endpoint_provider=endpoints, transport_factory=QrtrTransport):
    mutating = args.enable or args.disable
    if mutating and not args.instance:
        raise RuntimeError(
            "--enable/--disable require exactly one --instance")

    found = endpoint_provider()
    if not found:
        raise RuntimeError("QDSSC service is not registered")

    targets = selected_endpoints(found, args.instance, mutating)
    mode = "enable" if args.enable else "disable" if args.disable else "read"

    transport = transport_factory()
    try:
        ok = True
        for service, version, instance, node, port in targets:
            try:
                ok = inspect_endpoint(transport, node, port, instance, mode) \
                    and ok
            except Exception as error:
                ok = False
                print("instance=%d node=%d port=%d: %s" %
                      (instance, node, port, error), file=sys.stderr)
        return 0 if ok else 1
    finally:
        close = getattr(transport, "close", None)
        if close:
            close()


def main(argv=None, endpoint_provider=endpoints,
         transport_factory=QrtrTransport):
    parser = build_parser()
    args = parser.parse_args(argv)
    mutating = args.enable or args.disable
    if mutating and not args.instance:
        parser.error("--enable/--disable require exactly one --instance")
    try:
        normalize_instances(args.instance, mutating)
    except RuntimeError as error:
        parser.error(str(error))
    try:
        return run(args, endpoint_provider, transport_factory)
    except RuntimeError as error:
        print(error, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
