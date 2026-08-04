#!/usr/bin/env python3
"""Validate provenance metadata recorded in a Rig manifest (.rig-manifest.json).

Each manifest entry may carry base_revision/generator/provider fields
(added by install.sh's write_manifest_metadata() — see 444-B). Entries
written before that change simply lack these fields (or carry explicit
nulls); that is a normal "legacy/unknown provenance" state, not an error.
A field that IS present but holds a value outside its known vocabulary is
malformed and must be reported, never silently ignored.

This script is a standalone, isolated building block for a future
doctor/postflight gate (444-H). It is not wired into `rig doctor` or any
upgrade decision path in this lane.

Exit codes:
  0  all entries are either well-formed or legacy/unknown provenance
  1  one or more entries have malformed provenance fields
  2  the manifest metadata file itself is unreadable or has an
     unrecognized schema
"""
import argparse
import json
import sys

# Keep these vocabularies in sync with install.sh's is_rig_owned(),
# manifest_artifact_source(), and write_manifest_metadata().
KNOWN_OWNERS = {"rig", "user"}
KNOWN_SOURCES = {
    "generated-codex",
    "codex-native",
    "claude-native",
    "shared-rig",
    "project-tooling",
    "project-user",
}
KNOWN_GENERATORS = {"install.sh", "codex-mirror"}
KNOWN_PROVIDERS = {"claude", "codex", "both", "none"}
KNOWN_TYPES = {"file", "directory", "symlink", "other", "missing"}

# Fields introduced by 444-B. An entry lacking all three (or carrying
# explicit null for all three) predates provenance tracking.
PROVENANCE_FIELDS = ("base_revision", "generator", "provider")


def validate_entry(entry):
    """Return a list of (field, reason) problems for one manifest entry.

    A field that is absent or explicitly null is treated as "unknown
    provenance", not an error. A field that is present with a value outside
    its known vocabulary is malformed.
    """
    if not isinstance(entry, dict):
        return [("entry", "not an object")]

    problems = []

    def check(field, known):
        value = entry.get(field)
        if value is None:
            return
        if value not in known:
            problems.append((field, f"unrecognized value: {value!r}"))

    check("owner", KNOWN_OWNERS)
    check("source", KNOWN_SOURCES)
    check("generator", KNOWN_GENERATORS)
    check("provider", KNOWN_PROVIDERS)
    check("type", KNOWN_TYPES)

    base_revision = entry.get("base_revision")
    if base_revision is not None and not isinstance(base_revision, str):
        problems.append((
            "base_revision",
            f"must be a string or null, got {type(base_revision).__name__}",
        ))

    sha256 = entry.get("sha256")
    if not isinstance(sha256, str) or not sha256:
        problems.append(("sha256", "missing or empty"))

    return problems


def is_legacy(entry):
    """True when an entry predates provenance metadata (444-B)."""
    return all(entry.get(field) is None for field in PROVENANCE_FIELDS)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("metadata", help="path to a .rig-manifest.json file")
    args = parser.parse_args()

    try:
        with open(args.metadata, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        print(json.dumps({
            "ok": False,
            "error": {"code": "manifest-unreadable", "message": str(exc)},
        }))
        return 2

    entries = data.get("entries")
    if data.get("schema_version") != 1 or not isinstance(entries, dict):
        print(json.dumps({
            "ok": False,
            "error": {
                "code": "manifest-schema-invalid",
                "message": "missing schema_version 1 or entries object",
            },
        }))
        return 2

    malformed = []
    legacy = []
    for rel in sorted(entries):
        entry = entries[rel]
        problems = validate_entry(entry)
        if problems:
            malformed.append({
                "path": rel,
                "problems": [{"field": f, "reason": r} for f, r in problems],
            })
        elif is_legacy(entry):
            legacy.append(rel)

    ok = not malformed
    print(json.dumps({
        "ok": ok,
        "checked": len(entries),
        "malformed": malformed,
        "legacy_provenance": legacy,
    }, separators=(",", ":")))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
