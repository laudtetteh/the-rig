#!/usr/bin/env python3
"""Reject maintainer-specific identifiers and non-portable mktemp templates in tracked public source."""

import argparse
import pathlib
import re
import subprocess
import sys

PATTERNS = {
    "personal_home": re.compile(r"/(?:Users|home)/(?!you/|user/|name/|dev/|code/|\.rig/)[A-Za-z0-9._-]+/"),
    "private_identifier": re.compile(r"\b(?:beaconavenue|dedoress|beaconessentials|seattlecollisions|laudbot)\b", re.I),
    "pilot_name": re.compile(r"\b4Culture\b", re.I),
    # BSD mktemp replaces only a trailing run of X's; anything after the X's
    # (for example a .json suffix) makes it create that literal path, so
    # concurrent runs collide (issue #724).
    # Inspect quoted and unquoted template arguments separately: quoted
    # suffixes may contain spaces or shell punctuation, while unquoted command
    # separators and the closing command-substitution paren are delimiters.
    "mktemp_suffix": re.compile(
        r"\bmktemp\b[^\n;|&]*?(?:\"[^\"\n]*?X{3,}(?!X)[^\"\n]+\"|"
        r"'[^'\n]*?X{3,}(?!X)[^'\n]+'|\S*?X{3,}(?!X)[^\s;)|&\"']+)"
    ),
}
ALLOW = {("README.md", "pilot_name"):
         re.compile(r"^It was subsequently piloted on \[4Culture\.org\]\(https://4culture\.org\),"),
         # The release note for the earlier fix quotes the broken template.
         ("CHANGELOG.md", "mktemp_suffix"):
         re.compile(r"^- `mktemp /tmp/rig-global-claude-XXXXXX\.md` used non-portable suffix")}


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
