#!/usr/bin/env bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  TEST_ROOT="$(mktemp -d)"
}

teardown() {
  rm -rf "$TEST_ROOT"
}

@test "project GitHub templates have canonical source parity" {
  for rel in \
    .github/PULL_REQUEST_TEMPLATE.md \
    .github/ISSUE_TEMPLATE/bug.md \
    .github/ISSUE_TEMPLATE/chore.md \
    .github/ISSUE_TEMPLATE/feature.md; do
    [ -f "$REPO_ROOT/$rel" ]
    [ -f "$REPO_ROOT/templates/project/$rel" ]
    cmp -s "$REPO_ROOT/$rel" "$REPO_ROOT/templates/project/$rel"
  done
}

@test "README component counts match canonical template inventory" {
  [ "$(find "$REPO_ROOT/templates/global/skills" -maxdepth 1 -type f -name '*.md' | wc -l | tr -d ' ')" -eq 5 ]
  [ "$(find "$REPO_ROOT/templates/project/.rig/processes" -maxdepth 1 -type f -name '*.md' | wc -l | tr -d ' ')" -eq 8 ]
  [ "$(find "$REPO_ROOT/templates/project/.rig/rules" -maxdepth 1 -type f | wc -l | tr -d ' ')" -eq 7 ]
  grep -Fq '| Processes (8) |' "$REPO_ROOT/README.md"
  grep -Fq '| Rules (7) |' "$REPO_ROOT/README.md"
}

@test "full project install covers every project template file or documents an explicit exception" {
  local target missing_report
  target="$TEST_ROOT/project"
  missing_report="$TEST_ROOT/missing.txt"
  mkdir -p "$target"
  git -C "$target" init -q
  printf '%s\n' '{"scripts":{}}' > "$target/package.json"

  run bash "$REPO_ROOT/install.sh" --project-only --target "$target" \
    --project-name Test --tracking repo --strategy merge \
    --project-agent both --feature-docs --subagents --contribute
  [ "$status" -eq 0 ]

  python3 - "$REPO_ROOT/templates/project" "$target" > "$missing_report" <<'PYEOF'
import os
import sys

template_root, target = sys.argv[1:]
explicit_exceptions = set()

missing = []
for root, _, files in os.walk(template_root):
    for name in files:
        rel = os.path.relpath(os.path.join(root, name), template_root)
        if rel in explicit_exceptions:
            continue
        if not os.path.exists(os.path.join(target, rel)):
            missing.append(rel)

for rel in sorted(missing):
    print(rel)
raise SystemExit(1 if missing else 0)
PYEOF

  [ ! -s "$missing_report" ]
}
