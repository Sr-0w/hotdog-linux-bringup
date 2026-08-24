#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Inventory an OxygenOS modem, telephony, data and IMS stack."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from collections import Counter
from pathlib import Path


COMPONENTS = {
    "bin/hw/qcrild": ("radio", "RIL/QMI orchestration and Android radio HAL"),
    "lib64/libril-qc-qmi-1.so": ("radio", "UIM, PDC, NAS, WMS, voice and IMS QMI state machines"),
    "lib64/libril-qc-hal-qmi.so": ("radio", "radio HAL request and indication bridge"),
    "lib64/libqcrilFramework.so": ("radio", "QCRIL event, module and message framework"),
    "lib64/libqmiservices.so": ("qmi", "Qualcomm QMI service schemas"),
    "bin/rmt_storage": ("storage", "modem EFS remote storage"),
    "bin/netmgrd": ("data", "rmnet link and packet data manager"),
    "bin/dpmQmiMgr": ("data", "data port mapper QMI manager"),
    "bin/qti": ("data", "data QTI control service"),
    "bin/adpl": ("data", "data peripheral link service"),
    "bin/ipacm": ("data", "IPA connection manager"),
    "bin/cnd": ("data", "connectivity policy daemon"),
    "bin/imsqmidaemon": ("ims", "IMS QMI broker"),
    "bin/imsdatadaemon": ("ims", "IMS packet data daemon"),
    "bin/imsrcsd": ("ims", "IMS RCS service"),
    "bin/ims_rtp_daemon": ("ims", "IMS RTP service"),
    "bin/port-bridge": ("diagnostics", "modem diagnostic port bridge"),
    "bin/qrtr-ns": ("transport", "QRTR name service"),
    "bin/qrtr-cfg": ("transport", "QRTR transport configuration"),
}

SUPPORT_FILES = (
    "etc/data/netmgr_config.xml",
    "etc/vintf/manifest.xml",
    "radio/qcril_database/qcril.db",
)

INIT_NAMES = (
    "qcrild.rc",
    "init-qcril-data.rc",
    "dpmQmiMgr.rc",
    "netmgrd.rc",
    "dataqti.rc",
    "dataadpl.rc",
    "ipacm.rc",
    "cnd.rc",
    "imsqmidaemon.rc",
    "imsdatadaemon.rc",
    "imsrcsd.rc",
    "ims_rtp_daemon.rc",
    "port-bridge.rc",
)

