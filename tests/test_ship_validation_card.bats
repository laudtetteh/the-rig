#!/usr/bin/env bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SHIP_COMMAND="$REPO_ROOT/templates/project/.claude/commands/rig-ship.md"
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

@test "ship command blocks legacy and Git-hook progress stubs" {
  grep -Fq 'Auto-logged by (post-tool|post-commit) hook' "$SHIP_COMMAND"
}

@test "ship command makes manual reruns optional without false attestation" {
  grep -q 'Optional manual validation' "$SHIP_COMMAND"
  grep -q 'it does not claim you personally' "$SHIP_COMMAND"
  if grep -q 'user confirmed local testing' "$SHIP_COMMAND"; then return 1; fi
}

@test "ship command reuses evidence in PR Test plan" {
  grep -q 'Reuse them in the pull' "$SHIP_COMMAND"
  grep -q 'request \*\*Test plan\*\*' "$SHIP_COMMAND"
}

@test "canonical workflow carries the validation-card contract" {
  grep -q '## Step 2.4 — Live validation plan and evidence' "$SHIP_WORKFLOW"
  grep -q '## Step 2.5 — Commit gate: evidence block, validation card' "$SHIP_WORKFLOW"
  grep -q 'Approval does not claim you' "$SHIP_WORKFLOW"
  grep -q 'PR \*\*Test plan\*\*' "$SHIP_WORKFLOW"
}

# ── Gate evidence blocks (#716) ──────────────────────────────────────────────

GLOBAL_CLAUDE="$REPO_ROOT/templates/global/CLAUDE.md"

# Print the fenced block that follows a "### <heading>" line.
gate_block() {
  awk -v h="### $2" '
    $0 == h { in_section = 1; next }
    in_section && /^### / { exit }
    in_section && /^```text$/ { in_block = 1; next }
    in_block && /^```$/ { exit }
    in_block { print }
  ' "$1"
}

assert_commit_block() {
  local block
  block="$(gate_block "$1" "Commit gate evidence block")"
  [[ -n "$block" ]] || return 1
  grep -q '^Commit gate — <branch> · staged on <HEAD short SHA>' <<<"$block" || return 1
  grep -q '^• Diff: ' <<<"$block"
  grep -q '^• Checks: ' <<<"$block"
  grep -q '^• Review: .*pre-commit.*post-commit @ <SHA>' <<<"$block"
  grep -q '^• Live validation: ' <<<"$block"
  grep -q '^• Open risk: ' <<<"$block"
  grep -q '^• Approving covers: ' <<<"$block"
}

assert_merge_block() {
  local block
  block="$(gate_block "$1" "Merge gate evidence block")"
  [[ -n "$block" ]] || return 1
  grep -q '^Merge gate — PR #<N> @ <head SHA>' <<<"$block"
  grep -q '^• CI: .*at this exact head' <<<"$block"
  grep -q '^• Review: .*post-commit on PR @ <SHA>.*pre-commit' <<<"$block"
  grep -q '^• Metadata/body review: ' <<<"$block"
  grep -q '^• Unresolved: ' <<<"$block"
  grep -q '^• Approving covers: merge PR #<N>' <<<"$block"
}

@test "ship command requires the commit gate evidence block with every bullet" {
  assert_commit_block "$SHIP_COMMAND"
}

@test "ship workflow requires the commit gate evidence block with every bullet" {
  assert_commit_block "$SHIP_WORKFLOW"
}

@test "ship command requires the merge gate evidence block with every bullet" {
  assert_merge_block "$SHIP_COMMAND"
}

@test "ship workflow requires the merge gate evidence block with every bullet" {
  assert_merge_block "$SHIP_WORKFLOW"
}

@test "ship command and workflow carry identical gate evidence blocks" {
  local section command_block workflow_block
  for section in "Commit gate evidence block" "Merge gate evidence block"; do
    command_block="$(gate_block "$SHIP_COMMAND" "$section")"
    workflow_block="$(gate_block "$SHIP_WORKFLOW" "$section")"
    [[ -n "$command_block" ]] || return 1
    [[ "$command_block" == "$workflow_block" ]] || return 1
  done
}

@test "gate evidence flags a review made stale by a moved head" {
  grep -q 'changed after the review, say so and re-run the review' "$SHIP_COMMAND"
  grep -q 'changed after the review, say so and re-run the review' "$SHIP_WORKFLOW"
  grep -q 'a stale review never counts as current' "$SHIP_COMMAND"
  grep -q 'a stale review never counts as current' "$SHIP_WORKFLOW"
}

