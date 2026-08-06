#!/usr/bin/env python3
"""Frontmatter + prose three-way merge for command/process Markdown
(issue #444, lane 444-C).

Targets files shaped like `.claude/commands/*.md`, `.claude/agents/*.md`,
and `.rig/processes/*.md`: an optional leading `---`-delimited flat YAML
frontmatter block (`key: value` lines only -- no nested mappings, lists, or
block scalars; this project has no YAML parser in its stdlib-only Python
dependency budget, see installer/merge-toml.py for the same constraint
applied to TOML) followed by a Markdown prose body.

Frontmatter keys are merged structurally with the exact same rule as
installer/merge-json.py (see _convergence_common.py): a key customized on
one side and untouched on the other is kept; a key changed identically on
both sides converges silently; a key changed differently on both sides is a
conflict. If either side's frontmatter block does not parse as flat
`key: value` lines, both sides fall back to a single whole-block text
comparison so the merge never partially rewrites a block it did not fully
understand.

The prose body is treated as one atomic value: if the user's body and the
incoming body are identical, nothing to do; if they differ, this lane runs
without a trusted base (issue #444 lane 444-B, which supplies one, is
unmerged), so there is no way to know which side "changed" -- differing
bodies are always reported as a conflict rather than guessed, never
semantically merged.

Usage:
    merge-frontmatter-markdown.py --current <path> --incoming <path> \
        --output <path> [--base <path>]

Prints one JSON report line to stdout (same shape as merge-json.py) and
exits 0 (merged), 1 (conflicts, nothing written), or 2 (I/O failure).
"""
import argparse
import json
import os
import re
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _convergence_common import merge_dict  # noqa: E402

_KV_RE = re.compile(r'^([A-Za-z0-9_.\-]+):[ \t]?(.*)$')


def split_frontmatter(text):
    """Return (raw_frontmatter_body_or_None, body). raw excludes the '---'
    delimiter lines themselves; None means no frontmatter block is present."""
    lines = text.splitlines(keepends=True)
    if not lines or lines[0].rstrip("\n") != "---":
        return None, text
    end_index = None
    for idx in range(1, len(lines)):
        if lines[idx].rstrip("\n") == "---":
            end_index = idx
            break
    if end_index is None:
        # Unterminated frontmatter marker -- too ambiguous to trust; treat
        # the whole file as body-only rather than guess where it ends.
        return None, text
    return "".join(lines[1:end_index]), "".join(lines[end_index + 1:])


def parse_fields(raw):
    """Parse flat `key: value` lines. Returns a dict, or None if any
    non-blank/non-comment line doesn't match that exact shape (nested
    mappings, list items, block scalars, or indented continuation lines)."""
    fields = {}
    for line in raw.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if line[:1].isspace():
            return None  # indented line -- not a flat top-level key
        match = _KV_RE.match(line)
        if not match:
            return None
        fields[match.group(1)] = match.group(2).strip()
    return fields


def frontmatter_parts(text):
    """Return (raw_with_delimiters_or_None, parsed_dict_or_None, body)."""
    raw, body = split_frontmatter(text)
    if raw is None:
        return None, None, body
    return f"---\n{raw}---\n", parse_fields(raw), body


def load(path):
    if not path or not os.path.exists(path):
        return None, None, ""  # no base file: no frontmatter, empty body
    with open(path, encoding="utf-8") as handle:
        return frontmatter_parts(handle.read())


def build_struct(raw, parsed, body, use_dict):
    struct = {"body": body}
    if raw is not None:
        struct["frontmatter"] = parsed if use_dict else raw
    return struct


def render(struct):
    parts = []
    if "frontmatter" in struct:
        value = struct["frontmatter"]
        if isinstance(value, dict):
            parts.append("---\n")
            for key, val in value.items():
                parts.append(f"{key}: {val}\n")
            parts.append("---\n")
        else:
            parts.append(value)
    parts.append(struct.get("body", ""))
    return "".join(parts)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base")
    parser.add_argument("--current", required=True)
    parser.add_argument("--incoming", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    try:
        base_raw, base_parsed, base_body = load(args.base)
        with open(args.current, encoding="utf-8") as handle:
            cur_raw, cur_parsed, cur_body = frontmatter_parts(handle.read())
        with open(args.incoming, encoding="utf-8") as handle:
            inc_raw, inc_parsed, inc_body = frontmatter_parts(handle.read())
    except OSError as exc:
        print(json.dumps({"ok": False, "error": str(exc), "conflicts": []}))
        return 2

    # Only trust field-level (dict) frontmatter merging when every side that
    # actually has a frontmatter block parsed cleanly. Otherwise fall back to
    # comparing the whole block verbatim on every side that has one, so a
    # dict never gets recursively merged against a raw string it can't
    # meaningfully be compared to.
    sides_with_frontmatter = [
        (raw, parsed) for raw, parsed in ((base_raw, base_parsed), (cur_raw, cur_parsed), (inc_raw, inc_parsed))
        if raw is not None
    ]
    use_dict = bool(sides_with_frontmatter) and all(parsed is not None for _, parsed in sides_with_frontmatter)

    base_struct = build_struct(base_raw, base_parsed, base_body, use_dict)
    current_struct = build_struct(cur_raw, cur_parsed, cur_body, use_dict)
    incoming_struct = build_struct(inc_raw, inc_parsed, inc_body, use_dict)

    conflicts = []
    merged = merge_dict(base_struct, current_struct, incoming_struct, "", conflicts)

    if conflicts:
        print(json.dumps({"ok": False, "conflicts": conflicts}))
        return 1

    # render()'s dict-mode reconstruction always drops any comment or blank
    # line inside the frontmatter block -- parse_fields() has to skip them
    # to build a dict at all, and there's no way back from a dict to the
    # comments that weren't stored in it. Retro-audit finding, PR #452: this
    # was unconditional, on every successful merge, silently discarding any
    # user-added frontmatter comment even when nothing about the actual
    # field values needed to change on that side. Mirrors merge-toml.py's
    # own render_final() pattern: when the merged fields turn out to be
    # exactly one side's original parsed fields, reuse that side's raw text
    # verbatim (comments, blank lines, and all) instead of resynthesizing
    # a dict-only reconstruction that can't represent them.
    if use_dict and "frontmatter" in merged:
        if cur_parsed is not None and merged["frontmatter"] == cur_parsed and cur_raw is not None:
            merged["frontmatter"] = cur_raw
        elif inc_parsed is not None and merged["frontmatter"] == inc_parsed and inc_raw is not None:
            merged["frontmatter"] = inc_raw

    directory = os.path.dirname(os.path.abspath(args.output)) or "."
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".rig-merge-md.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(render(merged))
        os.replace(tmp, args.output)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)

    print(json.dumps({"ok": True, "conflicts": []}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
