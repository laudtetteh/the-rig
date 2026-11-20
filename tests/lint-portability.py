#!/usr/bin/env python3
"""Reject maintainer-specific identifiers in tracked public source."""

import argparse
import pathlib
import re
import subprocess
import sys

PATTERNS = {
    "personal_home": re.compile(r"/(?:Users|home)/(?!you/|user/|name/|dev/|code/|\.rig/)[A-Za-z0-9._-]+/"),
    "private_identifier": re.compile(r"\b(?:beaconavenue|dedoress|beaconessentials|seattlecollisions|laudbot)\b", re.I),
    "pilot_name": re.compile(r"\b4Culture\b", re.I),
}
ALLOW = {("README.md", "pilot_name"):
         re.compile(r"^It was subsequently piloted on \[4Culture\.org\]\(https://4culture\.org\),")}


def paths(root):
    result = subprocess.run(["git", "-C", str(root), "ls-files", "-z"],
                            check=True, capture_output=True)
    return [pathlib.Path(item.decode()) for item in result.stdout.split(b"\0") if item]


def lint(root):
    findings = []
    for rel in paths(root):
        if rel == pathlib.Path("tests/lint-portability.py"):
            continue
        path = root / rel
        try:
            content = path.read_text(encoding="utf-8")
        except (UnicodeError, OSError):
            continue
        for number, line in enumerate(content.splitlines(), 1):
            for name, pattern in PATTERNS.items():
                allowed = ALLOW.get((rel.as_posix(), name))
                if pattern.search(line) and not (allowed and allowed.search(line)):
                    findings.append(f"{rel}:{number}: {name}")
    return findings


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=pathlib.Path, default=pathlib.Path(__file__).resolve().parent.parent)
    root = parser.parse_args().root.resolve()
    findings = lint(root)
    for finding in findings:
        print(finding)
    print(f"portability lint: {len(findings)} finding(s)")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
