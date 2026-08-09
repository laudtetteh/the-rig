#!/usr/bin/env bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
PLANNER="$REPO_ROOT/tests/plan-ci-shards.py"

@test "weighted CI shard planner assigns every Bats file exactly once" {
  run python3 "$PLANNER" --weights "$REPO_ROOT/tests/.ci-shard-weights.json" --shards 8
  [ "$status" -eq 0 ]

  JSON_OUTPUT="$output" python3 - "$REPO_ROOT" <<'PYEOF'
import glob
import json
import os
import sys

repo = sys.argv[1]
doc = json.loads(os.environ["JSON_OUTPUT"])
expected = sorted(os.path.relpath(path, repo) for path in glob.glob(os.path.join(repo, "tests/*.bats")))
actual = sorted(path for shard in doc["include"] for path in shard["files"].split())
assert actual == expected
assert len(doc["include"]) == 8
PYEOF
}

@test "weighted CI shard planner separates the heaviest measured files" {
  run python3 "$PLANNER" --weights "$REPO_ROOT/tests/.ci-shard-weights.json" --shards 8
  [ "$status" -eq 0 ]

  JSON_OUTPUT="$output" python3 - <<'PYEOF'
import json
import os
import sys

doc = json.loads(os.environ["JSON_OUTPUT"])
owner = {}
for shard in doc["include"]:
    for path in shard["files"].split():
        owner[path] = shard["shard"]

heavy = [
    "tests/test_install_a.bats",
    "tests/test_install_d.bats",
    "tests/test_hook_lifecycle.bats",
    "tests/test_install_e.bats",
]
assert len({owner[path] for path in heavy}) == len(heavy)
PYEOF
}
