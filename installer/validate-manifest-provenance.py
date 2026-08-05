#!/usr/bin/env python3
"""Validate provenance metadata recorded in a Rig manifest (.rig-manifest.json).

Each manifest entry may carry base_revision/generator/provider fields
(added by install.sh's write_manifest_metadata() — see 444-B). Entries
written before that change simply lack these fields (or carry explicit
nulls); that is a normal "legacy/unknown provenance" state, not an error.
A field that IS present but holds a value outside its known vocabulary is
malformed and must be reported, never silently ignored.

When --running-version is supplied, entries are additionally checked for
version continuity (issue #463): a base_revision that is a parseable
X[.Y[.Z...]] version strictly newer than --running-version describes an
impossible/bogus state (a manifest claiming to be from an installer
release that, relative to what is actually running, does not exist yet —
either hand-corruption or a manifest written by some future installer).
That is reported as a distinct "future_revision" finding, separate from
"malformed" (an ordinary malformed field is a wrong-shaped value; a future
revision is a well-formed value describing an impossible state) and from
"legacy_provenance" (predates provenance tracking entirely). A
base_revision that is missing, null, equal to, older than, or not a clean
dotted-numeric string is never reported here — this check is intentionally
narrow and makes no attempt at real semantic version-compatibility
gating between releases. Omitting --running-version disables this check
entirely (future_revision is always an empty list), preserving the exact
prior behavior for any caller that does not pass it.

This script was originally a standalone, isolated building block for a
future doctor/postflight gate (444-H); it is now wired into `rig doctor`'s
manifest_provenance gate (see templates/project/bin/rig) and into
install.sh's validate_manifest_provenance() wrapper, which the
agent-plan/agent-upgrade upgrade flow consults to refuse on a future
base_revision (issue #463).

Exit codes:
  0  all entries are either well-formed (and not future-revision) or
     legacy/unknown provenance
  1  one or more entries have malformed provenance fields and/or a
     future_revision finding
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


def parse_version(value):
    """Parse a plain dotted-numeric version string ("1.23.0") into a tuple
    of ints for comparison.

    Returns None for anything that is not a clean dotted-numeric string
    (missing, null, "unknown", pre-release/build suffixes, etc). This
    project's VERSION strings are always simple X.Y.Z, so no general
    semver parser is needed — an unparseable value is deliberately treated
    as "cannot confirm future", never flagged, to keep the future_revision
    check narrow and free of false positives (issue #463).
    """
    if not isinstance(value, str) or not value:
        return None
    parts = value.split(".")
    result = []
    for part in parts:
        if not part.isdigit():
            return None
        result.append(int(part))
    return tuple(result)


def is_future_revision(base_revision, running_version):
    """True when base_revision is a parseable version strictly newer than
    running_version. False (never flagged) when either value is missing or
    not a clean dotted-numeric string.
    """
    base = parse_version(base_revision)
    running = parse_version(running_version)
    if base is None or running is None:
        return False
    return base > running


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("metadata", help="path to a .rig-manifest.json file")
    parser.add_argument(
        "--running-version",
        default=None,
        help=(
            "the currently running installer's own VERSION; when supplied, "
            "entries whose base_revision is a parseable version strictly "
            "newer than this are reported in future_revision (issue #463). "
            "Omit to skip this check entirely (prior behavior)."
        ),
    )
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
    future_revision = []
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

        if args.running_version and isinstance(entry, dict):
            base_revision = entry.get("base_revision")
            if is_future_revision(base_revision, args.running_version):
                future_revision.append({
                    "path": rel,
                    "base_revision": base_revision,
                    "running_version": args.running_version,
                })

    ok = not malformed and not future_revision
    print(json.dumps({
        "ok": ok,
        "checked": len(entries),
        "malformed": malformed,
        "legacy_provenance": legacy,
        "future_revision": future_revision,
    }, separators=(",", ":")))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
