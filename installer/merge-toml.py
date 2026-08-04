#!/usr/bin/env python3
"""Best-effort section/key-aware TOML merge (issue #444, lane 444-C).

`.gitleaks.toml` is the one real TOML file this project ships, and this
installer has no third-party dependency budget (Python 3.9 is the floor here
-- see this project's CLAUDE.md "Known gotchas" -- so `tomllib`, stdlib only
since 3.11, cannot be assumed). Rather than hand-roll a full TOML AST parser,
this is a line-oriented, best-effort merge:

  - The file is split into top-level blocks: an implicit root block (any
    content before the first `[table]`/`[[array-table]]` header), one block
    per `[table]` header, and one block per `[[array-table]]` occurrence.
    A header only counts if it starts at column 0 -- this deliberately
    excludes indented continuation lines of a multi-line array (real TOML
    table headers are conventionally unindented; this project's own
    .gitleaks.toml follows that convention).
  - `[[array-table]]` blocks are always treated as a single atomic value --
    merging array-of-tables entries by identity is out of scope for a
    best-effort tool and risky to get wrong silently.
  - The root block and each `[table]` block are parsed as flat `key = value`
    lines when EVERY non-blank/non-comment line matches that shape. A
    multi-line array or string breaks this (continuation lines don't match
    `key = value`), which is expected and safe: that block just falls back
    to being compared as one atomic block instead of per-key. This is
    exactly what happens to .gitleaks.toml's own `[allowlist]` block (its
    `paths`/`regexes` arrays span multiple lines).
  - Merging otherwise follows the exact same three-way rule as
    installer/merge-json.py (see _convergence_common.py): a block/key
    customized on one side and untouched on the other is kept; changed
    identically on both sides converges silently; changed differently on
    both sides is a conflict.
  - A block/key left completely unchanged by the merge is emitted using its
    original raw text (comments and formatting preserved). A block/key that
    the merge actually changed is regenerated as plain `key = value` lines
    (losing any local comment inside that specific block) -- an accepted
    best-effort tradeoff, called out here rather than silently.

Usage:
    merge-toml.py --current <path> --incoming <path> --output <path> \
        [--base <path>]

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

_HEADER_RE = re.compile(r'^\[(\[?)([^\[\]]+)\]?\]\s*(#.*)?\s*$')
_KV_RE = re.compile(r'^\s*([A-Za-z0-9_.\-]+)\s*=\s*(.+?)\s*$')
_ROOT = "__root__"


def parse_blocks(text):
    """Split TOML text into an ordered {block_name: raw_text} mapping.

    `raw_text` for a named block includes its own header line, so it can be
    emitted verbatim with no extra bookkeeping. Array-table occurrences are
    disambiguated as `name#0`, `name#1`, ...
    """
    order = []
    blocks = {}
    array_counts = {}
    current_name = _ROOT
    current_lines = []

    def flush():
        blocks[current_name] = "".join(current_lines)
        order.append(current_name)

    for line in text.splitlines(keepends=True):
        if line.startswith("["):
            match = _HEADER_RE.match(line.rstrip("\n"))
            if match:
                flush()
                is_array = bool(match.group(1))
                name = match.group(2).strip()
                if is_array:
                    array_counts[name] = array_counts.get(name, -1) + 1
                    current_name = f"{name}#{array_counts[name]}"
                else:
                    current_name = name
                current_lines = [line]
                continue
        current_lines.append(line)
    flush()
    return order, blocks


def parse_simple_fields(body_text):
    """Parse a block body as flat `key = value` lines. Returns a dict, or
    None if any non-blank/non-comment line doesn't match that exact shape."""
    fields = {}
    for line in body_text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or stripped.startswith("["):
            continue
        match = _KV_RE.match(line)
        if not match:
            return None
        fields[match.group(1)] = match.group(2)
    return fields


def block_body(raw_text, name):
    """Strip a named block's own header line off its raw text (root has none)."""
    if name == _ROOT:
        return raw_text
    lines = raw_text.splitlines(keepends=True)
    return "".join(lines[1:]) if lines else ""


