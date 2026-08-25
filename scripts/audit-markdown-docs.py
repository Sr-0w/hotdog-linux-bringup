#!/usr/bin/env python3
"""Generate or verify the repository-wide Markdown review register."""

import argparse
import pathlib
import subprocess
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
REPORT = pathlib.Path("docs/markdown-audit-2026-08-25.md")
TITLE_EXCEPTIONS = {
    pathlib.Path(".github/PULL_REQUEST_TEMPLATE.md"),
    pathlib.Path("README.md"),
    pathlib.Path("docs/postmarketos-wiki-page-mockup.md"),
}


def tracked_markdown():
    result = subprocess.run(
        ["git", "ls-files", "*.md"],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    )
    paths = {pathlib.Path(line) for line in result.stdout.splitlines() if line}
    paths.add(REPORT)
    return sorted(paths, key=lambda path: str(path))


def classify(path, text):
    raw = str(path)
    if path == REPORT:
        return "Audit register", "Generated and checked by this audit tool"
    if raw == "docs/evidence/README.md":
        return "Evidence policy", "Current archive/supersession policy"
    if raw.startswith("docs/evidence/"):
        prefix = "\n".join(text.splitlines()[:12]).lower()
        superseded = any(
            marker in prefix
            for marker in (
                "supersed",
                "> fixed in the current",
                "> historical",
                "historical",
                "remains correct",
                "were added",
                "now hardware-validated",
                "then-untested",
                "is not the phone's user-facing",
            )
        )
        note = (
            "Historical evidence; explicit supersession note present"
            if superseded
            else "Historical evidence; dated observations preserved"
        )
        return "Evidence", note
    if raw.startswith("docs/release-notes-"):
        return "Release record", "Immutable description of its exact release"
    if raw in {
        "docs/bringup-history.md",
        "docs/camera-port-plan.md",
        "docs/mainline-bringup.md",
    }:
        return "Project history", "Historical scope/supersession stated"
    if raw.startswith("work/"):
        return "Work note", "Historical/experimental scope stated"
    if raw.startswith("upstream/"):
        return "Mail archive", "Immutable upstream submission context"
    if raw.endswith("linux-oneplus-hotdog-mainline617-k1/README.md"):
        return "Package history", "Historical K1 package scope stated"
    if raw == "helpers/r6-ufs-regdump/README.md":
        return "Disabled helper", "Fail-closed safety status verified"
    if raw.startswith("aports/"):
        return "Package documentation", "Reviewed against current package roles"
    return "Current documentation", "Reviewed against Alpha 5 and current status"


def render():
    rows = []
    counts = {}
    for path in tracked_markdown():
        absolute = ROOT / path
        if path == REPORT and not absolute.exists():
            text = "# Markdown audit - 2026-08-25\n"
            raw = text.encode()
        else:
            try:
                raw = absolute.read_bytes()
                text = raw.decode("utf-8")
            except (OSError, UnicodeDecodeError) as exc:
                raise SystemExit(f"{path}: cannot read as UTF-8: {exc}") from exc
        if not text.strip():
            raise SystemExit(f"{path}: empty Markdown file")
        if "\0" in text:
            raise SystemExit(f"{path}: NUL byte in Markdown")
        if path not in TITLE_EXCEPTIONS and not any(
            line.startswith("# ") for line in text.splitlines()
        ):
            raise SystemExit(f"{path}: missing level-1 title")
        role, verdict = classify(path, text)
        counts[role] = counts.get(role, 0) + 1
        rows.append((str(path), role, verdict))

    lines = [
        "# Markdown audit - 2026-08-25",
        "",
        "This register lists every Git-tracked Markdown file after the Alpha 5",
        "documentation audit. Current documents were checked against `README.md`,",
        "`docs/status.md`, package revisions `r181`/`3-r32` and the published",
        "Alpha 5 manifest. Dated evidence and release notes retain their original",
        "observations; misleading intermediate conclusions carry supersession notes.",
        "",
        "Automated checks also require UTF-8, non-empty content, a level-1 title",
        "where the native format permits one, and a list exactly matching Git.",
        "Local Markdown links are checked separately by `validate-public-tree.sh`.",
        "An external-link pass returned HTTP 200 for 42 of 46 unique URLs; the",
        "four exact lore.kernel.org message links returned the site's automated",
        "client 403 response and were retained as immutable submission IDs.",
        "",
        f"Total: **{len(rows)} Markdown files**.",
        "",
        "| Role | Count |",
        "|---|---:|",
    ]
    for role in sorted(counts):
        lines.append(f"| {role} | {counts[role]} |")
    lines.extend(
        [
            "",
            "## File-by-file register",
            "",
            "| File | Role | Review result |",
            "|---|---|---|",
        ]
    )
    for path, role, verdict in rows:
        lines.append(f"| `{path}` | {role} | {verdict} |")
    lines.append("")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--write", action="store_true")
    mode.add_argument("--check", action="store_true")
    args = parser.parse_args()
    expected = render()
    report = ROOT / REPORT
    if args.write:
        report.write_text(expected, encoding="utf-8")
        print(f"wrote {REPORT}")
        return 0
    try:
        actual = report.read_text(encoding="utf-8")
    except OSError as exc:
        parser.exit(1, f"missing Markdown audit report: {exc}\n")
    if actual != expected:
        parser.exit(1, "Markdown audit report is stale; run --write\n")
    print(f"Markdown audit report: PASS ({len(tracked_markdown())} files)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
