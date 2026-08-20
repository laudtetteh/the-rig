#!/usr/bin/env python3
"""Shared three-way / structure-aware merge primitive (issue #444, lane 444-C).

Not a standalone CLI -- imported by merge-json.py, merge-toml.py, and
merge-frontmatter-markdown.py. Kept in its own module purely so the same
algorithm is exercised identically by every structure-aware merge helper
rather than re-implemented per format.

A trusted base is available since issue #560
(installer/resolve-historical-base.py). `merge_dict()` still accepts an empty
base mapping and degrades gracefully without one: a key present on both sides
with differing values is reported as a conflict rather than guessed, per the
"when in doubt, report a conflict" policy.

`merge_text_3way()` (below) adds the line-level counterpart for content that
has no key structure to merge on -- Markdown prose bodies and shell scripts.
Issue #561: a trusted base alone converged only 1 of the 16 files blocking a
real downstream rollout, because treating a whole body as one atomic value
means "both sides touched this file anywhere" is always a conflict. Line-level
merging raises that to 5, with the remaining 11 being genuine overlapping
edits.

Algorithm (per key, across the union of base/current/incoming keys):
  current == incoming            -> take that value (already converged)
  current == base                -> only incoming changed -> take incoming
  incoming == base                -> only current changed -> take current
  otherwise                      -> both sides changed it differently -> conflict

A MISSING key is treated as just another distinct value, so the same four
rules also cover additions and deletions correctly:
  - a key only incoming added (missing from base and current) is adopted
  - a key only current added (missing from base and incoming) is preserved
  - a key the user deleted that incoming left alone stays deleted
  - a key the user deleted that incoming also changed is a conflict
"""

import os
import re
import subprocess
import tempfile

MISSING = object()

_CONFLICT_START = re.compile(r"^<{7}(?: |$)")
_CONFLICT_BASE = re.compile(r"^\|{7}(?: |$)")
_CONFLICT_MID = re.compile(r"^={7}$")
_CONFLICT_END = re.compile(r"^>{7}(?: |$)")
_SNIPPET_LIMIT = 200


def _snippet(lines):
    text = "".join(lines)
    if len(text) > _SNIPPET_LIMIT:
        text = text[:_SNIPPET_LIMIT] + "…"
    return text


def _parse_conflict_hunks(merged_text, label):
    """Turn git's conflict markers into structured conflict records.

    Reporting which hunks actually collided is the whole point of refusing
    with detail rather than a generic "customized, skipped".
    """
    hunks = []
    current, incoming = [], []
    state = None
    for line in merged_text.splitlines(keepends=True):
        stripped = line.rstrip("\n")
        # `not state` matters: this repo ships docs that literally contain
        # conflict markers, and without the guard a stray `<<<<<<< ` inside an
        # already-open hunk would restart it and emit a phantom conflict.
        if not state and _CONFLICT_START.match(stripped):
            state, current, incoming = "current", [], []
            continue
        if state and _CONFLICT_BASE.match(stripped):
            state = "base"
            continue
        if state and _CONFLICT_MID.match(stripped):
            state = "incoming"
            continue
        if state and _CONFLICT_END.match(stripped):
            hunks.append({
                "path": "%s hunk %d" % (label, len(hunks) + 1),
                "current": _snippet(current),
                "incoming": _snippet(incoming),
            })
            state = None
            continue
        if state == "current":
            current.append(line)
        elif state == "incoming":
            incoming.append(line)
    return hunks


def merge_text_3way(base_text, current_text, incoming_text, label="lines"):
    """Line-level three-way merge. Returns (merged_text_or_None, conflicts).

    Delegates to `git merge-file`, deliberately. A hand-rolled hunk-aligning
    merge would be guessing at semantics it cannot verify, whereas git's
    implementation is the same one every developer already trusts for this
    exact operation -- and git is already a hard dependency of the installer.

    A base is required. Without one there is no way to know which side
    changed, so callers must keep using the conservative whole-file rules.
    """
    if base_text is None:
        return None, []
    workdir = tempfile.mkdtemp(prefix=".rig-merge3.")
    try:
        paths = {}
        for name, text in (
            ("current", current_text), ("base", base_text), ("incoming", incoming_text)
        ):
            paths[name] = os.path.join(workdir, name)
            # newline="" so line endings survive the round trip. Callers read
            # with universal newlines, so a CRLF file would otherwise come back
            # all-LF and be reported as a clean convergence while every single
            # line had in fact changed.
            with open(paths[name], "w", encoding="utf-8", newline="") as handle:
                handle.write(text)
        try:
            proc = subprocess.run(
                ["git", "merge-file", "-p", "--diff3",
                 "-L", "yours", "-L", "base", "-L", "incoming",
                 paths["current"], paths["base"], paths["incoming"]],
                capture_output=True,
            )
        except OSError:
            return None, []  # git unavailable: caller falls back
        merged = proc.stdout.decode("utf-8", "replace")
        if proc.returncode == 0:
            return merged, []
        # git merge-file returns the number of conflicts, or 255 on its own
        # failure (bad usage, unreadable input); a negative code means a
        # signal. Only a plausible conflict count is a real conflict —
        # reporting "these lines conflict" when the truth is "git broke" would
        # send the operator after the wrong problem.
        if proc.returncode < 0 or proc.returncode >= 255:
            return None, []
        return None, _parse_conflict_hunks(merged, label)
    finally:
        for name in ("current", "base", "incoming"):
            path = os.path.join(workdir, name)
            if os.path.exists(path):
                os.unlink(path)
        os.rmdir(workdir)


def merge_dict(base, current, incoming, path_prefix, conflicts):
    """Return the merged dict for one base/current/incoming triple.

    `base`, `current`, and `incoming` are plain dicts (base may be `{}` when
    no trusted base is available). Values that are dicts on both `current`
    and `incoming` are merged recursively; every other value (str, list,
    int, bool, None, ...) is treated as an atomic leaf compared by equality.
    Conflicts are appended to `conflicts` as
    `{"path": "a.b.c", "current": <value-or-None>, "incoming": <value-or-None>}`
    and the key is omitted from the returned dict -- callers must treat any
    non-empty `conflicts` list as "do not apply this merge".
    """
    merged = {}
    seen = set()
    ordered_keys = []
    for source in (current, incoming, base):
        for key in source.keys():
            if key not in seen:
                seen.add(key)
                ordered_keys.append(key)

    for key in ordered_keys:
        b = base.get(key, MISSING)
        c = current.get(key, MISSING)
        i = incoming.get(key, MISSING)
        child_path = f"{path_prefix}.{key}" if path_prefix else str(key)

        if isinstance(c, dict) and isinstance(i, dict):
            sub_base = b if isinstance(b, dict) else {}
            merged[key] = merge_dict(sub_base, c, i, child_path, conflicts)
            continue

        if c == i:
            if c is not MISSING:
                merged[key] = c
            continue
        if c == b:
            if i is not MISSING:
                merged[key] = i
            continue
        if i == b:
            if c is not MISSING:
                merged[key] = c
            continue
        conflicts.append({
            "path": child_path,
            "current": None if c is MISSING else c,
            "incoming": None if i is MISSING else i,
        })
    return merged
