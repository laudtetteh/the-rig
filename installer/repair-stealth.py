#!/usr/bin/env python3
"""Safe, additive repair for stealth-mode git-exclude coverage.

Consumes the read-only classification produced by audit-stealth.py and
appends any missing pattern to .git/info/exclude for artifacts classified
as tracked_leak or untracked_leak. This is the only mutation performed:

  - Never removes or rewrites an existing .git/info/exclude line.
  - Never duplicates a pattern already present (exact-line match, same
    idempotency rule install.sh's own _stealth_exclude helper uses).
  - Never touches the git index and never deletes a file. A tracked_leak
    (a file already committed to git) is NOT untracked here — adding an
    exclude pattern has no effect on an already-tracked path; removing it
    from tracking is an explicitly separate, more carefully scoped repair
    action against real projects, deliberately out of scope for this tool.
  - Never touches a path this tool did not itself classify as a leak —
    unrelated existing exclude rules and unrelated user files are left
    completely alone.

Exit status: 0 on success (including "nothing to repair"), 2 on a usage or
input error. A tracked_leak surviving in the result's "still_tracked" list
is not a failure of this tool — it is expected and must be resolved via a
separate, explicitly authorized repair.
"""
import json
import os
import subprocess
import sys


def run_audit(target):
    audit_script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "audit-stealth.py")
    result = subprocess.run(
        [sys.executable, audit_script, target],
        capture_output=True,
        text=True,
        check=False,
    )
    return json.loads(result.stdout)


def main():
    parser_error = None
    if len(sys.argv) != 2:
        parser_error = "usage: repair-stealth.py <target>"
    if parser_error:
        print(json.dumps({"ok": False, "error": {"code": "usage", "message": parser_error}}))
        return 2

    target = os.path.abspath(sys.argv[1])

    try:
        audit = run_audit(target)
    except (OSError, json.JSONDecodeError) as exc:
        print(json.dumps({"ok": False, "error": {"code": "audit-failed", "message": str(exc)}}))
        return 2

    if audit.get("error"):
        print(json.dumps({"ok": False, "error": audit["error"]}))
        return 2

    if not audit.get("stealth"):
        print(json.dumps({
            "ok": True,
            "target": target,
            "repaired": [],
            "message": audit.get("message", "not a stealth/external install — nothing to repair"),
        }, indent=2, sort_keys=True))
        return 0

    exclude_path = os.path.join(target, ".git", "info", "exclude")
    if not os.path.isfile(exclude_path):
        print(json.dumps({
            "ok": False,
            "error": {"code": "no-exclude-file", "message": f"{exclude_path} not found"},
        }))
        return 2

    with open(exclude_path, encoding="utf-8") as fh:
        existing_lines = {line.rstrip("\n") for line in fh}

    leaked = [a["path"] for a in audit.get("artifacts", []) if a.get("status") in ("tracked_leak", "untracked_leak")]
    to_add = [p for p in leaked if p not in existing_lines]

    if to_add:
        with open(exclude_path, "a", encoding="utf-8") as fh:
            fh.write("\n# The Rig — stealth repair: previously uncovered artifacts\n")
            for pattern in to_add:
                fh.write(pattern + "\n")

    result = {
        "ok": True,
        "target": target,
        "exclude_file": exclude_path,
        "repaired": to_add,
        "already_covered": [p for p in leaked if p not in to_add],
        "still_tracked": [a["path"] for a in audit.get("artifacts", []) if a.get("status") == "tracked_leak"],
    }
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
