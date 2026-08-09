#!/usr/bin/env bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

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

@test "project template ships canonical docs index" {
  [ -f "$REPO_ROOT/templates/project/docs/INDEX.md" ]
  grep -Fq '[`features/README.md`](features/README.md)' "$REPO_ROOT/templates/project/docs/INDEX.md"
}

@test "README links canonical docs index instead of duplicating doc list" {
  grep -Fq '[docs/INDEX.md](docs/INDEX.md)' "$REPO_ROOT/README.md"
  run grep -F '[How it works](docs/how-it-works.md)' "$REPO_ROOT/README.md"
  [ "$status" -ne 0 ]
}
