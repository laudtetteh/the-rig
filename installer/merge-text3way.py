#!/usr/bin/env python3
"""Plain-text three-way merge fallback (issue #444, lane 444-C).

The catch-all for any customized artifact with no known structure (shell
scripts, plain docs, anything not handled by merge-json.py, merge-toml.py, or
merge-frontmatter-markdown.py).

Resolved without conflict, in order:
  - current == incoming                             -> already converged
  - a trusted --base is given and current == base   -> only incoming changed, take incoming
  - a trusted --base is given and incoming == base  -> only current changed, take current
  - a trusted --base is given                       -> line-level three-way merge

The line-level step (issue #561) delegates to `git merge-file` rather than a
hand-rolled hunk-aligning algorithm. Originally this tool resolved only the
three whole-file cases above, because issue #444 lane 444-B never supplied a
base and guessing which side changed would silently discard either the user's
customization or the incoming Rig improvement. Now that
installer/resolve-historical-base.py proves a base by hash (issue #560), the
ambiguity is gone and standard diff3 semantics apply.

Without a trusted base the old conservative behaviour is unchanged: any
difference between current and incoming is a conflict. The conflict report is
specific either way -- git's conflicting hunks when a base was available, or
every differing line range between current and incoming (via difflib) when it
was not.

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

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _convergence_common import merge_text_3way  # noqa: E402

_SNIPPET_LIMIT = 200


def read_lines(path):
    if not path or not os.path.exists(path):
        return None
    # newline="" disables universal-newline translation. Without it a CRLF file
    # is read as LF and written back as LF, so a merge that changed nothing
    # would silently rewrite every line and still report a clean convergence.
    with open(path, encoding="utf-8", newline="") as handle:
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
    elif base_lines is not None:
        merged_text, hunks = merge_text_3way(
            "".join(base_lines), "".join(current_lines), "".join(incoming_lines)
        )
        if merged_text is None:
            # Real overlapping edits, or git unavailable. Fall back to the
            # difflib report when git gave us no hunks to show.
            conflicts = hunks or line_conflicts(current_lines, incoming_lines)
            print(json.dumps({"ok": False, "conflicts": conflicts}))
            return 1
        merged_lines = [merged_text]
    else:
        conflicts = line_conflicts(current_lines, incoming_lines)
        print(json.dumps({"ok": False, "conflicts": conflicts}))
        return 1

    directory = os.path.dirname(os.path.abspath(args.output)) or "."
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".rig-merge-text.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as handle:
            handle.writelines(merged_lines)
        os.replace(tmp, args.output)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)

    print(json.dumps({"ok": True, "conflicts": []}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