def normalize_trailing_blank_lines(text):
    """Collapse a block's trailing blank lines to at most one newline for
    COMPARISON purposes only. A block that gains a new sibling immediately
    after it (the common case: a whole new [table] appended at file end)
    picks up the blank line that used to separate it from EOF -- without
    this, that block would look "changed" on whichever side has the new
    sibling even though nothing inside the block itself changed. Callers
    that need the true original text for rendering must keep using the
    unnormalized raw block, not this."""
    stripped = text.rstrip("\n")
    if not text:
        return text
    return stripped + "\n"


def load(path):
    if not path or not os.path.exists(path):
        return [], {}
    with open(path, encoding="utf-8") as handle:
        text = handle.read()
    return parse_blocks(text)


def struct_for(order, blocks, other_orders_blocks):
    """Build the {block_name: dict-of-keys-or-raw-text} structure used for
    merging. A named (non-array-table) block is represented as a dict only
    when EVERY side that has that same block name also parses it cleanly --
    otherwise every side falls back to that block's raw text, so a parsed
    dict is never recursively compared against a raw string."""
    struct = {}
    for name in order:
        if "#" in name:  # array-table occurrence: always atomic
            struct[name] = normalize_trailing_blank_lines(blocks[name])
            continue
        body = block_body(blocks[name], name)
        parsed = parse_simple_fields(body)
        agrees = True
        for other_blocks in other_orders_blocks:
            if name in other_blocks and "#" not in name:
                other_body = block_body(other_blocks[name], name)
                if parse_simple_fields(other_body) is None:
                    agrees = False
                    break
        struct[name] = parsed if (parsed is not None and agrees) else normalize_trailing_blank_lines(blocks[name])
    return struct


def render_block(name, value):
    if isinstance(value, str):
        return value  # raw text, already includes its own header if any
    lines = [] if name == _ROOT else [f"[{name}]\n"]
    for key, val in value.items():
        lines.append(f"{key} = {val}\n")
    return "".join(lines)


def render_final(name, merged_value, current_blocks, incoming_blocks, current_struct, incoming_struct):
    """Prefer emitting a side's original raw text (comments/formatting
    intact) whenever the merge result for this block is identical to that
    side's own value -- only a block the merge actually changed by taking
    fields from both sides gets regenerated from scratch."""
    if name in current_struct and current_struct[name] == merged_value and name in current_blocks:
        return current_blocks[name]
    if name in incoming_struct and incoming_struct[name] == merged_value and name in incoming_blocks:
        return incoming_blocks[name]
    return render_block(name, merged_value)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base")
    parser.add_argument("--current", required=True)
    parser.add_argument("--incoming", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    try:
        base_order, base_blocks = load(args.base)
        with open(args.current, encoding="utf-8") as handle:
            current_order, current_blocks = parse_blocks(handle.read())
        with open(args.incoming, encoding="utf-8") as handle:
            incoming_order, incoming_blocks = parse_blocks(handle.read())
    except OSError as exc:
        print(json.dumps({"ok": False, "error": str(exc), "conflicts": []}))
        return 2

    base_struct = struct_for(base_order, base_blocks, [current_blocks, incoming_blocks])
    current_struct = struct_for(current_order, current_blocks, [base_blocks, incoming_blocks])
    incoming_struct = struct_for(incoming_order, incoming_blocks, [base_blocks, current_blocks])

    conflicts = []
    merged = merge_dict(base_struct, current_struct, incoming_struct, "", conflicts)

    if conflicts:
        print(json.dumps({"ok": False, "conflicts": conflicts}))
        return 1

    # Preserve current's block order; append any incoming-only blocks at the end.
    final_order = [name for name in current_order if name in merged]
    final_order += [name for name in incoming_order if name in merged and name not in final_order]

    rendered = "".join(
        render_final(name, merged[name], current_blocks, incoming_blocks, current_struct, incoming_struct)
        for name in final_order
    )

    directory = os.path.dirname(os.path.abspath(args.output)) or "."
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".rig-merge-toml.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(rendered)
        os.replace(tmp, args.output)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)

    print(json.dumps({"ok": True, "conflicts": []}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
