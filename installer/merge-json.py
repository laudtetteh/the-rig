#!/usr/bin/env python3
"""Structure-aware three-way JSON merge (issue #444, lane 444-C).

Merges the currently-installed (possibly customized) JSON file with the
incoming Rig template JSON file: keys the user customized that the incoming
template left alone are preserved; keys the incoming template changed that
the user left alone are adopted; keys both sides changed to the same value
converge silently; keys both sides changed to *different* values are
reported as conflicts and the merge refuses to guess (see
_convergence_common.py for the exact three-way rule and its no-base
fallback -- this lane runs without a trusted base until issue #444 lane
444-B lands provenance data).

This is a general-purpose sibling to install.sh's merge_settings_json(),
which stays in place unchanged for .claude/settings.json's existing
additive-dedup hook/permission semantics (that function intentionally never
reports a conflict -- it always merges). This tool is for every other JSON
artifact and does report conflicts.

Usage:
    merge-json.py --current <path> --incoming <path> --output <path> \
        [--base <path>]

Prints one JSON report line to stdout:
    {"ok": true,  "conflicts": []}                         (and writes --output)
    {"ok": false, "conflicts": [{"path": ..., "current": ..., "incoming": ...}]}
    {"ok": false, "error": "...", "conflicts": []}          (I/O or parse failure)

Exit code: 0 = merged and written, 1 = conflicts (nothing written),
2 = could not even attempt the merge (missing/invalid input).
"""
import argparse
import json
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _convergence_common import merge_dict  # noqa: E402


def load(path):
    if not path or not os.path.exists(path):
        return {}
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base")
    parser.add_argument("--current", required=True)
    parser.add_argument("--incoming", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    try:
        base = load(args.base)
        current = load(args.current)
        incoming = load(args.incoming)
    except (OSError, json.JSONDecodeError) as exc:
        print(json.dumps({"ok": False, "error": str(exc), "conflicts": []}))
        return 2

    if not isinstance(current, dict) or not isinstance(incoming, dict):
        print(json.dumps({
            "ok": False,
            "error": "top-level JSON value is not an object; structure-aware merge requires an object",
            "conflicts": [],
        }))
        return 2

    conflicts = []
    merged = merge_dict(base if isinstance(base, dict) else {}, current, incoming, "", conflicts)

    if conflicts:
        print(json.dumps({"ok": False, "conflicts": conflicts}))
        return 1

    directory = os.path.dirname(os.path.abspath(args.output)) or "."
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".rig-merge-json.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(merged, handle, indent=2)
            handle.write("\n")
        os.replace(tmp, args.output)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)

    print(json.dumps({"ok": True, "conflicts": []}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
