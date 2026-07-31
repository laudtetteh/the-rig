#!/usr/bin/env bats
#
# Focused contract tests for the /wrap DECISIONS.md write path.
# Run with: bats tests/test_decisions_write_path.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
WRAP_COMMAND="$REPO_ROOT/templates/project/.claude/commands/wrap.md"

@test "wrap: collects and reports DECISIONS.md additions" {
  grep -q 'DECISIONS.md additions' "$WRAP_COMMAND"
  grep -q '\*\*DECISIONS.md:\*\* \[N new entries: short-title-1, short-title-2 | no new entries\]' "$WRAP_COMMAND"
  grep -q 'Add inferred DECISIONS.md entries (if any)' "$WRAP_COMMAND"
}

@test "wrap: limits logging to significant adopted decisions" {
  grep -q 'significant adopted' "$WRAP_COMMAND"
  grep -q 'closes off meaningful alternatives' "$WRAP_COMMAND"
  grep -q 'choice not actually' "$WRAP_COMMAND"
}

@test "wrap: de-duplicates semantically equivalent decisions" {
  grep -q 'Treat semantically equivalent entries as duplicates' "$WRAP_COMMAND"
  grep -q 'do not add another entry' "$WRAP_COMMAND"
}

@test "wrap: uses the complete DECISIONS.md entry format" {
  grep -q '\*\*Context\*\*: Why this decision needed to be made' "$WRAP_COMMAND"
  grep -q '\*\*Decision\*\*: What was chosen' "$WRAP_COMMAND"
  grep -q '\*\*Rejected\*\*: What was considered and not chosen' "$WRAP_COMMAND"
  grep -q '\*\*Rationale\*\*: Why' "$WRAP_COMMAND"
  grep -q '\*\*Consequences\*\*: What this decision implies going forward' "$WRAP_COMMAND"
  grep -q 'remove the `No decisions logged yet` placeholder' "$WRAP_COMMAND"
}

@test "wrap: decision logging remains automatic and non-blocking" {
  grep -q 'If no significant adopted decision occurred, report `no new entries` and make no change' "$WRAP_COMMAND"
  grep -q 'Do not ask for confirmation' "$WRAP_COMMAND"
  grep -q 'do not turn decision logging into a required gate' "$WRAP_COMMAND"
}
