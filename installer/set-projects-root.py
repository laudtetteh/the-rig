#!/usr/bin/env python3
"""Validate or atomically add an explicitly selected user project root."""

import argparse
import json
import os
from pathlib import Path
import stat
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "templates/project/bin"))
from rig_project_roots import RootsConfigError, read_project_roots  # noqa: E402


def selected_root(value):
    path = Path(value)
    if not path.is_absolute():
        raise RootsConfigError("--projects-root requires an absolute directory")
    try:
        path = path.resolve(strict=True)
    except OSError as exc:
        raise RootsConfigError("--projects-root must exist") from exc
    if not path.is_dir():
        raise RootsConfigError("--projects-root must be a directory")
    return path


def configure(value, write):
    root = selected_root(value)
    home = Path.home()
    config = home / ".rig" / "config.json"
    if config.parent.is_symlink():
        raise RootsConfigError("~/.rig must be a directory, not a symlink")
    # Ignore an environment override while checking the file about to change.
    read_project_roots(home=home, environ={})
    if config.exists():
        data = json.loads(config.read_text(encoding="utf-8"))
    else:
        data = {"schema_version": 1, "projects_roots": []}
    if not write:
        return root
    config.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    roots = data["projects_roots"]
    if str(root) not in roots:
        roots.append(str(root))
    fd, temp = tempfile.mkstemp(prefix=".config-", dir=config.parent)
    try:
        os.fchmod(fd, stat.S_IRUSR | stat.S_IWUSR)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(data, stream, indent=2)
            stream.write("\n")
        os.replace(temp, config)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)
    return root


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("check", "write"))
    parser.add_argument("root")
    args = parser.parse_args()
    try:
        print(configure(args.root, args.action == "write"))
    except (RootsConfigError, OSError, UnicodeError, json.JSONDecodeError) as exc:
        print(str(exc), file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
