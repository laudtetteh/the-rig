#!/usr/bin/env python3
"""Read-only stealth-mode artifact classification for The Rig.

Given a stealth/external-tracked project, enumerates every path the
installer's stealth mode is expected to keep out of git (per the
_stealth_exclude block in install.sh) and classifies each as:

  excluded        - not tracked by git and covered by an ignore/exclude rule
  tracked_leak    - tracked by git despite being a Rig-generated artifact
                    (a real leak; .gitignore/.git/info/exclude cannot hide a
                    tracked path — the file must be untracked separately,
                    which this tool deliberately does not do)
  untracked_leak  - present on disk, not tracked, but not covered by any
                    ignore/exclude rule (git status would show it as "??")
  missing         - not present on disk and not tracked (nothing to protect)

The expected-artifact set is derived from the project's own Rig manifest
(every relative path the installer actually wrote — a complete, drift-free
record) plus a small static safety net of known generated-launcher/top-level
paths for legacy installs that predate manifest tracking. This script never
writes anything. See repair-stealth.py for the safe, additive repair action
that consumes this script's output.
"""
import argparse
import json
import os
import subprocess
import sys

# Fixed stealth-policy top-level entries mirrored from install.sh's
# _stealth_exclude block. This is a safety net for legacy/pre-manifest
# installs only — for any current install, these same paths are also
# present in the manifest and would be discovered there regardless.
STEALTH_TOP_LEVEL = [
    "CLAUDE.md",
    "PROJECT_BRIEF.md",
    ".claude/",
    ".agents/",
    ".codex/",
    ".mcp.json",
    ".playwright-mcp/",
    ".github/",
    ".gitleaks.toml",
    "docs/features/README.md",
    ".rig-backup/",
    ".rig/",
    ".rigpath",
]


def read_rigpath(target):
    path = os.path.join(target, ".rigpath")
    try:
        with open(path, encoding="utf-8") as fh:
            value = fh.read().strip()
    except OSError:
        return None
    return value or None


def read_manifest_paths(rig_dir):
    """Every relative path recorded in the project's Rig manifest.

    The manifest records ALL installed files (not just Rig-owned ones),
    so it is a complete, always-current inventory of what the installer
    actually wrote into this target — including any bin/rig-* launcher
    added in a future release, with no code change required here.
    """
    manifest = os.path.join(rig_dir, "memory", ".rig-manifest")
    paths = set()
    try:
        with open(manifest, encoding="utf-8") as fh:
            for line in fh:
                line = line.rstrip("\n")
                if not line or line.startswith("#"):
                    continue
                parts = line.split(None, 1)
                if len(parts) == 2:
                    paths.add(parts[1])
    except OSError:
        pass
    return paths


def discover_launcher_paths(target):
    """Safety net: any launcher The Rig actually ships, physically present
    in the target, even if it predates manifest tracking or the manifest is
    unreadable. Scoped to the installer's own real template source rather
    than a name.startswith("rig") heuristic on the target's directory
    listing -- retro-audit finding, PR #449: that heuristic matched ANY
    bin/ file starting with "rig", not just ones The Rig generated. A user's
    own unrelated script (e.g. bin/rig-my-deploy-script.sh) was silently
    misclassified as a leak, and the documented manual-repair workflow
    (repair-stealth.py) would then append it to .git/info/exclude, hiding
    real content from git -- exactly the failure install.sh's own
    stealth-exclude enumeration explicitly reasons about and rejects a
    "bin/rig*" glob for. Mirrors install.sh: enumerate the real template
    source, never guess from a name pattern. If the template source isn't
    colocated (a normal downstream install, not this repo's own checkout),
    there is no safety net for un-manifested legacy launchers -- correct,
    since guessing from names is exactly the bug being fixed here.
    """
    template_bin = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                 "..", "templates", "project", "bin")
    try:
        known_names = set(os.listdir(template_bin))
    except OSError:
        return set()
    bin_dir = os.path.join(target, "bin")
    found = set()
    try:
        for name in os.listdir(bin_dir):
            if name in known_names:
                found.add(f"bin/{name}")
    except OSError:
        pass
    return found


def git(target, *args):
    return subprocess.run(
        ["git", "-C", target, *args],
        capture_output=True,
        text=True,
        check=False,
    )


def is_tracked(target, rel):
    # No --error-unmatch: rel may be a directory pathspec (e.g. ".claude"),
    # and a non-empty listing under it is itself proof of a tracked leak.
    result = git(target, "ls-files", "--", rel)
    return bool(result.stdout.strip())


def is_ignored(target, rel):
    result = git(target, "check-ignore", "-q", "--", rel)
    return result.returncode == 0


def classify(target, rel):
    check_rel = rel[:-1] if rel.endswith("/") and rel != "/" else rel
    abs_path = os.path.join(target, check_rel)
    if is_tracked(target, check_rel):
        return "tracked_leak"
    if not os.path.lexists(abs_path):
        return "missing"
    if is_ignored(target, check_rel):
        return "excluded"
    return "untracked_leak"


def collect_expected_paths(target, rig_dir):
    expected = set(STEALTH_TOP_LEVEL)
    if rig_dir:
        expected |= read_manifest_paths(rig_dir)
    expected |= discover_launcher_paths(target)
    # Manifest entries under .rig/ route to the external Rig directory in
    # stealth/external mode and never land in the target repo at all — they
    # are not part of the target's git-exclude surface and would always
    # misreport as "missing".
    #
    # .git/hooks/* entries (manifest-tracked since 444-G's safe stealth hook
    # lifecycle) are structurally outside the git working tree: .git/ itself
    # is never tracked, never shown by `git status`, and `git check-ignore`
    # does not apply gitignore semantics to paths inside it. Running them
    # through the tracked/ignored pipeline this tool uses for real working-
    # tree paths always misreports them as untracked_leak, even on a fresh,
    # correctly stealth-installed project. They are safe by construction and
    # excluded from the expected-artifact set here, the same way .rig/* is.
    return {p for p in expected if not p.startswith(".rig/") and not p.startswith(".git/")}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("target", help="path to the stealth/external-tracked project")
    args = parser.parse_args()
    target = os.path.abspath(args.target)

    if not os.path.isdir(os.path.join(target, ".git")):
        print(json.dumps({
            "ok": False,
            "error": {"code": "not-a-git-repo", "message": f"{target} is not a git repository"},
        }))
        return 2

    rigpath = read_rigpath(target)
    if not rigpath:
        print(json.dumps({
            "ok": True,
            "target": target,
            "stealth": False,
            "message": "No .rigpath found — not a stealth/external install.",
            "artifacts": [],
        }, indent=2, sort_keys=True))
        return 0

    rig_dir = rigpath if os.path.isabs(rigpath) else os.path.join(target, rigpath)
    expected = collect_expected_paths(target, rig_dir)

    artifacts = []
    leaks = 0
    for rel in sorted(expected):
        status = classify(target, rel)
        if status in ("tracked_leak", "untracked_leak"):
            leaks += 1
        artifacts.append({"path": rel, "status": status})

    result = {
        "ok": leaks == 0,
        "target": target,
        "rig_dir": rig_dir,
        "stealth": True,
        "artifacts": artifacts,
        "leak_count": leaks,
    }
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0 if leaks == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
