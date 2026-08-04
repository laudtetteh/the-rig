#!/usr/bin/env python3
"""Shared three-way / structure-aware merge primitive (issue #444, lane 444-C).

Not a standalone CLI -- imported by merge-json.py, merge-toml.py, and
merge-frontmatter-markdown.py. Kept in its own module purely so the same
algorithm is exercised identically by every structure-aware merge helper
rather than re-implemented per format.

No trusted base/provenance manifest field exists yet (issue #444 lane 444-B
adds base_revision/generator/provider fields; it had not merged as of this
lane). `merge_dict()` therefore accepts an optional base mapping and
degrades gracefully when it is empty/absent: a key present on both sides
with differing values is always reported as a conflict rather than guessed,
per this lane's "when in doubt, report a conflict" policy. Once 444-B lands
and a trusted base becomes available, passing its resolved value as `base`
here is a thin adapter -- the merge algorithm itself does not change.

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

MISSING = object()


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