@test "optional validation card still excludes required checks" {
  local card
  card="$(gate_block "$SHIP_COMMAND" "Optional manual validation card")"
  [[ -n "$card" ]] || return 1
  if grep -Eiq 'lint|unit|static' <<<"$card"; then return 1; fi
  card="$(gate_block "$SHIP_WORKFLOW" "Optional manual validation card")"
  [[ -n "$card" ]] || return 1
  if grep -Eiq 'lint|unit|static' <<<"$card"; then return 1; fi
}

@test "commit approval wording no longer claims the user reviewed the diff" {
  if grep -q 'you confirm that you reviewed the diff' "$SHIP_COMMAND"; then return 1; fi
  if grep -q 'confirm you reviewed the diff' "$SHIP_WORKFLOW"; then return 1; fi
  if grep -q 'The user reviewed the diff' "$SHIP_COMMAND"; then return 1; fi
  grep -q "evidence block lists under 'Approving covers'" "$SHIP_COMMAND"
  grep -q "evidence block lists under 'Approving covers'" "$SHIP_WORKFLOW"
}

@test "global hard rule 11 requires the evidence block before commit and merge" {
  local rule
  rule="$(awk '/^11\. \*\*Never run `git commit`/{f=1} f&&/^12\. /{exit} f' "$GLOBAL_CLAUDE")"
  [[ -n "$rule" ]] || return 1
  grep -q 'evidence block' <<<"$rule"
  grep -q 'pre-commit or' <<<"$rule"
  grep -q 'post-commit with the commit reviewed' <<<"$rule"
  grep -q 'what the approval covers' <<<"$rule"
  grep -q 'before' <<<"$rule"
  grep -q 'asking to merge' <<<"$rule"
}

# Print the bullet list that follows a "### <heading>" fenced block.
gate_notes() {
  awk -v h="### $2" '
    $0 == h { in_section = 1; next }
    in_section && /^### / { exit }
    in_section && /^## / { exit }
    in_section && /^- \*\*/ { in_notes = 1 }
    in_notes { print }
  ' "$1"
}

@test "commit gate diff count includes untracked files (#716 review)" {
  local file notes
  for file in "$SHIP_COMMAND" "$SHIP_WORKFLOW"; do
    notes="$(gate_notes "$file" "Commit gate evidence block")"
    [[ -n "$notes" ]] || return 1
    grep -q 'git diff HEAD --shortstat' <<<"$notes" || return 1
    grep -q 'git ls-files --others --exclude-standard' <<<"$notes" || return 1
    if grep -q 'git diff --shortstat` before staging' <<<"$notes"; then return 1; fi
  done
}

@test "commit gate names the parent commit as staged on, not @ (#716 review)" {
  local file notes
  for file in "$SHIP_COMMAND" "$SHIP_WORKFLOW"; do
    notes="$(gate_notes "$file" "Commit gate evidence block")"
    grep -q 'is the parent commit' <<<"$notes" || return 1
    grep -q 'staged on <HEAD short SHA>' <<<"$notes" || return 1
  done
}

@test "merge gate stops for a fresh explicit approval after the block (#716 review)" {
  local file notes
  for file in "$SHIP_COMMAND" "$SHIP_WORKFLOW"; do
    notes="$(gate_notes "$file" "Merge gate evidence block")"
    grep -q 'Stop after the block' <<<"$notes" || return 1
    grep -q 'explicit go-ahead in a new user message' <<<"$notes" || return 1
    grep -q 'is not that approval' <<<"$notes" || return 1
    grep -q 'Never show the block and run' <<<"$notes" || return 1
  done
  if grep -q 'Then proceed to the merge' "$SHIP_COMMAND"; then return 1; fi
  grep -q 'stop for the user.s explicit merge approval' "$SHIP_COMMAND" || return 1
  grep -q 'stop for the user.s explicit merge approval' "$SHIP_WORKFLOW" || return 1
}

@test "commit gate step headings no longer call the step optional (#716 review)" {
  grep -q '^## Step 5 — Commit gate: evidence block' "$SHIP_COMMAND" || return 1
  grep -q '^## Step 2.5 — Commit gate: evidence block' "$SHIP_WORKFLOW" || return 1
  if grep -q '^## Step 5 — Optional' "$SHIP_COMMAND"; then return 1; fi
  if grep -q '^## Step 2.5 — Optional' "$SHIP_WORKFLOW"; then return 1; fi
}

@test "global rule 11 requires stopping after the merge gate block (#716 review)" {
  local rule
  rule="$(awk '/^11\. \*\*Never run `git commit`/{f=1} f&&/^12\. /{exit} f' "$GLOBAL_CLAUDE")"
  [[ -n "$rule" ]] || return 1
  grep -q 'untracked files' <<<"$rule" || return 1
  grep -q 'CI result at the exact PR head' <<<"$rule" || return 1
  grep -q 'new' <<<"$rule" || return 1
  grep -q 'never show the merge block and merge in the same turn' <<<"$rule" || return 1
}
