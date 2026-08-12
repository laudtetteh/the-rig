#!/usr/bin/env bats
#
# tests/test_command_lint.bats — Structural linting for command markdown files
#
# Run with: bats tests/test_command_lint.bats
#
# Enforces four structural invariants across every .md file in
# templates/project/.claude/commands/:
#   1. H1 first line matches "# Command: /slug"
#   2. Slug in H1 matches the filename (debug.md → /debug)
#   3. At least one H2 section exists
#   4. No H2 header is missing a space after "##"

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
COMMAND_DIR="$REPO_ROOT/templates/project/.claude/commands"

# ── Helpers ───────────────────────────────────────────────────────────────────

_fail_with_list() {
  local label="$1"
  shift
  printf '%s:\n' "$label"
  printf '  %s\n' "$@"
  return 1
}

# ── Tests ─────────────────────────────────────────────────────────────────────

@test "command files: H1 first line matches '# Command: /slug' format" {
  local failures=()
  for f in "$COMMAND_DIR"/*.md; do
    local first
    first="$(head -1 "$f")"
    if ! echo "$first" | grep -qE '^# Command: /[a-z-]+$'; then
      failures+=("$(basename "$f"): got '${first}'")
    fi
  done
  [ "${#failures[@]}" -eq 0 ] || _fail_with_list "Malformed H1" "${failures[@]}"
}

@test "command files: slug in H1 matches filename" {
  local failures=()
  for f in "$COMMAND_DIR"/*.md; do
    local name first slug
    name="$(basename "$f" .md)"
    first="$(head -1 "$f")"
    slug="${first#\# Command: /}"
    if [[ "$slug" != "$name" ]]; then
      failures+=("$(basename "$f"): expected /${name}, H1 says /${slug}")
    fi
  done
  [ "${#failures[@]}" -eq 0 ] || _fail_with_list "Slug mismatch" "${failures[@]}"
}

@test "command files: all files have at least one H2 section" {
  local failures=()
  for f in "$COMMAND_DIR"/*.md; do
    if ! grep -q "^## " "$f"; then
      failures+=("$(basename "$f")")
    fi
  done
  [ "${#failures[@]}" -eq 0 ] || _fail_with_list "Missing H2 section" "${failures[@]}"
}

@test "command files: no H2 header missing space after '##'" {
  local failures=()
  for f in "$COMMAND_DIR"/*.md; do
    # Matches ## at line start followed by a char that is not # or space.
    # This catches "##Foo" but not "### Foo" (H3) or "## Foo" (valid H2).
    if grep -qE '^##[^# ]' "$f"; then
      failures+=("$(basename "$f")")
    fi
  done
  [ "${#failures[@]}" -eq 0 ] || _fail_with_list "H2 missing space after ##" "${failures[@]}"
}

# ── wrap / post-merge behavior spec ───────────────────────────────────────────

@test "wrap.md: contains Wrap report step section" {
  grep -q "## Wrap report step" "$COMMAND_DIR/wrap.md"
}

@test "wrap.md: Wrap report step defines collection phase and report format" {
  grep -q "Collection phase" "$COMMAND_DIR/wrap.md"
  grep -q "This session" "$COMMAND_DIR/wrap.md"
  grep -q "Wrap report —" "$COMMAND_DIR/wrap.md"
  grep -Fq 'Codex `$wrap` skill' "$COMMAND_DIR/wrap.md"
  grep -Fq 'Session: unresolved — no final session-file write performed' "$COMMAND_DIR/wrap.md"
}

@test "wrap.md: PROGRESS.md trim executes automatically — no confirmation gate" {
  # Must NOT contain the old 'Trim now?' prompt
  if grep -q "Trim now?" "$COMMAND_DIR/wrap.md"; then return 1; fi
}

@test "wrap.md: ERRORS.md logging infers from context — no 'ask' prompt" {
  # Must NOT ask the user whether anything unexpected happened
  if grep -q "Did anything unexpected" "$COMMAND_DIR/wrap.md"; then return 1; fi
}

@test "wrap.md: trim steps reference Wrap report — not standalone confirmations" {
  grep -q "note in the Wrap report" "$COMMAND_DIR/wrap.md"
}

@test "post-merge.md: contains Post-merge report step section" {
  grep -q "## Post-merge report step" "$COMMAND_DIR/post-merge.md"
}

@test "post-merge.md: Post-merge report step defines collection and report format" {
  grep -q "Collection phase" "$COMMAND_DIR/post-merge.md"
  grep -q "Post-merge report —" "$COMMAND_DIR/post-merge.md"
  grep -Fq 'Codex `$post-merge` skill' "$COMMAND_DIR/post-merge.md"
  grep -Fq 'Post-merge report — skipped' "$COMMAND_DIR/post-merge.md"
}

@test "post-merge.md: executes POST_MERGE_WORKFLOW automatically after report" {
  grep -q "execute POST_MERGE_WORKFLOW steps" "$COMMAND_DIR/post-merge.md"
}

@test "rig-upgrade.md: --version detects stale stable installer source" {
  grep -Fq 'Stable installer source is at `$GLOBAL_VERSION` but latest release is `$GITHUB_VERSION`' "$COMMAND_DIR/rig-upgrade.md"
  grep -Fq 'git -C ~/tools/the-rig pull --ff-only origin main' "$COMMAND_DIR/rig-upgrade.md"
  grep -Fq 're-run `/rig-upgrade --version`' "$COMMAND_DIR/rig-upgrade.md"
}

@test "wrap and post-merge stop on external Rig memory permission failure" {
  for command in wrap post-merge; do
    grep -Fq 'Unable to write Rig memory lock' "$COMMAND_DIR/$command.md"
    grep -Fq 'Operation not permitted' "$COMMAND_DIR/$command.md"
    grep -Fq 'request scoped write approval for $RIG_DIR' "$COMMAND_DIR/$command.md"
    grep -Fq 'No further memory writes were attempted.' "$COMMAND_DIR/$command.md"
  done
}

@test "task and run use the fixed PROGRESS top-insertion anchor" {
  for command in task run; do
    grep -q 'immediately after the `## Format`' "$COMMAND_DIR/$command.md"
    grep -q "Never anchor the insertion to the" "$COMMAND_DIR/$command.md"
    grep -q "own prior PROGRESS edit from the same" "$COMMAND_DIR/$command.md"
  done
}

@test "rig-help baseline deny patterns match shipped settings.json" {
  grep -Fq '`rm -rf *`, `git push --force*`, `git push -f*`' "$COMMAND_DIR/rig-help.md"

  run grep -Eq 'DROP TABLE|TRUNCATE' "$COMMAND_DIR/rig-help.md"
  [ "$status" -ne 0 ]
}

@test "docs index convention is wired into feature doc commands" {
  grep -Fq 'docs/INDEX.md' "$COMMAND_DIR/doc-list.md"
  grep -Fq 'architecture/' "$COMMAND_DIR/doc-list.md"
  grep -Fq 'docs/INDEX.md' "$COMMAND_DIR/doc-feature.md"
  grep -Fq 'docs/INDEX.md' "$COMMAND_DIR/refresh-feature-doc.md"
  grep -Fq 'docs/INDEX.md' "$COMMAND_DIR/rig-help.md"
  run grep -R '\$RIG_DIR/docs' "$COMMAND_DIR"
  [ "$status" -ne 0 ]
}

@test "handoff-checklist preserves explicit two-gate consent" {
  grep -Fq 'explicitly agreed' "$COMMAND_DIR/handoff-checklist.md"
  grep -Fq 'Silence, hesitation, or an ambiguous answer is not consent' "$COMMAND_DIR/handoff-checklist.md"
  grep -Fq 'Do not run `/post-merge`, `/wrap`, or any checklist step' "$COMMAND_DIR/handoff-checklist.md"
}

@test "rig-upgrade.md: verifies Codex mirrors after command updates" {
  grep -Fq '.agents/skills/wrap/SKILL.md' "$COMMAND_DIR/rig-upgrade.md"
  grep -Fq 'installer/generate-codex-skills.py' "$COMMAND_DIR/rig-upgrade.md"
  grep -Fq -- '--output "$REPO/.agents/skills"' "$COMMAND_DIR/rig-upgrade.md"
  grep -Fq -- '--base-branch "$BASE_BRANCH"' "$COMMAND_DIR/rig-upgrade.md"
  grep -Fq -- '--skills-source "$INSTALLER_SRC/templates/project/.claude/skills"' "$COMMAND_DIR/rig-upgrade.md"
  grep -Fq '"${CODEX_COMMAND_SOURCES[@]}"' "$COMMAND_DIR/rig-upgrade.md"
  grep -Fq 'Do not patch generated `.agents/skills/*/references/command.md` files by hand' "$COMMAND_DIR/rig-upgrade.md"
  grep -Fq 'PROJECT_TARGETS_FILE="$RIG_DIR/install-targets.json"' "$COMMAND_DIR/rig-upgrade.md"
  grep -Fq 'CODEX_INFRA_STATUS' "$COMMAND_DIR/rig-upgrade.md"
  grep -Fq 'bin/rig session retrofit --agent codex --from-env --source resume --json' "$COMMAND_DIR/rig-upgrade.md"
}

# ── PR description freshness ───────────────────────────────────────────────────

@test "wrap.md: contains PR description freshness step" {
  grep -q "## PR description freshness step" "$COMMAND_DIR/wrap.md"
}

@test "wrap.md: PR freshness step skips housekeeping commit types" {
  grep -q "chore(memory)" "$COMMAND_DIR/wrap.md"
}

@test "wrap.md: PR freshness step skips silently when no open PR" {
  grep -q "skip silently" "$COMMAND_DIR/wrap.md"
}

@test "ship.md: Step 9 compares commits against existing PR description before prompting" {
  grep -q "compare the branch commits against the existing PR description" "$COMMAND_DIR/ship.md"
}

@test "ship.md: Step 9 skips housekeeping commit types in freshness check" {
  grep -qE "chore\(memory\)" "$COMMAND_DIR/ship.md"
}

@test "code-review.md: requires dependency impact analysis before findings" {
  grep -Fq "## Step 4.5 — Dependency impact analysis" "$COMMAND_DIR/code-review.md"
  grep -Fq "Canonical sources and generated artifacts" "$COMMAND_DIR/code-review.md"
  grep -Fq "Upstream/downstream install and upgrade paths" "$COMMAND_DIR/code-review.md"
  grep -Fq "Dependency impact gaps" "$COMMAND_DIR/code-review.md"
}

@test "ship.md: dependency impact gate is blocking and feeds PR evidence" {
  grep -Fq "## Step 4.6 — Dependency impact gate" "$COMMAND_DIR/ship.md"
  grep -Fq "This is a blocking gate" "$COMMAND_DIR/ship.md"
  grep -Fq "Generated artifacts: PASS / N/A / HOLD" "$COMMAND_DIR/ship.md"
  grep -Fq "Retain this matrix and reuse it in the pull request **Dependency impact** section" "$COMMAND_DIR/ship.md"
  grep -Fq "## Dependency impact" "$COMMAND_DIR/ship.md"
}

@test "sprint workflow codifies Dependency Surface Audit planning gate" {
  local process="$REPO_ROOT/templates/project/.rig/processes/SPRINT_WORKFLOW.md"
  grep -Fq "Dependency Surface Audit (DSA)" "$process"
  grep -Fq "Upstream inputs" "$process"
  grep -Fq "Downstream dependents" "$process"
  grep -Fq "Generated artifacts" "$process"
  grep -Fq "Upgrade/install path" "$process"
  grep -Fq "Cross-agent parity" "$process"
  grep -Fq "Persistent state" "$process"
  grep -Fq "Validation hooks" "$process"
  grep -Fq "Dependency Surface Audit required by" "$COMMAND_DIR/sprint.md"
}

@test "delegated validation protocol forbids duplicate detached full-suite runs" {
  local process="$REPO_ROOT/templates/project/.rig/processes/SPRINT_WORKFLOW.md"
  grep -Fq "foreground tool calls" "$process"
  grep -Fq "exact command and" "$process"
  grep -Fq "tool/session identifier" "$process"
  grep -Fq "must not start duplicate validation" "$process"
  grep -Fq 'full local `bats tests/` suite requires' "$process"
  grep -Fq "must not run a local full \`bats tests/\` suite" "$COMMAND_DIR/handoff-checklist.md"
}

@test "ship merge guidance verifies GitHub PR state after non-zero merge" {
  grep -Fq "## Step 10 — Merge verification and branch cleanup" "$COMMAND_DIR/ship.md"
  grep -Fq 'gh pr view "$PR_NUMBER" --json state,mergedAt' "$COMMAND_DIR/ship.md"
  grep -Fq "linked worktree" "$COMMAND_DIR/ship.md"
  grep -Fq "local cleanup failure" "$COMMAND_DIR/ship.md"
  grep -Fq "Do not run" "$COMMAND_DIR/ship.md"
}

@test "code-review and ship discover PR validation candidates safely" {
  for command in code-review ship; do
    grep -Fq "Local verification" "$COMMAND_DIR/$command.md"
    grep -Fq "Validation" "$COMMAND_DIR/$command.md"
    grep -Fq "Test plan" "$COMMAND_DIR/$command.md"
    grep -Fq "validation candidates" "$COMMAND_DIR/$command.md"
    grep -Fq "PR-body" "$COMMAND_DIR/$command.md"
    grep -Fq "YARN_NO_PROXY" "$COMMAND_DIR/$command.md"
    grep -Fq "env -u YARN_NO_PROXY" "$COMMAND_DIR/$command.md"
    grep -Fq "at most once" "$COMMAND_DIR/$command.md"
  done
}

@test "PR template captures dependency impact evidence" {
  local template="$REPO_ROOT/templates/project/.github/PULL_REQUEST_TEMPLATE.md"
  grep -Fq "## Dependency impact" "$template"
  grep -Fq "Generated artifacts:" "$template"
  grep -Fq "Downstream install/upgrade:" "$template"
  grep -Fq "Cross-agent/runtime parity:" "$template"
  grep -Fq "Runtime/config dependencies:" "$template"
}

@test "rig-help advertises dependency impact review gates" {
  grep -Fq "dependency impact" "$COMMAND_DIR/rig-help.md"
  grep -Fq "coverage, dependency impact, style" "$COMMAND_DIR/rig-help.md"
}

@test "wrap.md: transcript pruning uses agent-aware documented locations" {
  grep -q "transcript-retention-days" "$COMMAND_DIR/wrap.md"
  grep -Fq '$HOME/.claude/projects' "$COMMAND_DIR/wrap.md"
  grep -Fq '${CODEX_HOME:-$HOME/.codex}/sessions' "$COMMAND_DIR/wrap.md"
  grep -q "transcript-retention-include-archived" "$COMMAND_DIR/wrap.md"
}

@test "wrap.md: contains Permission scan opt-in section" {
  grep -q "## Permission scan (opt-in)" "$COMMAND_DIR/wrap.md"
}

@test "wrap.md: permission scan checks .fewer-prompts-enabled sentinel" {
  grep -q ".fewer-prompts-enabled" "$COMMAND_DIR/wrap.md"
}

@test "wrap.md: permission scan reports Auto-approved format" {
  grep -q "Auto-approved" "$COMMAND_DIR/wrap.md"
}

@test "wrap.md: permission scan contains PYEOF heredoc delimiter" {
  grep -q "<<'PYEOF'" "$COMMAND_DIR/wrap.md"
}
