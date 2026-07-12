#!/usr/bin/env python3
"""Filter a DT overlay so every external fixup resolves in a base DTB."""

import argparse
import subprocess
import sys


LOCAL_FIXUPS = "/__local_fixups__"


def command(*args, check=True):
    result = subprocess.run(
        args,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    if check and result.returncode:
        raise RuntimeError(f"command failed ({result.returncode}): {' '.join(args)}")
    return result


def words(*args):
    return command(*args).stdout.split()


def node_exists(dtb, path):
    return command("fdtget", "-p", dtb, path, check=False).returncode == 0


def property_exists(dtb, path, prop):
    return (
        command("fdtget", "-t", "bx", dtb, path, prop, check=False).returncode
        == 0
    )


def delete_node(dtb, path):
    if node_exists(dtb, path):
        command("fdtput", "-r", dtb, path)


def delete_property(dtb, path, prop):
    if property_exists(dtb, path, prop):
        command("fdtput", "-d", dtb, path, prop)


def set_strings(dtb, path, prop, values):
    command("fdtput", "-t", "s", dtb, path, prop, *values)


def child_nodes(dtb, path):
    return words("fdtget", "-l", dtb, path) if node_exists(dtb, path) else []


def walk_nodes(dtb, path="/"):
    yield path
    for child in child_nodes(dtb, path):
        child_path = path.rstrip("/") + "/" + child
        yield from walk_nodes(dtb, child_path)


def properties(dtb, path):
    return words("fdtget", "-p", dtb, path) if node_exists(dtb, path) else []


def string_property(dtb, path, prop):
    return words("fdtget", "-t", "s", dtb, path, prop)


def fixup_parts(ref):
    path, prop, offset = ref.rsplit(":", 2)
    return path, prop, int(offset, 0)


def remove_unresolved_external_fixups(overlay, base):
    base_symbols = set(properties(base, "/__symbols__"))
    fragments = set()
    doomed_properties = set()

    for symbol in properties(overlay, "/__fixups__"):
        if symbol in base_symbols:
            continue
        for ref in string_property(overlay, "/__fixups__", symbol):
            path, prop, _ = fixup_parts(ref)
            if path.startswith("/fragment@") and "/" not in path[1:] and prop == "target":
                fragments.add(path)
            else:
                doomed_properties.add((path, prop))

    for fragment in sorted(fragments):
        delete_node(overlay, fragment)
        delete_node(overlay, LOCAL_FIXUPS + fragment)

    removed_properties = 0
    for path, prop in sorted(doomed_properties):
        if any(path == fragment or path.startswith(fragment + "/") for fragment in fragments):
            continue
        if property_exists(overlay, path, prop):
            delete_property(overlay, path, prop)
            delete_property(overlay, LOCAL_FIXUPS + path, prop)
            removed_properties += 1

    for symbol in list(properties(overlay, "/__fixups__")):
        refs = []
        for ref in string_property(overlay, "/__fixups__", symbol):
            path, prop, _ = fixup_parts(ref)
            if property_exists(overlay, path, prop):
                refs.append(ref)
        if symbol not in base_symbols or not refs:
            delete_property(overlay, "/__fixups__", symbol)
        else:
            set_strings(overlay, "/__fixups__", symbol, refs)

    return len(fragments), removed_properties


def phandle_map(dtb):
    result = {}
    for path in walk_nodes(dtb):
        for prop in ("phandle", "linux,phandle"):
            values = words("fdtget", "-t", "x", dtb, path, prop) if property_exists(dtb, path, prop) else []
            if values:
                result[int(values[0], 16)] = path
    return result


def prune_undefined_local_references(overlay):
    removed = 0
    while True:
        known = phandle_map(overlay)
        doomed = set()
        for local_path in walk_nodes(overlay, LOCAL_FIXUPS):
            actual_path = local_path[len(LOCAL_FIXUPS) :] or "/"
            for prop in properties(overlay, local_path):
                if not property_exists(overlay, actual_path, prop):
                    delete_property(overlay, local_path, prop)
                    continue
                offsets = [
                    int(value, 16)
                    for value in words("fdtget", "-t", "x", overlay, local_path, prop)
                ]
                raw = bytes(
                    int(value, 16)
                    for value in words("fdtget", "-t", "bx", overlay, actual_path, prop)
                )
                for offset in offsets:
                    if offset + 4 > len(raw):
                        raise RuntimeError(
                            f"invalid local fixup offset {actual_path}:{prop}:{offset}"
                        )
                    if int.from_bytes(raw[offset : offset + 4], "big") not in known:
                        doomed.add((actual_path, prop))
                        break
        if not doomed:
            return removed
        for path, prop in sorted(doomed):
            delete_property(overlay, path, prop)
            delete_property(overlay, LOCAL_FIXUPS + path, prop)
            removed += 1


def prune_stale_symbols(overlay):
    removed = 0
    for symbol in list(properties(overlay, "/__symbols__")):
        paths = string_property(overlay, "/__symbols__", symbol)
        if len(paths) != 1 or not node_exists(overlay, paths[0]):
            delete_property(overlay, "/__symbols__", symbol)
            removed += 1
    return removed


def validate_metadata(overlay):
    for symbol in properties(overlay, "/__fixups__"):
        for ref in string_property(overlay, "/__fixups__", symbol):
            path, prop, offset = fixup_parts(ref)
            raw = words("fdtget", "-t", "bx", overlay, path, prop)
            if not raw or offset + 4 > len(raw):
                raise RuntimeError(f"invalid external fixup: {symbol}={ref}")

    known = phandle_map(overlay)
    for local_path in walk_nodes(overlay, LOCAL_FIXUPS):
        actual_path = local_path[len(LOCAL_FIXUPS) :] or "/"
        for prop in properties(overlay, local_path):
            raw = bytes(
                int(value, 16)
                for value in words("fdtget", "-t", "bx", overlay, actual_path, prop)
            )
            for value in words("fdtget", "-t", "x", overlay, local_path, prop):
                offset = int(value, 16)
                if offset + 4 > len(raw):
                    raise RuntimeError(f"invalid local fixup: {actual_path}:{prop}:{offset}")
                target = int.from_bytes(raw[offset : offset + 4], "big")
                if target not in known:
                    raise RuntimeError(
                        f"undefined local phandle {target:#x}: {actual_path}:{prop}:{offset}"
                    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--overlay", required=True)
    parser.add_argument("--base", required=True)
    args = parser.parse_args()

    fragments, properties_removed = remove_unresolved_external_fixups(
        args.overlay, args.base
    )
    local_removed = prune_undefined_local_references(args.overlay)
    stale_symbols = prune_stale_symbols(args.overlay)
    validate_metadata(args.overlay)
    print(f"removed fragments: {fragments}")
    print(f"removed external-reference properties: {properties_removed}")
    print(f"removed undefined local-reference properties: {local_removed}")
    print(f"removed stale symbols: {stale_symbols}")
    print(f"remaining fragments: {len([n for n in child_nodes(args.overlay, '/') if n.startswith('fragment@')])}")
    print(f"remaining fixup symbols: {len(properties(args.overlay, '/__fixups__'))}")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(1)
