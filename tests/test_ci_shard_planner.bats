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

  JSON_OUTPUT="$output" python3 - "$REPO_ROOT" <<'PYEOF'
import json
import os
import sys

doc = json.loads(os.environ["JSON_OUTPUT"])
owner = {}
for shard in doc["include"]:
    for path in shard["files"].split():
        owner[path] = shard["shard"]

# Derive the heaviest files from the weights file rather than hard-coding
# them. A fixed list goes stale the moment the weight table changes — which
# it did when the upgrade suites were measured properly — and then fails for
# a reason that has nothing to do with the planner's behaviour.
weights = json.load(open(os.path.join(sys.argv[1], "tests/.ci-shard-weights.json")))
weights.pop("_default", None)
heavy = [path for path, _ in sorted(weights.items(), key=lambda kv: -kv[1])[:4]]
assert all(path in owner for path in heavy), [p for p in heavy if p not in owner]
assert len({owner[path] for path in heavy}) == len(heavy), {p: owner[p] for p in heavy}
PYEOF
}
