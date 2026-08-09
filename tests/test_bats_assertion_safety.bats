#!/usr/bin/env bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

@test "bats assertions avoid bash 3.2 bare [[ ]] and leading ! command traps" {
  run python3 - "$REPO_ROOT/tests" <<'PYEOF'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
bare = re.compile(r'^\s*\[\[.*\]\]\s*$')
inline_bare = re.compile(r';\s*\[\[.*\]\]\s*$')
negated = re.compile(r'^\s*!\s+(grep|jq|find|git|cmp|diff|python|python3|test)\b')
failures = []

for path in sorted(root.glob("*.bats")):
    for lineno, line in enumerate(path.read_text().splitlines(), 1):
        stripped = line.strip()
        if stripped.startswith("#"):
            continue
        if "|| return 1" in line:
            continue
        if bare.search(line) or inline_bare.search(line) or negated.search(line):
            failures.append(f"{path.name}:{lineno}:{line}")

if failures:
    print("\n".join(failures))
    raise SystemExit(1)
PYEOF
  [ "$status" -eq 0 ]
}
