#!/usr/bin/env python3
"""Resolve a project's Rig directory without changing characters in .rigpath."""

import pathlib
import sys


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: rig-path.py PROJECT_ROOT", file=sys.stderr)
        return 64
    root = pathlib.Path(sys.argv[1]).resolve()
    pointer = root / ".rigpath"
    if pointer.exists() or pointer.is_symlink():
        if pointer.is_symlink() or not pointer.is_file():
            print(".rigpath must be a regular file", file=sys.stderr)
            return 3
        lines = pointer.read_text(encoding="utf-8").splitlines()
        if len(lines) != 1 or not lines[0]:
            print(".rigpath must contain one nonempty path", file=sys.stderr)
            return 3
        path = pathlib.Path(lines[0])
        print(path if path.is_absolute() else root / path)
    else:
        print(root / ".rig")
    return 0


if __name__ == "__main__":
    sys.exit(main())
