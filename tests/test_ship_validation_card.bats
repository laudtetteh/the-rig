#!/usr/bin/env bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SHIP_COMMAND="$REPO_ROOT/templates/project/.claude/commands/ship.md"
SHIP_WORKFLOW="$REPO_ROOT/templates/project/.rig/processes/SHIP_WORKFLOW.md"

@test "ship command derives bounded live steps with complete card fields" {
  grep -q 'derive \*\*1–5 exact live validation steps\*\*' "$SHIP_COMMAND"
  grep -q '\*\*Setup\*\*' "$SHIP_COMMAND"
  grep -q '\*\*Command/action\*\*' "$SHIP_COMMAND"
  grep -q '\*\*Expected\*\*' "$SHIP_COMMAND"
  grep -q '\*\*Cleanup\*\*' "$SHIP_COMMAND"
  grep -q 'Agent result: <PASS / SKIPPED' "$SHIP_COMMAND"
}

@test "ship command separates static checks from live validation" {
  grep -q 'live validation' "$SHIP_COMMAND"
  grep -q 'static analysis in the Step 3 results' "$SHIP_COMMAND"
  grep -q 'include lint, unit, or static checks in the card' "$SHIP_COMMAND"
}

@test "ship command runs safe checks and reports skips and unsafe checks" {
  grep -q 'Run every safe, local step yourself' "$SHIP_COMMAND"
  grep -q 'record the reason and residual risk' "$SHIP_COMMAND"
  grep -q 'explicit approval before running it' "$SHIP_COMMAND"
}

@test "ship command gives docs-only changes a minimal validation card" {
  grep -q 'docs-only diff still needs one minimal' "$SHIP_COMMAND"
}

@test "ship command makes manual reruns optional without false attestation" {
  grep -q 'Optional manual validation' "$SHIP_COMMAND"
  grep -q 'it does not claim you personally' "$SHIP_COMMAND"
  ! grep -q 'user confirmed local testing' "$SHIP_COMMAND"
}

@test "ship command reuses evidence in PR Test plan" {
  grep -q 'Reuse them in the pull' "$SHIP_COMMAND"
  grep -q 'request \*\*Test plan\*\*' "$SHIP_COMMAND"
}

@test "canonical workflow carries the validation-card contract" {
  grep -q '## Step 2.4 — Live validation plan and evidence' "$SHIP_WORKFLOW"
  grep -q '## Step 2.5 — Optional manual validation card' "$SHIP_WORKFLOW"
  grep -q 'Approval does not claim you' "$SHIP_WORKFLOW"
  grep -q 'PR \*\*Test plan\*\*' "$SHIP_WORKFLOW"
}
