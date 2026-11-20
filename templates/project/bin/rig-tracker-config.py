#!/usr/bin/env python3
"""Read the project's issue tracker settings for Rig commands and hooks."""

import argparse
import json
import os
import re
import shlex
import stat
import subprocess
import sys
from pathlib import Path

PRESETS = {
    "linear": (r"[A-Z]+-[0-9]+", "ENG-123"),
    "trello": (r"trello:[^]]+", "trello:CARD-ID"),
    "gus": (r"W-[0-9]+", "W-1234567"),
}
KEYS = {"issue-tracking", "issue-ref-pattern", "issue-ref-example"}


def read_config(path):
    values = {}
    config_path = Path(path)
    if config_path.exists() or config_path.is_symlink():
        flags = os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW
        descriptor = os.open(config_path, flags)
        with os.fdopen(descriptor, "r") as handle:
            if not stat.S_ISREG(os.fstat(handle.fileno()).st_mode):
                raise ValueError("CLAUDE.md must be a regular file")
            lines = handle.read().splitlines()
    else:
        lines = []
    for number, line in enumerate(lines, 1):
        match = re.match(r"^\s*([a-z][a-z-]*):\s*(.*?)\s*$", line, re.I)
        if not match or match.group(1).lower() not in KEYS:
            continue
        key = match.group(1).lower()
        if key in values:
            raise ValueError(f"duplicate {key} setting at line {number}")
        try:
            tokens = shlex.split(match.group(2), comments=True)
        except ValueError as exc:
            raise ValueError(f"invalid {key} setting at line {number}: {exc}") from exc
        if len(tokens) > 1:
            raise ValueError(f"{key} must contain one value at line {number}")
        values[key] = tokens[0] if tokens else ""

    tracker = values.get("issue-tracking", "github").lower()
    if not tracker or not re.fullmatch(r"[a-z][a-z0-9_-]*", tracker):
        raise ValueError("issue-tracking must be one tracker name")
    pattern = values.get("issue-ref-pattern") or PRESETS.get(tracker, ("", ""))[0]
    example = values.get("issue-ref-example") or PRESETS.get(tracker, ("", ""))[1]
    if tracker == "github":
        pattern, example = r"#[0-9]+", "#123"
    if tracker == "none":
        pattern, example = "", ""
    if pattern:
        check = subprocess.run(["grep", "-E", "-q", "-e", pattern],
                               input="", text=True, capture_output=True)
        if check.returncode == 2:
            raise ValueError(f"invalid issue-ref-pattern: {check.stderr.strip()}")
    return {"tracker": tracker, "pattern": pattern, "example": example}


def reference_valid(config, ref):
    if not ref or ref.strip() != ref or "\n" in ref or "\r" in ref:
        return False
    if config["tracker"] == "none":
        return False
    if config["tracker"] == "github":
        return bool(re.fullmatch(r"#[0-9]+", ref))
    if not config["pattern"]:
        return True
    expression = f"^({config['pattern']})$"
    return subprocess.run(["grep", "-E", "-q", "-e", expression],
                          input=ref + "\n", text=True).returncode == 0


def subject_has_ref(config, subject):
    if config["tracker"] == "none":
        return True
    if config["tracker"] == "github" and re.search(r"\(#[0-9]+\)", subject):
        return True
    return any(reference_valid(config, ref)
               for ref in re.findall(r"\[([^\]\n]+)\]", subject))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("show", "validate-ref", "validate-subject"))
    parser.add_argument("config")
    parser.add_argument("subject", nargs="?")
    args = parser.parse_args()
    try:
        config = read_config(args.config)
    except (OSError, ValueError, UnicodeError) as exc:
        print(f"ERROR: invalid tracker configuration: {exc}", file=sys.stderr)
        return 2
    if args.action == "show":
        print(json.dumps(config, sort_keys=True))
        return 0
    if args.subject is None:
        parser.error(f"{args.action} requires a value")
    valid = (reference_valid(config, args.subject) if args.action == "validate-ref"
             else subject_has_ref(config, args.subject))
    if valid:
        return 0
    example = config["example"] or "TICKET-123"
    tracker_name = {"github": "GitHub", "gus": "GUS"}.get(
        config["tracker"], config["tracker"].title())
    if args.action == "validate-ref":
        print(f"ERROR: invalid {tracker_name} reference; expected {example}.", file=sys.stderr)
    else:
        kind = "issue reference" if config["tracker"] == "github" else "reference"
        print(f"ERROR: Commit message must include a {tracker_name} {kind} such as [{example}].", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