SYMBOL_FAMILIES = {
    "uim": re.compile(r"(?:^|_)(?:uim|sim|gstk|pbm)(?:_|$)", re.I),
    "pdc-mbn": re.compile(r"(?:^|_)(?:pdc|mbn|mcfg)(?:_|$)", re.I),
    "radio-nas": re.compile(r"(?:^|_)(?:nas|nwreg|dms|rfrpe|sar)(?:_|$)", re.I),
    "data": re.compile(r"(?:^|_)(?:wds|data|rmnet|dpm|ipa)(?:_|$)", re.I),
    "sms": re.compile(r"(?:^|_)(?:wms|sms)(?:_|$)", re.I),
    "voice": re.compile(r"(?:^|_)(?:voice|call)(?:_|$)", re.I),
    "ims": re.compile(r"(?:^|_)(?:ims|imsa|imss|imsrtp|rcs)(?:_|$)", re.I),
    "ssr": re.compile(r"(?:^|_)(?:ssr|restart|recovery|crash)(?:_|$)", re.I),
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def run_readelf(path: Path, option: str) -> str:
    try:
        result = subprocess.run(
            ["readelf", option, str(path)],
            check=True,
            capture_output=True,
            text=True,
        )
    except (FileNotFoundError, subprocess.CalledProcessError, UnicodeError):
        return ""
    return result.stdout


def elf_dependencies(path: Path) -> list[str]:
    output = run_readelf(path, "-d")
    return sorted(set(re.findall(r"\(NEEDED\).*?\[(.+?)\]", output)))


def dynamic_symbols(path: Path) -> list[str]:
    symbols = []
    for line in run_readelf(path, "-Ws").splitlines():
        fields = line.split()
        if len(fields) < 8 or fields[0] == "Num:":
            continue
        symbol = fields[-1].split("@", 1)[0]
        if symbol and symbol != "UND":
            symbols.append(symbol)
    return sorted(set(symbols))


def classify_symbols(symbols: list[str]) -> dict[str, dict[str, object]]:
    classified = {}
    for family, pattern in SYMBOL_FAMILIES.items():
        matches = [symbol for symbol in symbols if pattern.search(symbol)]
        if matches:
            classified[family] = {
                "count": len(matches),
                "examples": matches[:12],
            }
    return classified


def parse_init_services(text: str, source: str) -> list[dict[str, object]]:
    services = []
    current = None
    trigger = None
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("on "):
            trigger = line[3:]
            current = None
            continue
        if line.startswith("service "):
            fields = line.split()
            current = {
                "name": fields[1],
                "command": fields[2:],
                "source": source,
                "options": [],
            }
            services.append(current)
            trigger = None
            continue
        if current is not None and raw_line[:1].isspace():
            current["options"].append(line)
        elif trigger and line.startswith(("start ", "stop ", "restart ", "setprop ")):
            services.append({"trigger": trigger, "action": line, "source": source})
    return services


def parse_vintf(path: Path) -> list[dict[str, object]]:
    if not path.is_file():
        return []
    try:
        root = ET.parse(path).getroot()
    except (ET.ParseError, OSError):
        return []
    entries = []
    for hal in root.findall("hal"):
        name = (hal.findtext("name") or "").strip()
        text = " ".join(part.strip() for part in hal.itertext() if part.strip())
        if not re.search(r"radio|ims|dpm|data", f"{name} {text}", re.I):
            continue
        entries.append({
            "name": name,
            "interfaces": sorted(set(node.text.strip() for node in hal.findall(".//interface/name") if node.text)),
            "instances": sorted(set(node.text.strip() for node in hal.findall(".//instance") if node.text)),
            "fqnames": sorted(set(node.text.strip() for node in hal.findall("fqname") if node.text)),
        })
    return entries


def inventory(root: Path) -> dict[str, object]:
    if not root.is_dir():
        raise ValueError(f"vendor root is not a directory: {root}")

    components = []
    capability_counts: Counter[str] = Counter()
    for relative, (layer, responsibility) in COMPONENTS.items():
        path = root / relative
        if not path.is_file():
            continue
        symbols = dynamic_symbols(path)
        capabilities = classify_symbols(symbols)
        capability_counts.update({name: value["count"] for name, value in capabilities.items()})
        components.append({
            "path": relative,
            "layer": layer,
            "responsibility": responsibility,
            "size": path.stat().st_size,
            "sha256": sha256(path),
            "needed": elf_dependencies(path),
            "symbol_capabilities": capabilities,
        })

    support = []
    for relative in SUPPORT_FILES:
        path = root / relative
        if path.is_file():
            support.append({"path": relative, "size": path.stat().st_size, "sha256": sha256(path)})

    init_services = []
    init_root = root / "etc/init"
    for name in INIT_NAMES:
        path = init_root / name
        if path.is_file():
            init_services.extend(parse_init_services(path.read_text(errors="replace"), f"etc/init/{name}"))

    return {
        "schema": 1,
        "components": sorted(components, key=lambda item: item["path"]),
        "support_files": sorted(support, key=lambda item: item["path"]),
        "init_services": init_services,
        "vintf": parse_vintf(root / "etc/vintf/manifest.xml"),
        "capability_symbol_counts": dict(sorted(capability_counts.items())),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("vendor_root", type=Path)
    parser.add_argument("--output", type=Path, help="write JSON to this path instead of stdout")
    args = parser.parse_args()
    try:
        document = inventory(args.vendor_root)
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    encoded = json.dumps(document, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.write_text(encoded)
    else:
        sys.stdout.write(encoded)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
