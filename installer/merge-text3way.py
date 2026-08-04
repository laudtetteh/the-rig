#!/usr/bin/env python3
"""Plain-text three-way merge fallback (issue #444, lane 444-C).

The catch-all for any customized artifact with no known structure (shell
scripts, plain docs, anything not handled by merge-json.py,
merge-toml.py, or merge-frontmatter-markdown.py). Unlike those three, this
tool deliberately does NOT attempt a line/hunk-level diff3 merge -- an
unstructured file has no reliable notion of an independent "path" the way a
JSON key or a TOML table does, so a hand-rolled hunk-aligning 3-way merge
algorithm would be guessing at semantics it cannot verify. That risk is
explicitly out of scope here: "a hand-rolled line-based 3-way merge is
acceptable if you keep it simple" -- keeping it simple means resolving only
the three unambiguous whole-file cases and refusing (with a specific,
actionable report) everything else, never a partial/best-guess splice.

Resolved without conflict:
  - current == incoming                    -> already converged
  - a trusted --base is given and current == base   -> only incoming changed, take incoming
  - a trusted --base is given and incoming == base  -> only current changed, take current

Everything else is a conflict. This lane runs without a trusted base
(issue #444 lane 444-B, which supplies one, is unmerged), so in practice
every customized file that reaches this tool with current != incoming
conflicts -- this is intentional, not a bug: without a base there is no way
to know which side actually changed, so guessing would silently discard
either the user's customization or the incoming Rig improvement. The
conflict report is still specific: it locates and previews every differing
line range between the current and incoming files (via difflib), not just
a generic "customized, skipped" message.

Usage:
    merge-text3way.py --current <path> --incoming <path> --output <path> \
        [--base <path>]

Prints one JSON report line to stdout (same shape as merge-json.py) and
exits 0 (merged), 1 (conflicts, nothing written), or 2 (I/O failure).
"""
import argparse
import difflib
import json
import os
import sys
import tempfile

_SNIPPET_LIMIT = 200


def read_lines(path):
    if not path or not os.path.exists(path):
        return None
    with open(path, encoding="utf-8") as handle:
        return handle.readlines()


def snippet(lines):
    text = "".join(lines)
    if len(text) > _SNIPPET_LIMIT:
        text = text[:_SNIPPET_LIMIT] + "…"
    return text


def line_conflicts(current_lines, incoming_lines):
    matcher = difflib.SequenceMatcher(None, current_lines, incoming_lines, autojunk=False)
    conflicts = []
    for tag, i1, i2, j1, j2 in matcher.get_opcodes():
        if tag == "equal":
            continue
        current_range = f"{i1 + 1}-{i2}" if i2 > i1 else f"{i1 + 1} (no local content)"
        incoming_range = f"{j1 + 1}-{j2}" if j2 > j1 else f"{j1 + 1} (removed upstream)"
        conflicts.append({
            "path": f"lines {current_range} (yours) vs {incoming_range} (incoming)",
            "current": snippet(current_lines[i1:i2]),
            "incoming": snippet(incoming_lines[j1:j2]),
        })
    return conflicts


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base")
    parser.add_argument("--current", required=True)
    parser.add_argument("--incoming", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    try:
        base_lines = read_lines(args.base)
        current_lines = read_lines(args.current)
        incoming_lines = read_lines(args.incoming)
    except OSError as exc:
        print(json.dumps({"ok": False, "error": str(exc), "conflicts": []}))
        return 2

    if current_lines is None or incoming_lines is None:
        print(json.dumps({"ok": False, "error": "current/incoming file is unreadable", "conflicts": []}))
        return 2

    if current_lines == incoming_lines:
        merged_lines = current_lines
    elif base_lines is not None and current_lines == base_lines:
        merged_lines = incoming_lines
    elif base_lines is not None and incoming_lines == base_lines:
        merged_lines = current_lines
    else:
        conflicts = line_conflicts(current_lines, incoming_lines)
        print(json.dumps({"ok": False, "conflicts": conflicts}))
        return 1

    directory = os.path.dirname(os.path.abspath(args.output)) or "."
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".rig-merge-text.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.writelines(merged_lines)
        os.replace(tmp, args.output)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)

    print(json.dumps({"ok": True, "conflicts": []}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
