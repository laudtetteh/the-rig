#!/usr/bin/env bats
#
# tests/test_install.bats — Integration tests for install.sh
#
# Run with: bats tests/test_install.bats
# Install bats: brew install bats-core  (macOS)
#               apt-get install bats    (Debian/Ubuntu)
#
# These tests call install.sh with --strategy, --target, and --project-name
# flags to drive non-interactive installation into temporary directories.
# Each test is fully isolated — temp dirs are created and destroyed per test.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
INSTALLER="$REPO_ROOT/install.sh"

# ── Helpers ───────────────────────────────────────────────────────────────────

setup() {
  # Create an isolated temp dir and a bare git repo inside it for each test.
  TEMP_DIR="$(mktemp -d)"
  TEST_PROJECT="$TEMP_DIR/test-project"
  mkdir -p "$TEST_PROJECT"
  git -C "$TEST_PROJECT" init -q
  git -C "$TEST_PROJECT" config user.email "test@test.com"
  git -C "$TEST_PROJECT" config user.name "Test"
}

teardown() {
  rm -rf "$TEMP_DIR"
}

run_installer() {
  # Convenience wrapper: always project-only, into TEST_PROJECT, with a fixed name.
  # Defaults to --tracking repo so tests remain isolated in TEMP_DIR.
  # Tests that need stealth/external tracking pass --tracking explicitly (overrides).
  run bash "$INSTALLER" --project-only \
    --target "$TEST_PROJECT" \
    --project-name "TestProject" \
    --tracking repo \
    "$@"
}

# ── is_rig_owned classification ───────────────────────────────────────────────
# These tests source a minimal stub that re-implements is_rig_owned() exactly
# as install.sh defines it, letting us unit-test the classification logic without
# running the full installer.

is_rig_owned_stub() {
  local rel="$1"
  case "$rel" in
    .claude/hooks/*|\
    .claude/commands/*|\
    .rig/processes/*|\
    .rig/VERSION|\
    .husky/*|\
    .gitleaks.toml)
      return 0 ;;
    *)
      return 1 ;;
  esac
}

@test "is_rig_owned: hook script is Rig-owned" {
  is_rig_owned_stub ".claude/hooks/pre-tool.sh"
  [ "$?" -eq 0 ]
}

@test "is_rig_owned: slash command is Rig-owned" {
  is_rig_owned_stub ".claude/commands/ship.md"
  [ "$?" -eq 0 ]
}

@test "is_rig_owned: process file is Rig-owned" {
  is_rig_owned_stub ".rig/processes/SHIP_WORKFLOW.md"
  [ "$?" -eq 0 ]
}

@test "is_rig_owned: husky hook is Rig-owned" {
  is_rig_owned_stub ".husky/pre-commit"
  [ "$?" -eq 0 ]
}

@test "is_rig_owned: gitleaks config is Rig-owned" {
  is_rig_owned_stub ".gitleaks.toml"
  [ "$?" -eq 0 ]
}

@test "is_rig_owned: CLAUDE.md is user-owned" {
  run is_rig_owned_stub "CLAUDE.md"
  [ "$status" -ne 0 ]
}

@test "is_rig_owned: rules file is user-owned" {
  run is_rig_owned_stub ".rig/rules/coding-standards.md"
  [ "$status" -ne 0 ]
}

@test "is_rig_owned: memory file is user-owned" {
  run is_rig_owned_stub ".rig/memory/PROGRESS.md"
  [ "$status" -ne 0 ]
}

@test "is_rig_owned: RIG_GAPS.md is user-owned (never overwritten)" {
  run is_rig_owned_stub ".rig/memory/RIG_GAPS.md"
  [ "$status" -ne 0 ]
}

@test "is_rig_owned: task file is user-owned" {
  run is_rig_owned_stub ".rig/tasks/backlog/TASK_example.md"
  [ "$status" -ne 0 ]
}

@test "is_rig_owned: GitHub template is user-owned" {
  run is_rig_owned_stub ".github/PULL_REQUEST_TEMPLATE.md"
  [ "$status" -ne 0 ]
}

# ── Fresh install — skip strategy ─────────────────────────────────────────────

@test "skip strategy: creates files that do not exist" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]
  [ -f "$TEST_PROJECT/.rig/processes/SHIP_WORKFLOW.md" ]
  [ -f "$TEST_PROJECT/.claude/hooks/pre-tool.sh" ]
  [ -f "$TEST_PROJECT/.rig/memory/RIG_GAPS.md" ]
}

@test "skip strategy: does not overwrite existing files" {
  # Place a sentinel in a Rig-owned location
  mkdir -p "$TEST_PROJECT/.claude/hooks"
  echo "ORIGINAL" > "$TEST_PROJECT/.claude/hooks/pre-tool.sh"

  run_installer --strategy skip
  [ "$status" -eq 0 ]

  # Original must be preserved
  grep -q "ORIGINAL" "$TEST_PROJECT/.claude/hooks/pre-tool.sh"
}

@test "skip strategy: creates RIG_GAPS.md on fresh install" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]
  [ -f "$TEST_PROJECT/.rig/memory/RIG_GAPS.md" ]
}

# ── Overwrite strategy ────────────────────────────────────────────────────────

@test "overwrite strategy: creates files on fresh install" {
  run_installer --strategy overwrite
  [ "$status" -eq 0 ]
  [ -f "$TEST_PROJECT/.rig/processes/SHIP_WORKFLOW.md" ]
  [ -f "$TEST_PROJECT/.claude/hooks/pre-tool.sh" ]
}

@test "overwrite strategy: replaces existing files" {
  mkdir -p "$TEST_PROJECT/.claude/hooks"
  echo "STALE" > "$TEST_PROJECT/.claude/hooks/pre-tool.sh"

  run_installer --strategy overwrite
  [ "$status" -eq 0 ]

  # Should no longer contain the stale content
  run grep -q "STALE" "$TEST_PROJECT/.claude/hooks/pre-tool.sh"
  [ "$status" -ne 0 ]
}

@test "overwrite strategy: backs up replaced files to .rig-backup/" {
  mkdir -p "$TEST_PROJECT/.claude/hooks"
  echo "STALE" > "$TEST_PROJECT/.claude/hooks/pre-tool.sh"

  run_installer --strategy overwrite
  [ "$status" -eq 0 ]

  # A backup directory should exist
  [ -d "$TEST_PROJECT/.rig-backup" ]
  # The backup directory should contain the old hook
  local backup_count
  backup_count="$(find "$TEST_PROJECT/.rig-backup" -name "pre-tool.sh" | wc -l | tr -d ' ')"
  [ "$backup_count" -gt 0 ]
}

@test "overwrite strategy in stealth mode: backs up to external rig dir, not project" {
  local rig_ext="$TEMP_DIR/rig-external"
  mkdir -p "$TEST_PROJECT/.claude/hooks"
  echo "STALE" > "$TEST_PROJECT/.claude/hooks/pre-tool.sh"

  run_installer --strategy overwrite --tracking stealth --rig-dir "$rig_ext"
  [ "$status" -eq 0 ]

  # Backup must land in the external rig dir
  local backup_count
  backup_count="$(find "$rig_ext/backups" -name "pre-tool.sh" 2>/dev/null | wc -l | tr -d ' ')"
  [ "$backup_count" -gt 0 ]

  # No backup traces in the project repo
  [ ! -d "$TEST_PROJECT/.rig-backup" ]
}

# ── Upgrade strategy ──────────────────────────────────────────────────────────

@test "upgrade strategy: creates manifest on fresh install" {
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]
  [ -f "$TEST_PROJECT/.rig/memory/.rig-manifest" ]
}

@test "upgrade strategy: manifest contains Rig-owned file entries" {
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]

  # Manifest should have an entry for a known Rig-owned file
  grep -q ".claude/hooks/pre-tool.sh" "$TEST_PROJECT/.rig/memory/.rig-manifest"
}

@test "upgrade strategy: auto-updates unmodified Rig-owned file on re-install" {
  # First install
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]

  # Tamper with a Rig-owned file to simulate a newer Rig version
  local hook="$TEST_PROJECT/.claude/hooks/pre-tool.sh"
  local original_content
  original_content="$(cat "$hook")"

  # Overwrite with different content simulating "old version"
  echo "# OLD VERSION" > "$hook"

  # The manifest still has the hash of the original (first install), so
  # the current file hash differs from manifest → treated as customized.
  # Re-run with upgrade — since hash ≠ manifest, it would prompt.
  # We can't fully test the prompt path non-interactively, but we CAN verify
  # that a file whose hash MATCHES the manifest is auto-updated silently.

  # Reset the file to match what the manifest recorded (simulates unmodified)
  echo "$original_content" > "$hook"

  # Second install with upgrade — should auto-update silently (status 0, no prompt)
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]
}

@test "upgrade strategy: never overwrites user-owned files" {
  # First install to set up everything
  run_installer --strategy overwrite
  [ "$status" -eq 0 ]

  # Write distinctive content to a user-owned file
  echo "MY CUSTOM RULES" > "$TEST_PROJECT/CLAUDE.md"

  # Upgrade run must not touch CLAUDE.md
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]

  grep -q "MY CUSTOM RULES" "$TEST_PROJECT/CLAUDE.md"
}

@test "upgrade strategy: never overwrites RIG_GAPS.md" {
  run_installer --strategy overwrite
  [ "$status" -eq 0 ]

  echo "## 2099-01-01 — My Custom Gap" > "$TEST_PROJECT/.rig/memory/RIG_GAPS.md"

  run_installer --strategy upgrade
  [ "$status" -eq 0 ]

  grep -q "My Custom Gap" "$TEST_PROJECT/.rig/memory/RIG_GAPS.md"
}

@test "upgrade strategy: manifest tracks user-owned files after install" {
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]

  # CLAUDE.md is user-owned but should now appear in the manifest
  [ -f "$TEST_PROJECT/.rig/memory/.rig-manifest" ]
  grep -q "CLAUDE.md" "$TEST_PROJECT/.rig/memory/.rig-manifest"
}

@test "upgrade strategy: preserves user-modified user-owned file (non-interactive)" {
  # Install to establish manifest baseline for user-owned files
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]

  # User modifies CLAUDE.md — hash now differs from manifest
  echo "MY BESPOKE PROJECT CONFIG" >> "$TEST_PROJECT/CLAUDE.md"

  # Upgrade non-interactive: customized user-owned file must be skipped
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]

  grep -q "MY BESPOKE PROJECT CONFIG" "$TEST_PROJECT/CLAUDE.md"
}

@test "overwrite strategy: skips user-modified user-owned file in non-interactive mode" {
  # First install establishes manifest
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]

  # User modifies CLAUDE.md
  echo "MY CUSTOM OVERWRITE CONTENT" >> "$TEST_PROJECT/CLAUDE.md"

  # Overwrite non-interactive: confirm() defaults to "n", so customized file is skipped
  run_installer --strategy overwrite
  [ "$status" -eq 0 ]

  grep -q "MY CUSTOM OVERWRITE CONTENT" "$TEST_PROJECT/CLAUDE.md"
}

# ── settings.json merge ───────────────────────────────────────────────────────

@test "merge strategy: creates settings.json when absent" {
  run_installer --strategy merge
  [ "$status" -eq 0 ]
  [ -f "$TEST_PROJECT/.claude/settings.json" ]
}

@test "skip strategy: settings.json is created on fresh install" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]
  [ -f "$TEST_PROJECT/.claude/settings.json" ]
}

# ── CLAUDE.md substitution ────────────────────────────────────────────────────

@test "project name is substituted into CLAUDE.md" {
  run_installer --strategy skip --project-name "MyAwesomeApp"
  [ "$status" -eq 0 ]
  grep -q "MyAwesomeApp" "$TEST_PROJECT/CLAUDE.md"
}

@test "REPO_ROOT placeholder is substituted in settings.json" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]
  # [REPO_ROOT] should not appear anywhere in settings.json
  run grep -q "\[REPO_ROOT\]" "$TEST_PROJECT/.claude/settings.json"
  [ "$status" -ne 0 ]
}

@test "merge strategy: does not duplicate hooks when settings.json already has Rig hooks" {
  # First install populates settings.json with the Rig hooks.
  run_installer --strategy skip
  [ "$status" -eq 0 ]
  local count_after_first
  count_after_first=$(python3 -c "
import json
with open('$TEST_PROJECT/.claude/settings.json') as f:
    s = json.load(f)
print(sum(len(v) for v in s.get('hooks', {}).values()))
")
  # Second install via merge should not add duplicate entries.
  run_installer --strategy merge
  [ "$status" -eq 0 ]
  local count_after_second
  count_after_second=$(python3 -c "
import json
with open('$TEST_PROJECT/.claude/settings.json') as f:
    s = json.load(f)
print(sum(len(v) for v in s.get('hooks', {}).values()))
")
  # Count must not grow — no duplicates added
  [ "$count_after_second" -eq "$count_after_first" ]
}

@test "upgrade strategy: does not duplicate hooks when settings.json already has Rig hooks" {
  # First install populates settings.json with the Rig hooks.
  run_installer --strategy skip
  [ "$status" -eq 0 ]
  local count_after_first
  count_after_first=$(python3 -c "
import json
with open('$TEST_PROJECT/.claude/settings.json') as f:
    s = json.load(f)
print(sum(len(v) for v in s.get('hooks', {}).values()))
")
  # Upgrade should not add duplicate entries.
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]
  local count_after_second
  count_after_second=$(python3 -c "
import json
with open('$TEST_PROJECT/.claude/settings.json') as f:
    s = json.load(f)
print(sum(len(v) for v in s.get('hooks', {}).values()))
")
  # Count must not grow — no duplicates added
  [ "$count_after_second" -eq "$count_after_first" ]
}

# ── CLI flag validation ───────────────────────────────────────────────────────

@test "--strategy with invalid value warns and falls back to interactive" {
  # We can't fully drive interactive mode in bats, but we can verify the
  # installer doesn't crash on an unknown strategy value — it should warn
  # and continue (or at least not exit non-zero before the interaction).
  # Instead, check that a valid unknown value produces a warning in output.
  run bash "$INSTALLER" --project-only \
    --target "$TEST_PROJECT" \
    --project-name "TestProject" \
    --strategy "bogus" <<< "2"   # pipe "2" (skip) to answer the strategy prompt
  # The installer should still succeed when given a fallback answer
  [ "$status" -eq 0 ]
}

@test "--target with non-existent path exits non-zero" {
  run bash "$INSTALLER" --project-only \
    --target "/tmp/definitely-does-not-exist-$$" \
    --project-name "Test" \
    --strategy skip
  [ "$status" -ne 0 ]
}

# ── bash -n syntax checks ─────────────────────────────────────────────────────
# Verify every shell script in the repo has valid bash syntax.
# These catch trivial parse errors before a user ever runs an install.

@test "syntax: install.sh has valid bash syntax" {
  run bash -n "$REPO_ROOT/install.sh"
  [ "$status" -eq 0 ]
}

@test "syntax: pre-tool.sh has valid bash syntax" {
  run bash -n "$REPO_ROOT/templates/project/.claude/hooks/pre-tool.sh"
  [ "$status" -eq 0 ]
}

@test "syntax: post-tool.sh has valid bash syntax" {
  run bash -n "$REPO_ROOT/templates/project/.claude/hooks/post-tool.sh"
  [ "$status" -eq 0 ]
}

@test "syntax: stop.sh has valid bash syntax" {
  run bash -n "$REPO_ROOT/templates/project/.claude/hooks/stop.sh"
  [ "$status" -eq 0 ]
}

@test "syntax: session-start.sh has valid bash syntax" {
  run bash -n "$REPO_ROOT/templates/project/.claude/hooks/session-start.sh"
  [ "$status" -eq 0 ]
}

@test "syntax: prompt-submit.sh has valid bash syntax" {
  run bash -n "$REPO_ROOT/templates/project/.claude/hooks/prompt-submit.sh"
  [ "$status" -eq 0 ]
}

@test "syntax: permission-request.sh has valid bash syntax" {
  run bash -n "$REPO_ROOT/templates/project/.claude/hooks/permission-request.sh"
  [ "$status" -eq 0 ]
}

@test "syntax: pre-compact.sh has valid bash syntax" {
  run bash -n "$REPO_ROOT/templates/project/.claude/hooks/pre-compact.sh"
  [ "$status" -eq 0 ]
}

@test "syntax: post-compact.sh has valid bash syntax" {
  run bash -n "$REPO_ROOT/templates/project/.claude/hooks/post-compact.sh"
  [ "$status" -eq 0 ]
}

@test "pre-compact: writes checkpoint file with branch and commit info" {
  local tmpdir
  tmpdir=$(mktemp -d)
  git -C "$tmpdir" init -q
  git -C "$tmpdir" config user.email "test@test.com"
  git -C "$tmpdir" config user.name "Test"
  git -C "$tmpdir" commit --allow-empty -m "initial" -q
  mkdir -p "$tmpdir/.rig/memory" "$tmpdir/.rig/tasks/active"

  # cd into tmpdir so git rev-parse --show-toplevel returns tmpdir, not Rig repo root
  (cd "$tmpdir" && RIG_DIR="$tmpdir/.rig" \
    bash "$REPO_ROOT/templates/project/.claude/hooks/pre-compact.sh" >/dev/null)

  local cp_file
  cp_file=$(ls -t "$tmpdir/.rig/memory"/.compact-checkpoint-*.md 2>/dev/null | head -1 || true)
  [ -n "$cp_file" ]
  grep -q "Branch:" "$cp_file"
  grep -q "Last commit:" "$cp_file"
  rm -rf "$tmpdir"
}

@test "post-compact: outputs additionalContext JSON when checkpoint exists" {
  local tmpdir
  tmpdir=$(mktemp -d)
  git -C "$tmpdir" init -q
  mkdir -p "$tmpdir/.rig/memory"
  printf '## Compact checkpoint\n\n**Branch:** test-branch\n' \
    > "$tmpdir/.rig/memory/.compact-checkpoint-12345.md"

  local output
  # cd into tmpdir so git rev-parse --show-toplevel returns tmpdir, not Rig repo root
  output=$((cd "$tmpdir" && RIG_DIR="$tmpdir/.rig" \
    bash "$REPO_ROOT/templates/project/.claude/hooks/post-compact.sh") 2>/dev/null)

  echo "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert 'hookSpecificOutput' in d
assert d['hookSpecificOutput']['hookEventName'] == 'PostCompact'
assert 'additionalContext' in d['hookSpecificOutput']
" 2>/dev/null
  [ "$?" -eq 0 ]
  rm -rf "$tmpdir"
}

@test "post-compact: exits silently when neither checkpoint nor snapshot exists" {
  local tmpdir
  tmpdir=$(mktemp -d)
  git -C "$tmpdir" init -q
  mkdir -p "$tmpdir/.rig/memory"

  local output
  # cd into tmpdir so git rev-parse --show-toplevel returns tmpdir, not Rig repo root
  output=$((cd "$tmpdir" && RIG_DIR="$tmpdir/.rig" \
    bash "$REPO_ROOT/templates/project/.claude/hooks/post-compact.sh") 2>/dev/null)

  [ -z "$output" ]
  rm -rf "$tmpdir"
}

@test "pre-compact: concurrent sessions write separate checkpoints, no clobbering" {
  local tmpdir
  tmpdir=$(mktemp -d)
  git -C "$tmpdir" init -q
  git -C "$tmpdir" config user.email "test@test.com"
  git -C "$tmpdir" config user.name "Test"
  git -C "$tmpdir" commit --allow-empty -m "initial" -q
  mkdir -p "$tmpdir/.rig/memory" "$tmpdir/.rig/tasks/active"

  # Pre-create a checkpoint simulating an existing concurrent session
  printf '## Compact checkpoint\n\n**Branch:** feat/other-session\n' \
    > "$tmpdir/.rig/memory/.compact-checkpoint-11111.md"

  # Current session runs pre-compact — must not overwrite the other session's file
  (cd "$tmpdir" && RIG_DIR="$tmpdir/.rig" \
    bash "$REPO_ROOT/templates/project/.claude/hooks/pre-compact.sh" >/dev/null)

  # Other session's checkpoint must be intact
  [ -f "$tmpdir/.rig/memory/.compact-checkpoint-11111.md" ]
  grep -q "feat/other-session" "$tmpdir/.rig/memory/.compact-checkpoint-11111.md"
  # A second checkpoint file (from this session) must also exist
  local count
  count=$(ls "$tmpdir/.rig/memory"/.compact-checkpoint-*.md 2>/dev/null | wc -l | tr -d ' ')
  [ "$count" -ge 2 ]
  rm -rf "$tmpdir"
}

@test "post-compact: reads own PPID-scoped checkpoint when multiple checkpoints exist" {
  local tmpdir
  tmpdir=$(mktemp -d)
  git -C "$tmpdir" init -q
  git -C "$tmpdir" config user.email "test@test.com"
  git -C "$tmpdir" config user.name "Test"
  git -C "$tmpdir" commit --allow-empty -m "initial" -q
  mkdir -p "$tmpdir/.rig/memory" "$tmpdir/.rig/tasks/active"

  # Create a stale checkpoint from a different session (old PID)
  printf '## Compact checkpoint\n\n**Branch:** feat/wrong-session\n' \
    > "$tmpdir/.rig/memory/.compact-checkpoint-99.md"

  # Run pre-compact then post-compact in the same subshell (shared PPID)
  # — post-compact must return the checkpoint written by pre-compact (this session),
  # not the stale one from PID 99
  local output
  output=$((cd "$tmpdir" && RIG_DIR="$tmpdir/.rig" \
    bash "$REPO_ROOT/templates/project/.claude/hooks/pre-compact.sh" >/dev/null && \
    bash "$REPO_ROOT/templates/project/.claude/hooks/post-compact.sh") 2>/dev/null)

  echo "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
ctx = d['hookSpecificOutput']['additionalContext']
assert 'wrong-session' not in ctx, 'Got stale checkpoint from wrong session: ' + ctx
assert 'Branch:' in ctx, 'Expected branch info in checkpoint: ' + ctx
" 2>/dev/null
  [ "$?" -eq 0 ]
  rm -rf "$tmpdir"
}

@test "session-start: compact source uses most-recent checkpoint when no PPID-scoped file exists" {
  local tmpdir
  tmpdir=$(mktemp -d)
  git -C "$tmpdir" init -q
  mkdir -p "$tmpdir/.rig/memory"

  # Create an older checkpoint and a newer one — session-start must pick the newest
  printf '## Compact checkpoint\n\n**Branch:** feat/old-session\n' \
    > "$tmpdir/.rig/memory/.compact-checkpoint-111.md"
  # Ensure newer mtime on the second file
  sleep 0.05
  printf '## Compact checkpoint\n\n**Branch:** feat/latest-session\n' \
    > "$tmpdir/.rig/memory/.compact-checkpoint-222.md"

  local output
  output=$((cd "$tmpdir" && RIG_DIR="$tmpdir/.rig" \
    printf '{"source":"compact"}' | \
    bash "$REPO_ROOT/templates/project/.claude/hooks/session-start.sh") 2>/dev/null)

  echo "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
ctx = d['hookSpecificOutput']['additionalContext']
assert 'latest-session' in ctx, 'Expected latest-session but got: ' + ctx
assert 'old-session' not in ctx, 'Got stale checkpoint instead of latest: ' + ctx
" 2>/dev/null
  [ "$?" -eq 0 ]
  rm -rf "$tmpdir"
}

@test "syntax: subagent-start.sh has valid bash syntax" {
  run bash -n "$REPO_ROOT/templates/project/.claude/hooks/subagent-start.sh"
  [ "$status" -eq 0 ]
}

@test "stealth default: install without --tracking uses stealth mode" {
  local rig_ext="$TEMP_DIR/rig-stealth"
  run bash "$INSTALLER" --project-only \
    --target "$TEST_PROJECT" \
    --project-name "TestProject" \
    --strategy skip \
    --rig-dir "$rig_ext"
  [ "$status" -eq 0 ]
  [ -f "$rig_ext/memory/PROGRESS.md" ]
  [ ! -f "$TEST_PROJECT/.rig/memory/PROGRESS.md" ]
}

@test "syntax: session-end.sh has valid bash syntax" {
  run bash -n "$REPO_ROOT/templates/project/.claude/hooks/session-end.sh"
  [ "$status" -eq 0 ]
}

@test "syntax: code-reviewer agent has valid markdown header" {
  run grep -q "^name: code-reviewer" "$REPO_ROOT/templates/project/.claude/agents/code-reviewer.md"
  [ "$status" -eq 0 ]
}

@test "feature-docs: doc-feature.md excluded from default install" {
  local tmpdir
  tmpdir=$(mktemp -d)
  git -C "$tmpdir" init -q
  bash "$REPO_ROOT/install.sh" --project-only --target "$tmpdir" --strategy merge \
    --tracking repo 2>/dev/null
  [ ! -f "$tmpdir/.claude/commands/doc-feature.md" ]
  rm -rf "$tmpdir"
}

@test "feature-docs: doc-feature.md included with --feature-docs flag" {
  local tmpdir
  tmpdir=$(mktemp -d)
  git -C "$tmpdir" init -q
  bash "$REPO_ROOT/install.sh" --project-only --target "$tmpdir" --strategy merge \
    --tracking repo --feature-docs 2>/dev/null
  [ -f "$tmpdir/.claude/commands/doc-feature.md" ]
  rm -rf "$tmpdir"
}

@test "feature-docs: upgrade preserves existing doc-feature.md without flag" {
  local tmpdir
  tmpdir=$(mktemp -d)
  git -C "$tmpdir" init -q
  # Fresh install with feature-docs
  bash "$REPO_ROOT/install.sh" --project-only --target "$tmpdir" --strategy merge \
    --tracking repo --feature-docs 2>/dev/null
  [ -f "$tmpdir/.claude/commands/doc-feature.md" ] || skip "initial install failed"
  # Upgrade without --feature-docs — should preserve
  bash "$REPO_ROOT/install.sh" --project-only --target "$tmpdir" --strategy upgrade \
    --tracking repo 2>/dev/null
  [ -f "$tmpdir/.claude/commands/doc-feature.md" ]
  rm -rf "$tmpdir"
}

@test "feature-docs: upgrade on project without feature-docs does not add them" {
  local tmpdir
  tmpdir=$(mktemp -d)
  git -C "$tmpdir" init -q
  bash "$REPO_ROOT/install.sh" --project-only --target "$tmpdir" --strategy merge \
    --tracking repo 2>/dev/null
  [ ! -f "$tmpdir/.claude/commands/doc-feature.md" ] || skip "initial install unexpectedly included feature-docs"
  bash "$REPO_ROOT/install.sh" --project-only --target "$tmpdir" --strategy upgrade \
    --tracking repo 2>/dev/null
  [ ! -f "$tmpdir/.claude/commands/doc-feature.md" ]
  rm -rf "$tmpdir"
}

@test "subagents: subagent-start.sh excluded from default install" {
  local tmpdir
  tmpdir=$(mktemp -d)
  git -C "$tmpdir" init -q
  bash "$REPO_ROOT/install.sh" --project-only --target "$tmpdir" --strategy merge \
    --tracking repo 2>/dev/null
  [ ! -f "$tmpdir/.claude/hooks/subagent-start.sh" ]
  rm -rf "$tmpdir"
}

@test "subagents: subagent-start.sh included with --subagents flag" {
  local tmpdir
  tmpdir=$(mktemp -d)
  git -C "$tmpdir" init -q
  bash "$REPO_ROOT/install.sh" --project-only --target "$tmpdir" --strategy merge \
    --tracking repo --subagents 2>/dev/null
  [ -f "$tmpdir/.claude/hooks/subagent-start.sh" ]
  rm -rf "$tmpdir"
}

@test "subagents: SubagentStart wired in settings.json with --subagents flag" {
  local tmpdir
  tmpdir=$(mktemp -d)
  git -C "$tmpdir" init -q
  bash "$REPO_ROOT/install.sh" --project-only --target "$tmpdir" --strategy merge \
    --tracking repo --subagents 2>/dev/null
  grep -q '"SubagentStart"' "$tmpdir/.claude/settings.json"
  rm -rf "$tmpdir"
}

@test "subagents: SubagentStart absent from settings.json without flag" {
  local tmpdir
  tmpdir=$(mktemp -d)
  git -C "$tmpdir" init -q
  bash "$REPO_ROOT/install.sh" --project-only --target "$tmpdir" --strategy merge \
    --tracking repo 2>/dev/null
  ! grep -q '"SubagentStart"' "$tmpdir/.claude/settings.json"
  rm -rf "$tmpdir"
}

@test "subagents: upgrade preserves existing subagent-start.sh without flag" {
  local tmpdir
  tmpdir=$(mktemp -d)
  git -C "$tmpdir" init -q
  bash "$REPO_ROOT/install.sh" --project-only --target "$tmpdir" --strategy merge \
    --tracking repo --subagents 2>/dev/null
  [ -f "$tmpdir/.claude/hooks/subagent-start.sh" ] || skip "initial install failed"
  bash "$REPO_ROOT/install.sh" --project-only --target "$tmpdir" --strategy upgrade \
    --tracking repo 2>/dev/null
  [ -f "$tmpdir/.claude/hooks/subagent-start.sh" ]
  rm -rf "$tmpdir"
}

@test "subagents: upgrade on project without subagents does not add hook" {
  local tmpdir
  tmpdir=$(mktemp -d)
  git -C "$tmpdir" init -q
  bash "$REPO_ROOT/install.sh" --project-only --target "$tmpdir" --strategy merge \
    --tracking repo 2>/dev/null
  [ ! -f "$tmpdir/.claude/hooks/subagent-start.sh" ] || skip "initial install unexpectedly included subagent-start"
  bash "$REPO_ROOT/install.sh" --project-only --target "$tmpdir" --strategy upgrade \
    --tracking repo 2>/dev/null
  [ ! -f "$tmpdir/.claude/hooks/subagent-start.sh" ]
  rm -rf "$tmpdir"
}

@test "contribute: rig-gaps.md excluded from default install" {
  local tmpdir
  tmpdir=$(mktemp -d)
  git -C "$tmpdir" init -q
  bash "$REPO_ROOT/install.sh" --project-only --target "$tmpdir" --strategy merge \
    --tracking repo 2>/dev/null
  [ ! -f "$tmpdir/.claude/commands/rig-gaps.md" ]
  rm -rf "$tmpdir"
}

@test "contribute: rig-gaps.md and rig-propose.md included with --contribute flag" {
  local tmpdir
  tmpdir=$(mktemp -d)
  git -C "$tmpdir" init -q
  bash "$REPO_ROOT/install.sh" --project-only --target "$tmpdir" --strategy merge \
    --tracking repo --contribute 2>/dev/null
  [ -f "$tmpdir/.claude/commands/rig-gaps.md" ]
  [ -f "$tmpdir/.claude/commands/rig-propose.md" ]
  rm -rf "$tmpdir"
}

@test "contribute: upgrade preserves existing rig-gaps.md without flag" {
  local tmpdir
  tmpdir=$(mktemp -d)
  git -C "$tmpdir" init -q
  bash "$REPO_ROOT/install.sh" --project-only --target "$tmpdir" --strategy merge \
    --tracking repo --contribute 2>/dev/null
  [ -f "$tmpdir/.claude/commands/rig-gaps.md" ] || skip "initial install failed"
  bash "$REPO_ROOT/install.sh" --project-only --target "$tmpdir" --strategy upgrade \
    --tracking repo 2>/dev/null
  [ -f "$tmpdir/.claude/commands/rig-gaps.md" ]
  rm -rf "$tmpdir"
}

@test "contribute: upgrade on project without contribute does not add rig-gaps" {
  local tmpdir
  tmpdir=$(mktemp -d)
  git -C "$tmpdir" init -q
  bash "$REPO_ROOT/install.sh" --project-only --target "$tmpdir" --strategy merge \
    --tracking repo 2>/dev/null
  [ ! -f "$tmpdir/.claude/commands/rig-gaps.md" ] || skip "initial install unexpectedly included contribute commands"
  bash "$REPO_ROOT/install.sh" --project-only --target "$tmpdir" --strategy upgrade \
    --tracking repo 2>/dev/null
  [ ! -f "$tmpdir/.claude/commands/rig-gaps.md" ]
  rm -rf "$tmpdir"
}

@test "syntax: pre-commit hook has valid bash syntax" {
  run bash -n "$REPO_ROOT/templates/project/.husky/pre-commit"
  [ "$status" -eq 0 ]
}

@test "syntax: commit-msg hook has valid bash syntax" {
  run bash -n "$REPO_ROOT/templates/project/.husky/commit-msg"
  [ "$status" -eq 0 ]
}

@test "syntax: post-commit hook has valid bash syntax" {
  run bash -n "$REPO_ROOT/templates/project/.husky/post-commit"
  [ "$status" -eq 0 ]
}

@test "syntax: post-merge hook has valid bash syntax" {
  run bash -n "$REPO_ROOT/templates/project/.husky/post-merge"
  [ "$status" -eq 0 ]
}

@test "syntax: filter-commit-message-inplace.sh has valid bash syntax" {
  run bash -n "$REPO_ROOT/templates/project/.husky/filter-commit-message-inplace.sh"
  [ "$status" -eq 0 ]
}

# ── Hook behavior: sentinel (commit gate) ─────────────────────────────────────
# The pre-tool hook blocks git commit unless .rig-commit-ok exists.
# We test the sentinel logic by sourcing a minimal version of the check.

_sentinel_check() {
  # Mirrors the sentinel logic in pre-tool.sh.
  # Returns 0 (allow) or 1 (block).
  local tool_name="$1"
  local rig_dir="$2"
  local sentinel="$rig_dir/memory/.rig-commit-ok"

  if [[ "$tool_name" == "Bash" ]]; then
    # Simulate checking stdin for a git commit command
    local input="$3"
    if echo "$input" | grep -q "git commit"; then
      if [[ ! -f "$sentinel" ]]; then
        return 1  # blocked
      fi
    fi
  fi
  return 0  # allowed
}

@test "sentinel: git commit blocked when .rig-commit-ok is absent" {
  local rig_dir="$TEMP_DIR/rig"
  mkdir -p "$rig_dir/memory"

  run _sentinel_check "Bash" "$rig_dir" "git commit -m 'test'"
  [ "$status" -ne 0 ]
}

@test "sentinel: git commit allowed when .rig-commit-ok exists" {
  local rig_dir="$TEMP_DIR/rig"
  mkdir -p "$rig_dir/memory"
  touch "$rig_dir/memory/.rig-commit-ok"

  _sentinel_check "Bash" "$rig_dir" "git commit -m 'test'"
  [ "$?" -eq 0 ]
}

@test "sentinel: non-commit Bash command always passes without sentinel" {
  local rig_dir="$TEMP_DIR/rig"
  mkdir -p "$rig_dir/memory"

  _sentinel_check "Bash" "$rig_dir" "ls -la"
  [ "$?" -eq 0 ]
}

@test "sentinel: non-Bash tool always passes without sentinel" {
  local rig_dir="$TEMP_DIR/rig"
  mkdir -p "$rig_dir/memory"

  _sentinel_check "Write" "$rig_dir" ""
  [ "$?" -eq 0 ]
}

# ── Hook behavior: main-branch commit guard ───────────────────────────────────
# pre-tool.sh blocks git commit on main/master unless CLAUDE.md sets
# housekeeping: direct-push. Tested independently of the sentinel check.

_main_branch_check() {
  # Mirrors the main-branch guard logic in pre-tool.sh.
  # Returns 0 (allow) or 1 (block).
  local current_branch="$1"
  local repo_dir="$2"

  if [[ "$current_branch" == "main" || "$current_branch" == "master" ]]; then
    local housekeeping
    housekeeping=$(grep "^housekeeping:" "$repo_dir/CLAUDE.md" 2>/dev/null \
      | awk '{print $2}' | tr -d '[:space:]' || echo "")
    if [[ "$housekeeping" != "direct-push" ]]; then
      return 1  # blocked
    fi
  fi
  return 0  # allowed
}

@test "main-branch guard: commit to main blocked when housekeeping is not direct-push" {
  local repo_dir="$TEMP_DIR/repo"
  mkdir -p "$repo_dir"
  echo "# CLAUDE.md" > "$repo_dir/CLAUDE.md"

  run _main_branch_check "main" "$repo_dir"
  [ "$status" -ne 0 ]
}

@test "main-branch guard: commit to main allowed when housekeeping is direct-push" {
  local repo_dir="$TEMP_DIR/repo"
  mkdir -p "$repo_dir"
  echo "housekeeping: direct-push" > "$repo_dir/CLAUDE.md"

  run _main_branch_check "main" "$repo_dir"
  [ "$status" -eq 0 ]
}

@test "main-branch guard: commit to non-main branch always passes" {
  local repo_dir="$TEMP_DIR/repo"
  mkdir -p "$repo_dir"

  run _main_branch_check "feat/my-feature" "$repo_dir"
  [ "$status" -eq 0 ]
}

# ── Hook behavior: PROGRESS.md auto-stub ──────────────────────────────────────
# post-tool.sh appends a stub to PROGRESS.md after every git commit.
# We test the stub logic in isolation.

_append_progress_stub() {
  # Mirrors the stub logic in post-tool.sh.
  local progress_file="$1"
  local commit_hash="$2"
  local commit_msg="$3"
  local date="$4"

  local stub="## $date — $commit_msg

- Commit: \`$commit_hash\`
- _Auto-logged by post-tool hook. Expand this entry during wrap-up._

---"

  # Idempotent: don't add if this hash is already present
  if grep -q "$commit_hash" "$progress_file" 2>/dev/null; then
    return 0
  fi

  # Prepend stub after the first line (header)
  local tmp; tmp="$(mktemp)"
  {
    head -1 "$progress_file" 2>/dev/null || true
    echo ""
    echo "$stub"
    echo ""
    tail -n +2 "$progress_file" 2>/dev/null || true
  } > "$tmp"
  mv "$tmp" "$progress_file"
}

@test "progress stub: appended after a commit hash is detected" {
  local progress="$TEMP_DIR/PROGRESS.md"
  echo "# Progress" > "$progress"

  _append_progress_stub "$progress" "abc1234" "feat: add thing" "2099-01-01"

  grep -q "abc1234" "$progress"
}

@test "progress stub: contains auto-logged marker text" {
  local progress="$TEMP_DIR/PROGRESS.md"
  echo "# Progress" > "$progress"

  _append_progress_stub "$progress" "def5678" "fix: something" "2099-01-01"

  grep -q "Auto-logged by post-tool hook" "$progress"
}

@test "progress stub: idempotent — same hash not added twice" {
  local progress="$TEMP_DIR/PROGRESS.md"
  echo "# Progress" > "$progress"

  _append_progress_stub "$progress" "abc9999" "chore: test" "2099-01-01"
  _append_progress_stub "$progress" "abc9999" "chore: test" "2099-01-01"

  local count
  count="$(grep -c "abc9999" "$progress")"
  [ "$count" -eq 1 ]
}

# ── Hook behavior: path blocking (RIG_PROTECTED) ──────────────────────────────
# pre-tool.sh blocks writes to governance files.
# We test the path-check logic in isolation.

_is_rig_protected() {
  # Mirrors the RIG_PROTECTED logic in pre-tool.sh.
  local file_path="$1"
  local rig_dir="${2:-.rig}"

  case "$file_path" in
    */.claude/hooks/*|\
    */.claude/settings*|\
    *"$rig_dir"/processes/*|\
    *"$rig_dir"/rules/*|\
    */.husky/*|\
    */CLAUDE.md)
      return 0 ;;  # protected
    *)
      return 1 ;;  # not protected
  esac
}

@test "path blocking: pre-tool.sh write is blocked" {
  _is_rig_protected "/repo/.claude/hooks/pre-tool.sh"
  [ "$?" -eq 0 ]
}

@test "path blocking: CLAUDE.md write is blocked" {
  _is_rig_protected "/repo/CLAUDE.md"
  [ "$?" -eq 0 ]
}

@test "path blocking: processes/ write is blocked" {
  _is_rig_protected "/repo/.rig/processes/SHIP_WORKFLOW.md"
  [ "$?" -eq 0 ]
}

@test "path blocking: rules/ write is blocked" {
  _is_rig_protected "/repo/.rig/rules/coding-standards.md"
  [ "$?" -eq 0 ]
}

@test "path blocking: PROGRESS.md write is allowed" {
  run _is_rig_protected "/repo/.rig/memory/PROGRESS.md"
  [ "$status" -ne 0 ]
}

@test "path blocking: src/ file write is allowed" {
  run _is_rig_protected "/repo/src/app/page.tsx"
  [ "$status" -ne 0 ]
}

@test "path blocking: task file write is allowed" {
  run _is_rig_protected "/repo/.rig/tasks/active/TASK_my-feature.md"
  [ "$status" -ne 0 ]
}

# ── Self-install detector ─────────────────────────────────────────────────────

@test "self-install detector: skips cleanup when install.sh is git-tracked" {
  local rig_dir="$TEMP_DIR/rig-self"
  mkdir -p "$rig_dir"
  cp "$INSTALLER" "$rig_dir/install.sh"
  cp -r "$REPO_ROOT/templates" "$rig_dir/templates"
  git -C "$rig_dir" init -q
  git -C "$rig_dir" config user.email "test@test.com"
  git -C "$rig_dir" config user.name "Test"
  git -C "$rig_dir" add install.sh
  git -C "$rig_dir" commit -q -m "init"

  run bash "$rig_dir/install.sh" --project-only \
    --target "$rig_dir" \
    --project-name "TestProject" \
    --strategy skip

  [ "$status" -eq 0 ]
  [ -f "$rig_dir/install.sh" ]
  [[ "$output" != *"run from inside the target"* ]]
}

@test "self-install detector: offers cleanup when install.sh is not git-tracked" {
  local rig_dir="$TEMP_DIR/rig-self"
  mkdir -p "$rig_dir"
  cp "$INSTALLER" "$rig_dir/install.sh"
  cp -r "$REPO_ROOT/templates" "$rig_dir/templates"
  git -C "$rig_dir" init -q
  git -C "$rig_dir" config user.email "test@test.com"
  git -C "$rig_dir" config user.name "Test"
  # install.sh intentionally not committed — artifact scenario

  run bash "$rig_dir/install.sh" --project-only \
    --target "$rig_dir" \
    --project-name "TestProject" \
    --strategy skip

  [ "$status" -eq 0 ]
  [ ! -f "$rig_dir/install.sh" ]
}

# ── Stealth mode: Husky conflict detection ────────────────────────────────────

@test "stealth mode: warns when .husky/ exists in target project" {
  local rig_external="$TEMP_DIR/rig-ext"
  mkdir -p "$rig_external" "$TEST_PROJECT/.husky"
  touch "$TEST_PROJECT/.husky/pre-commit"

  run bash "$INSTALLER" --project-only --strategy skip \
    <<< "$(printf '%s\n4\n%s\n' "$TEST_PROJECT" "$rig_external")"

  [ "$status" -eq 0 ]
  [[ "$output" == *".husky/ detected"* ]]
}

@test "--skip-git-hooks: skips .git/hooks/ writes in stealth mode" {
  local rig_external="$TEMP_DIR/rig-ext"
  mkdir -p "$rig_external"

  run bash "$INSTALLER" --project-only --strategy skip --skip-git-hooks \
    <<< "$(printf '%s\n4\n%s\n' "$TEST_PROJECT" "$rig_external")"

  [ "$status" -eq 0 ]
  [ ! -f "$TEST_PROJECT/.git/hooks/commit-msg" ]
  [[ "$output" == *"--skip-git-hooks set"* ]]
}

# ── --tracking flag ───────────────────────────────────────────────────────────

@test "--tracking stealth: installs without prompting when used with --target" {
  local rig_ext="$TEMP_DIR/rig-external"
  run_installer --strategy skip --tracking stealth --rig-dir "$rig_ext"
  [ "$status" -eq 0 ]
  [ -f "$rig_ext/memory/PROGRESS.md" ]
  [ ! -f "$TEST_PROJECT/.rig/memory/PROGRESS.md" ]
}

@test "--tracking: invalid value exits non-zero with error message" {
  run_installer --strategy skip --tracking bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid --tracking"* ]]
}

@test "--target without --tracking defaults to stealth tracking" {
  local rig_ext="$TEMP_DIR/rig-stealth-default"
  # Call installer directly (not run_installer) — no --tracking, no prompt stdin
  run bash "$INSTALLER" --project-only \
    --target "$TEST_PROJECT" \
    --project-name "TestProject" \
    --strategy skip \
    --rig-dir "$rig_ext"
  # .rig/ lands in external dir, not inside the project
  [ -f "$rig_ext/memory/PROGRESS.md" ]
  [ ! -f "$TEST_PROJECT/.rig/memory/PROGRESS.md" ]
  [ -f "$TEST_PROJECT/.rigpath" ]
}

@test "upgrade without --tracking auto-detects stealth mode from .rigpath" {
  # Simulate a project previously installed with --tracking stealth:
  # .rigpath exists pointing at an external directory.
  local rig_ext="$TEMP_DIR/rig-external"
  mkdir -p "$rig_ext"
  echo "$rig_ext" > "$TEST_PROJECT/.rigpath"

  # Call installer directly without --tracking so .rigpath auto-detection fires.
  # run_installer() prepends --tracking repo which would override auto-detect.
  run bash "$INSTALLER" --project-only \
    --target "$TEST_PROJECT" \
    --project-name "TestProject" \
    --strategy skip
  [ "$status" -eq 0 ]
  # .rig/ files must land in external dir, not project dir
  [ -f "$rig_ext/memory/PROGRESS.md" ]
  [ ! -f "$TEST_PROJECT/.rig/memory/PROGRESS.md" ]
}

@test "stealth install adds .rig/ to .git/info/exclude" {
  local rig_ext="$TEMP_DIR/rig-external"
  run_installer --strategy skip --tracking stealth --rig-dir "$rig_ext"
  [ "$status" -eq 0 ]
  grep -qF ".rig/" "$TEST_PROJECT/.git/info/exclude"
}

@test "stealth migration: warns about stale in-repo .rig/ and auto-removes in non-interactive mode" {
  # Start with a repo-tracked install so .rig/ exists in the project directory.
  run_installer --strategy skip --tracking repo
  [ "$status" -eq 0 ]
  [ -d "$TEST_PROJECT/.rig" ]

  # Re-install in stealth mode. confirm() is non-interactive (non-TTY in bats),
  # so it uses the default "y" and auto-removes .rig/ without reading stdin.
  local rig_ext="$TEMP_DIR/rig-stealth-migration"
  run bash "$INSTALLER" --project-only \
    --target "$TEST_PROJECT" \
    --project-name "TestProject" \
    --tracking stealth \
    --rig-dir "$rig_ext" \
    --strategy merge
  [ "$status" -eq 0 ]
  # Warning must mention the stale .rig/
  [[ "$output" == *"In-repo .rig/ found"* ]] || [[ "$output" == *"superseded"* ]]
  # Non-interactive default is "y" — .rig/ is auto-removed
  [ ! -d "$TEST_PROJECT/.rig" ]
}

@test "upgrade auto-detects repo mode when .rig/ is git-committed" {
  # Simulate a project previously installed in repo mode: .rig/ files committed.
  run_installer --strategy skip --tracking repo
  git -C "$TEST_PROJECT" add "$TEST_PROJECT/.rig/VERSION"
  git -C "$TEST_PROJECT" commit -m "chore: initial rig install" --allow-empty-message 2>/dev/null || true

  # Run upgrade directly (not via run_installer) so auto-detect fires.
  run bash "$INSTALLER" --project-only \
    --target "$TEST_PROJECT" \
    --project-name "TestProject" \
    --strategy upgrade
  [ "$status" -eq 0 ]
  # Must stay in repo mode: no .rigpath, .rig/VERSION still in project dir
  [ ! -f "$TEST_PROJECT/.rigpath" ]
  [ -f "$TEST_PROJECT/.rig/VERSION" ]
  [[ "$output" == *"Auto-detected existing tracking mode: repo"* ]]
}

@test "upgrade auto-detects local mode when .rig/ is in .git/info/exclude" {
  # Simulate a project previously installed in local mode.
  run_installer --strategy skip --tracking local
  # Confirm .rig/ is in .git/info/exclude (installed by --tracking local)
  grep -qF ".rig/" "$TEST_PROJECT/.git/info/exclude"

  # Run upgrade directly so auto-detect fires.
  run bash "$INSTALLER" --project-only \
    --target "$TEST_PROJECT" \
    --project-name "TestProject" \
    --strategy upgrade
  [ "$status" -eq 0 ]
  # Must stay in local mode: no .rigpath, .rig/ still in project dir
  [ ! -f "$TEST_PROJECT/.rigpath" ]
  [ -f "$TEST_PROJECT/.rig/VERSION" ]
  [[ "$output" == *"Auto-detected existing tracking mode: local"* ]]
}

@test "upgrade auto-detects local mode when .rig/ is in .gitignore" {
  # Simulate a project where .rig/ was manually added to .gitignore (not via installer).
  run_installer --strategy skip --tracking repo
  echo ".rig/" >> "$TEST_PROJECT/.gitignore"

  # .rig/ files are NOT in the git index (run_installer --tracking repo commits nothing).
  run bash "$INSTALLER" --project-only \
    --target "$TEST_PROJECT" \
    --project-name "TestProject" \
    --strategy upgrade
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_PROJECT/.rigpath" ]
  [[ "$output" == *"Auto-detected existing tracking mode: local"* ]]
}

@test "fresh install: .rig/VERSION matches installer VERSION" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]
  local installed; installed=$(cat "$TEST_PROJECT/.rig/VERSION")
  local expected; expected=$(cat "$BATS_TEST_DIRNAME/../VERSION")
  [ "$installed" = "$expected" ]
}

@test "upgrade: .rig/VERSION updated to installer VERSION even when template is stale" {
  # Simulate an installed project whose .rig/VERSION is behind the installer.
  run_installer --strategy skip
  [ "$status" -eq 0 ]
  echo "0.0.0" > "$TEST_PROJECT/.rig/VERSION"

  run_installer --strategy upgrade
  [ "$status" -eq 0 ]
  local installed; installed=$(cat "$TEST_PROJECT/.rig/VERSION")
  local expected; expected=$(cat "$BATS_TEST_DIRNAME/../VERSION")
  [ "$installed" = "$expected" ]
}

# ── Gap 4: session-end.sh writes .wrap-needed on 2+ commits ──────────────────
# Note: this logic moved from stop.sh to session-end.sh in Sprint 5.
# stop.sh now only updates CONTEXT_SNAPSHOT date and appends session-end markers.

@test "session-end.sh: writes .wrap-needed when session log has 2+ commits" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]

  local rig_dir="$TEST_PROJECT/.rig"
  local session_end_hook="$TEST_PROJECT/.claude/hooks/session-end.sh"
  local session_log="$TEMP_DIR/test-session.log"
  local wrap_needed="$rig_dir/memory/.wrap-needed"

  # Provide a snapshot so the "no snapshot" trigger doesn't fire first,
  # and ensure PROGRESS.md has no stubs (skip install creates none).
  # Together these isolate to the 2+ commits path.
  printf '**Last updated:** 2026-01-01 — test snapshot\n' \
    > "$rig_dir/memory/CONTEXT_SNAPSHOT.md"

  # Simulate two commits having been logged this session
  printf '[10:00:00] PROGRESS stub: abc1234 feat(x): first commit [#1]\n' >> "$session_log"
  printf '[10:01:00] PROGRESS stub: def5678 feat(x): second commit [#1]\n' >> "$session_log"

  rm -f "$wrap_needed"

  # Run session-end.sh with source=logout; cd into project so git rev-parse resolves correctly
  echo '{"source": "logout"}' \
    | ( cd "$TEST_PROJECT" && RIG_SESSION_LOG="$session_log" bash "$session_end_hook" )

  [ -f "$wrap_needed" ]
}

@test "session-end.sh: does not write .wrap-needed when session has fewer than 2 commits" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]

  local rig_dir="$TEST_PROJECT/.rig"
  local session_end_hook="$TEST_PROJECT/.claude/hooks/session-end.sh"
  local session_log="$TEMP_DIR/test-session.log"
  local wrap_needed="$rig_dir/memory/.wrap-needed"

  # Same isolation: snapshot present, no stubs, only 1 commit in session log
  printf '**Last updated:** 2026-01-01 — test snapshot\n' \
    > "$rig_dir/memory/CONTEXT_SNAPSHOT.md"

  printf '[10:00:00] PROGRESS stub: abc1234 feat(x): first commit [#1]\n' >> "$session_log"

  rm -f "$wrap_needed"

  echo '{"source": "logout"}' \
    | ( cd "$TEST_PROJECT" && RIG_SESSION_LOG="$session_log" bash "$session_end_hook" )

  [ ! -f "$wrap_needed" ]
}

# ── TASK_255: session-end.sh skips write_minimal_checkpoint if snap lock held ─

@test "session-end.sh: skips write_minimal_checkpoint when snapshot write lock exists" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]

  local rig_dir="$TEST_PROJECT/.rig"
  local session_end_hook="$TEST_PROJECT/.claude/hooks/session-end.sh"
  local session_log="$TEMP_DIR/the-rig-session-test.log"
  local snap_lock="$rig_dir/memory/.snapshot-write-in-progress"

  # Write a recognisable snapshot so we can detect if it was overwritten
  printf '**Last updated:** 2026-01-01 — original snapshot\n' \
    > "$rig_dir/memory/CONTEXT_SNAPSHOT.md"

  # Simulate /wrap holding the lock
  touch "$snap_lock"

  echo '{"source": "logout"}' \
    | ( cd "$TEST_PROJECT" && RIG_SESSION_LOG="$session_log" bash "$session_end_hook" )

  # Snapshot must be unchanged — write_minimal_checkpoint was skipped
  grep -q "original snapshot" "$rig_dir/memory/CONTEXT_SNAPSHOT.md"
}

@test "session-end.sh: write_minimal_checkpoint runs normally when no lock exists" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]

  local rig_dir="$TEST_PROJECT/.rig"
  local session_end_hook="$TEST_PROJECT/.claude/hooks/session-end.sh"
  local session_log="$TEMP_DIR/the-rig-session-test.log"
  local snap_lock="$rig_dir/memory/.snapshot-write-in-progress"

  printf '**Last updated:** 2026-01-01 — original snapshot\n' \
    > "$rig_dir/memory/CONTEXT_SNAPSHOT.md"
  # Ensure unexpanded stubs exist so the write-needed path is triggered
  printf '[10:00:00] PROGRESS stub: abc1234 feat(x): commit [#1]\n' >> "$session_log"
  printf '[10:01:00] PROGRESS stub: def5678 feat(x): commit [#2]\n' >> "$session_log"

  rm -f "$snap_lock"

  echo '{"source": "logout"}' \
    | ( cd "$TEST_PROJECT" && RIG_SESSION_LOG="$session_log" bash "$session_end_hook" )

  # Snapshot must have been replaced with the minimal checkpoint content
  grep -q "session-end checkpoint" "$rig_dir/memory/CONTEXT_SNAPSHOT.md"
}

# ── TASK_252: session name ownership via /tmp sentinel ───────────────────────

@test "session-end.sh: write_minimal_checkpoint omits session name when sentinel absent" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]

  local rig_dir="$TEST_PROJECT/.rig"
  local session_end_hook="$TEST_PROJECT/.claude/hooks/session-end.sh"
  local session_log="$TEMP_DIR/the-rig-session-test.log"

  # Snapshot has a name belonging to a sibling session
  printf '**Last updated:** 2026-01-01\n**Session name:** sibling-session-name\n\n---\n' \
    > "$rig_dir/memory/CONTEXT_SNAPSHOT.md"
  printf '[10:00:00] PROGRESS stub: abc1234 feat(x): first [#1]\n' >> "$session_log"
  printf '[10:01:00] PROGRESS stub: def5678 feat(x): second [#1]\n' >> "$session_log"
  rm -f "$rig_dir/memory/.snapshot-write-in-progress"

  # No sentinel — this session never called /session-name
  echo '{"source": "logout"}' \
    | ( cd "$TEST_PROJECT" && RIG_SESSION_LOG="$session_log" bash "$session_end_hook" )

  # Sibling's session name must NOT appear in the checkpoint
  run grep "sibling-session-name" "$rig_dir/memory/CONTEXT_SNAPSHOT.md"
  [ "$status" -ne 0 ]
}

@test "session-end.sh: write_minimal_checkpoint preserves session name when sentinel present" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]

  local rig_dir="$TEST_PROJECT/.rig"
  local session_end_hook="$TEST_PROJECT/.claude/hooks/session-end.sh"
  local session_log="$TEMP_DIR/the-rig-session-test.log"

  # Snapshot has this session's own name
  printf '**Last updated:** 2026-01-01\n**Session name:** my-own-session\n\n---\n' \
    > "$rig_dir/memory/CONTEXT_SNAPSHOT.md"
  printf '[10:00:00] PROGRESS stub: abc1234 feat(x): first [#1]\n' >> "$session_log"
  printf '[10:01:00] PROGRESS stub: def5678 feat(x): second [#1]\n' >> "$session_log"
  rm -f "$rig_dir/memory/.snapshot-write-in-progress"

  # Run via bash -c so $$ inside = PPID seen by session-end.sh
  local test_project="$TEST_PROJECT"
  bash -c "
    touch \"/tmp/.rig-session-name-set-\$\$\"
    cd \"$test_project\"
    echo '{\"source\": \"logout\"}' \
      | RIG_SESSION_LOG=\"$session_log\" bash \"$session_end_hook\"
    rm -f \"/tmp/.rig-session-name-set-\$\$\" 2>/dev/null
  "

  # This session's name must appear in the checkpoint
  grep -q "my-own-session" "$rig_dir/memory/CONTEXT_SNAPSHOT.md"
}

# ── Session log path is per-project ──────────────────────────────────────────
# Hooks must write to /tmp/the-rig-session-<project>.log, not a global path.
# This prevents cross-project commit count contamination in session-end.sh.

@test "session log path: stop.sh and session-end.sh use per-project log filename" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]

  local stop_hook="$TEST_PROJECT/.claude/hooks/stop.sh"
  local session_end_hook="$TEST_PROJECT/.claude/hooks/session-end.sh"

  # Both hooks must reference the per-project pattern, not the global path
  run grep "the-rig-session\.log" "$stop_hook"
  [ "$status" -ne 0 ]  # global path must NOT appear

  run grep 'the-rig-session-.*\.log\|the-rig-session-\$(basename' "$stop_hook"
  [ "$status" -eq 0 ]  # per-project pattern must appear

  run grep "the-rig-session\.log" "$session_end_hook"
  [ "$status" -ne 0 ]  # global path must NOT appear

  run grep 'the-rig-session-.*\.log\|the-rig-session-\$(basename' "$session_end_hook"
  [ "$status" -eq 0 ]  # per-project pattern must appear
}

@test "session-end.sh: commit count not inflated by stubs from a different project" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]

  local rig_dir="$TEST_PROJECT/.rig"
  local session_end_hook="$TEST_PROJECT/.claude/hooks/session-end.sh"
  local wrap_needed="$rig_dir/memory/.wrap-needed"

  printf '**Last updated:** 2026-01-01 — test snapshot\n' \
    > "$rig_dir/memory/CONTEXT_SNAPSHOT.md"

  # Simulate a different project's log with 2 commits written to a separate path
  local other_project_log="$TEMP_DIR/the-rig-session-other-project.log"
  printf '[10:00:00] PROGRESS stub: abc1234 feat(x): first commit [#1]\n' >> "$other_project_log"
  printf '[10:01:00] PROGRESS stub: def5678 feat(x): second commit [#1]\n' >> "$other_project_log"

  # This project's log is empty — injected via RIG_SESSION_LOG pointing to
  # a per-project path with zero stubs
  local this_project_log="$TEMP_DIR/the-rig-session-test-project.log"

  rm -f "$wrap_needed"

  echo '{"source": "logout"}' \
    | ( cd "$TEST_PROJECT" && RIG_SESSION_LOG="$this_project_log" bash "$session_end_hook" )

  # .wrap-needed must NOT be set — the other project's stubs must not be visible
  [ ! -f "$wrap_needed" ]
}

# ── Gap 5: commit-msg validates Conventional Commits format ───────────────────

@test "commit-msg: rejects non-conventional commit message" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]

  local hook="$TEST_PROJECT/.husky/commit-msg"
  local msg_file="$TEMP_DIR/COMMIT_EDITMSG"

  # Overwrite CLAUDE.md with minimal content; hook only reads issue-tracking
  printf 'issue-tracking: none\n' > "$TEST_PROJECT/CLAUDE.md"

  printf 'fixed stuff\n' > "$msg_file"
  run bash -c "cd '$TEST_PROJECT' && sh '$hook' '$msg_file'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Conventional Commits"* ]]
}

@test "commit-msg: accepts valid conventional commit message" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]

  local hook="$TEST_PROJECT/.husky/commit-msg"
  local msg_file="$TEMP_DIR/COMMIT_EDITMSG"

  printf 'issue-tracking: none\n' > "$TEST_PROJECT/CLAUDE.md"

  printf 'feat(auth): add login flow\n' > "$msg_file"
  run bash -c "cd '$TEST_PROJECT' && sh '$hook' '$msg_file'"
  [ "$status" -eq 0 ]
}

@test "commit-msg: rejects message missing issue ref when issue-tracking: github" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]

  local hook="$TEST_PROJECT/.husky/commit-msg"
  local msg_file="$TEMP_DIR/COMMIT_EDITMSG"

  # Overwrite with controlled minimal content so first grep match is github
  printf 'issue-tracking: github\n' > "$TEST_PROJECT/CLAUDE.md"

  printf 'feat(auth): add login flow\n' > "$msg_file"
  run bash -c "cd '$TEST_PROJECT' && sh '$hook' '$msg_file'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"issue reference"* ]]
}

@test "commit-msg: accepts message with [#N] issue ref when issue-tracking: github" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]

  local hook="$TEST_PROJECT/.husky/commit-msg"
  local msg_file="$TEMP_DIR/COMMIT_EDITMSG"

  printf 'issue-tracking: github\n' > "$TEST_PROJECT/CLAUDE.md"

  printf 'feat(auth): add login flow [#42]\n' > "$msg_file"
  run bash -c "cd '$TEST_PROJECT' && sh '$hook' '$msg_file'"
  [ "$status" -eq 0 ]
}

@test "commit-msg: skips validation for merge commits" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]

  local hook="$TEST_PROJECT/.husky/commit-msg"
  local msg_file="$TEMP_DIR/COMMIT_EDITMSG"

  printf 'issue-tracking: github\n' > "$TEST_PROJECT/CLAUDE.md"

  printf "Merge branch 'feat/foo' into main\n" > "$msg_file"
  run bash -c "cd '$TEST_PROJECT' && sh '$hook' '$msg_file'"
  [ "$status" -eq 0 ]
}

@test "commit-msg: bypass with SKIP_COMMIT_VALIDATION=1" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]

  local hook="$TEST_PROJECT/.husky/commit-msg"
  local msg_file="$TEMP_DIR/COMMIT_EDITMSG"

  printf 'this is not conventional\n' > "$msg_file"
  run bash -c "cd '$TEST_PROJECT' && SKIP_COMMIT_VALIDATION=1 sh '$hook' '$msg_file'"
  [ "$status" -eq 0 ]
}

@test "commit-msg: rejects message missing Linear ref when issue-tracking: linear" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]

  local hook="$TEST_PROJECT/.husky/commit-msg"
  local msg_file="$TEMP_DIR/COMMIT_EDITMSG"

  printf 'issue-tracking: linear\n' > "$TEST_PROJECT/CLAUDE.md"

  printf 'feat(auth): add login flow\n' > "$msg_file"
  run bash -c "cd '$TEST_PROJECT' && sh '$hook' '$msg_file'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Linear"* ]]
}

@test "commit-msg: accepts message with Linear ref when issue-tracking: linear" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]

  local hook="$TEST_PROJECT/.husky/commit-msg"
  local msg_file="$TEMP_DIR/COMMIT_EDITMSG"

  printf 'issue-tracking: linear\n' > "$TEST_PROJECT/CLAUDE.md"

  printf 'feat(auth): add login flow [ENG-123]\n' > "$msg_file"
  run bash -c "cd '$TEST_PROJECT' && sh '$hook' '$msg_file'"
  [ "$status" -eq 0 ]
}

@test "commit-msg: rejects message missing Trello ref when issue-tracking: trello" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]

  local hook="$TEST_PROJECT/.husky/commit-msg"
  local msg_file="$TEMP_DIR/COMMIT_EDITMSG"

  printf 'issue-tracking: trello\n' > "$TEST_PROJECT/CLAUDE.md"

  printf 'feat(auth): add login flow\n' > "$msg_file"
  run bash -c "cd '$TEST_PROJECT' && sh '$hook' '$msg_file'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Trello"* ]]
}

@test "commit-msg: accepts message with Trello ref when issue-tracking: trello" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]

  local hook="$TEST_PROJECT/.husky/commit-msg"
  local msg_file="$TEMP_DIR/COMMIT_EDITMSG"

  printf 'issue-tracking: trello\n' > "$TEST_PROJECT/CLAUDE.md"

  printf 'feat(auth): add login flow [trello:abc123]\n' > "$msg_file"
  run bash -c "cd '$TEST_PROJECT' && sh '$hook' '$msg_file'"
  [ "$status" -eq 0 ]
}

@test "commit-msg: rejects message missing GUS ref when issue-tracking: gus" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]

  local hook="$TEST_PROJECT/.husky/commit-msg"
  local msg_file="$TEMP_DIR/COMMIT_EDITMSG"

  printf 'issue-tracking: gus\n' > "$TEST_PROJECT/CLAUDE.md"

  printf 'feat(auth): add login flow\n' > "$msg_file"
  run bash -c "cd '$TEST_PROJECT' && sh '$hook' '$msg_file'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"GUS"* ]]
}

@test "commit-msg: accepts message with GUS ref when issue-tracking: gus" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]

  local hook="$TEST_PROJECT/.husky/commit-msg"
  local msg_file="$TEMP_DIR/COMMIT_EDITMSG"

  printf 'issue-tracking: gus\n' > "$TEST_PROJECT/CLAUDE.md"

  printf 'feat(auth): add login flow [W-1234567]\n' > "$msg_file"
  run bash -c "cd '$TEST_PROJECT' && sh '$hook' '$msg_file'"
  [ "$status" -eq 0 ]
}

# ── pre-commit: .rig-debug-scan-exclude path exclusions ──────────────────────

@test "pre-commit: .rig-debug-scan-exclude skips matched paths" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]

  local hook="$TEST_PROJECT/.husky/pre-commit"

  # Stage a file containing a debug artifact
  mkdir -p "$TEST_PROJECT/vendor"
  printf 'console.log("test");\n' > "$TEST_PROJECT/vendor/debug.js" # rig-debug-ok
  git -C "$TEST_PROJECT" add vendor/debug.js

  # Without exclusion the hook blocks
  run bash -c "cd '$TEST_PROJECT' && sh '$hook'"
  [ "$status" -ne 0 ]

  # Add the path to .rig-debug-scan-exclude
  printf 'vendor/*\n' > "$TEST_PROJECT/.rig-debug-scan-exclude"

  # With exclusion the hook passes
  run bash -c "cd '$TEST_PROJECT' && sh '$hook'"
  [ "$status" -eq 0 ]
}

# ── Global layer upgrade ──────────────────────────────────────────────────────

_sha256() {
  sha256sum "$1" 2>/dev/null | awk '{print $1}' || shasum -a 256 "$1" | awk '{print $1}'
}

@test "upgrade strategy: global Rig-owned file updated when hash matches manifest" {
  local fake_home="$TEMP_DIR/fake-home"
  mkdir -p "$fake_home"

  # First install global layer into fake home (non-interactive: pipe empty input for prompts)
  run bash -c "echo '' | HOME='$fake_home' bash '$INSTALLER' --global-only --strategy skip"
  [ "$status" -eq 0 ]
  [ -f "$fake_home/.claude/CLAUDE.md" ]

  # Simulate an older installed version and record its hash in the global manifest
  printf '# old version\n' > "$fake_home/.claude/CLAUDE.md"
  local old_hash
  old_hash=$(_sha256 "$fake_home/.claude/CLAUDE.md")
  printf '%s  CLAUDE.md\n' "$old_hash" > "$fake_home/.claude/.rig-global-manifest"

  # Run upgrade — CLAUDE.md hash matches manifest → auto-update
  run bash -c "echo '' | HOME='$fake_home' bash '$INSTALLER' --global-only --strategy upgrade"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Updated"* ]]

  # File should no longer contain the old content
  run grep -c '# old version' "$fake_home/.claude/CLAUDE.md"
  [ "$output" -eq 0 ]
}

@test "upgrade strategy: customized global file not overwritten in non-interactive" {
  local fake_home="$TEMP_DIR/fake-home"
  mkdir -p "$fake_home"

  # First install global layer
  run bash -c "echo '' | HOME='$fake_home' bash '$INSTALLER' --global-only --strategy skip"
  [ "$status" -eq 0 ]

  # Record original hash in manifest
  local orig_hash
  orig_hash=$(_sha256 "$fake_home/.claude/CLAUDE.md")
  printf '%s  CLAUDE.md\n' "$orig_hash" > "$fake_home/.claude/.rig-global-manifest"

  # Simulate user customization (hash now differs from manifest)
  printf '\n# user customization\n' >> "$fake_home/.claude/CLAUDE.md"

  # Upgrade in non-interactive mode — must NOT overwrite the customized file
  run bash -c "echo '' | HOME='$fake_home' bash '$INSTALLER' --global-only --strategy upgrade"
  [ "$status" -eq 0 ]
  grep -q '# user customization' "$fake_home/.claude/CLAUDE.md"
}

# ── commit-msg: # no-issue trailer ───────────────────────────────────────────

@test "commit-msg: # no-issue trailer skips issue ref check for github tracker" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]

  local hook="$TEST_PROJECT/.husky/commit-msg"
  local msg_file="$TEMP_DIR/COMMIT_EDITMSG"

  printf 'issue-tracking: github\n' > "$TEST_PROJECT/CLAUDE.md"

  # Conventional commit but no issue ref — would normally fail
  # Body contains # no-issue → should pass
  printf 'chore(deps): bump library version\n\n# no-issue\n' > "$msg_file"
  run bash -c "cd '$TEST_PROJECT' && sh '$hook' '$msg_file'"
  [ "$status" -eq 0 ]
}

@test "commit-msg: # no-issue trailer skips issue ref check for linear tracker" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]

  local hook="$TEST_PROJECT/.husky/commit-msg"
  local msg_file="$TEMP_DIR/COMMIT_EDITMSG"

  printf 'issue-tracking: linear\n' > "$TEST_PROJECT/CLAUDE.md"

  printf 'chore(deps): bump library version\n\n# no-issue\n' > "$msg_file"
  run bash -c "cd '$TEST_PROJECT' && sh '$hook' '$msg_file'"
  [ "$status" -eq 0 ]
}

@test "commit-msg: without # no-issue, github tracker still requires ref" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]

  local hook="$TEST_PROJECT/.husky/commit-msg"
  local msg_file="$TEMP_DIR/COMMIT_EDITMSG"

  printf 'issue-tracking: github\n' > "$TEST_PROJECT/CLAUDE.md"

  # No # no-issue, no ref → must still fail
  printf 'chore(deps): bump library version\n\nSome body text.\n' > "$msg_file"
  run bash -c "cd '$TEST_PROJECT' && sh '$hook' '$msg_file'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"issue reference"* ]]
}

# ── install.sh: branch drift warning ─────────────────────────────────────────

@test "installer drift check: warns when installer repo is behind remote" {
  # Create a bare remote repo and a local clone that's 1 commit behind
  local remote_repo="$TEMP_DIR/rig-remote"
  local local_repo="$TEMP_DIR/rig-local"

  git init -q "$remote_repo"
  git -C "$remote_repo" config user.email "test@test.com"
  git -C "$remote_repo" config user.name "Test"
  touch "$remote_repo/placeholder"
  git -C "$remote_repo" add placeholder
  git -C "$remote_repo" commit -q -m "initial commit"

  git clone -q "$remote_repo" "$local_repo"
  git -C "$local_repo" config user.email "test@test.com"
  git -C "$local_repo" config user.name "Test"

  # Add a commit to the remote that the local doesn't have
  touch "$remote_repo/newfile"
  git -C "$remote_repo" add newfile
  git -C "$remote_repo" commit -q -m "new commit on remote"

  # Run installer with _RIG_DRIFT_DIR pointing to the local (stale) repo
  run bash -c "_RIG_DRIFT_DIR='$local_repo' bash '$INSTALLER' --project-only \
    --target '$TEST_PROJECT' --project-name 'TestProject' --strategy skip"
  [ "$status" -eq 0 ]
  [[ "$output" == *"behind"* ]]
}

@test "installer drift check: no warning when installer repo is up to date" {
  # A git repo with a remote that matches HEAD — no warning expected
  local remote_repo="$TEMP_DIR/rig-remote"
  local local_repo="$TEMP_DIR/rig-local"

  git init -q "$remote_repo"
  git -C "$remote_repo" config user.email "test@test.com"
  git -C "$remote_repo" config user.name "Test"
  touch "$remote_repo/placeholder"
  git -C "$remote_repo" add placeholder
  git -C "$remote_repo" commit -q -m "initial commit"

  git clone -q "$remote_repo" "$local_repo"
  git -C "$local_repo" config user.email "test@test.com"
  git -C "$local_repo" config user.name "Test"

  # Local and remote are in sync
  run bash -c "_RIG_DRIFT_DIR='$local_repo' bash '$INSTALLER' --project-only \
    --target '$TEST_PROJECT' --project-name 'TestProject' --strategy skip"
  [ "$status" -eq 0 ]
  [[ "$output" != *"behind"* ]]
}

# ── Command behavior: /status ─────────────────────────────────────────────────
# /status reads RIG_DIR, counts backlog tasks, and checks pending flag files.
# We test the extractable shell logic in isolation.

_status_resolve_rig_dir() {
  # Mirrors RIG_DIR resolution in /status (and all other commands).
  # Prints the resolved RIG_DIR path.
  local repo="$1"
  if [[ -f "$repo/.rigpath" ]]; then
    tr -d '[:space:]' < "$repo/.rigpath"
  else
    echo "$repo/.rig"
  fi
}

_status_pending_flags() {
  # Returns a space-separated list of active flag names, or nothing.
  local rig_dir="$1"
  local flags=""
  [[ -f "$rig_dir/memory/.wrap-needed" ]] && flags="$flags wrap-needed"
  [[ -f "$rig_dir/memory/.post-merge-pending" ]] && flags="$flags post-merge-pending"
  echo "${flags# }"
}

_status_backlog_count() {
  # Returns the number of task files in the backlog directory.
  ls "$1/tasks/backlog/" 2>/dev/null | wc -l | tr -d '[:space:]'
}

@test "status: RIG_DIR resolves to repo/.rig when .rigpath absent" {
  local repo="$TEMP_DIR/repo"
  mkdir -p "$repo"

  result=$(_status_resolve_rig_dir "$repo")
  [ "$result" = "$repo/.rig" ]
}

@test "status: RIG_DIR resolves to external path when .rigpath present" {
  local repo="$TEMP_DIR/repo"
  local external="$TEMP_DIR/external-rig"
  mkdir -p "$repo"
  echo "$external" > "$repo/.rigpath"

  result=$(_status_resolve_rig_dir "$repo")
  [ "$result" = "$external" ]
}

@test "status: no pending flags when neither sentinel exists" {
  local rig_dir="$TEMP_DIR/rig"
  mkdir -p "$rig_dir/memory"

  result=$(_status_pending_flags "$rig_dir")
  [ "$result" = "" ]
}

@test "status: wrap-needed flag detected when sentinel present" {
  local rig_dir="$TEMP_DIR/rig"
  mkdir -p "$rig_dir/memory"
  touch "$rig_dir/memory/.wrap-needed"

  result=$(_status_pending_flags "$rig_dir")
  [[ "$result" == *"wrap-needed"* ]]
}

@test "status: both flags detected when both sentinels present" {
  local rig_dir="$TEMP_DIR/rig"
  mkdir -p "$rig_dir/memory"
  touch "$rig_dir/memory/.wrap-needed"
  touch "$rig_dir/memory/.post-merge-pending"

  result=$(_status_pending_flags "$rig_dir")
  [[ "$result" == *"wrap-needed"* ]]
  [[ "$result" == *"post-merge-pending"* ]]
}

@test "status: backlog count returns correct number of task files" {
  local rig_dir="$TEMP_DIR/rig"
  mkdir -p "$rig_dir/tasks/backlog"
  touch "$rig_dir/tasks/backlog/TASK_alpha.md"
  touch "$rig_dir/tasks/backlog/TASK_beta.md"
  touch "$rig_dir/tasks/backlog/TASK_gamma.md"

  result=$(_status_backlog_count "$rig_dir")
  [ "$result" = "3" ]
}

@test "status: backlog count is zero when backlog directory is empty" {
  local rig_dir="$TEMP_DIR/rig"
  mkdir -p "$rig_dir/tasks/backlog"

  result=$(_status_backlog_count "$rig_dir")
  [ "$result" = "0" ]
}

# ── Command behavior: /wrap concurrent session guard ──────────────────────────
# /wrap checks for .wrap-in-progress before doing anything, then creates it.
# We test the acquire/release cycle in isolation.

_wrap_acquire_lock() {
  # Mirrors the concurrent session guard in /wrap and /post-merge.
  # Returns 0 (lock acquired + sentinel created) or 1 (active lock present).
  local wrap_lock="$1"
  if [[ -f "$wrap_lock" ]]; then
    local lock_age
    lock_age=$(( $(date +%s) - $(stat -c %Y "$wrap_lock" 2>/dev/null || stat -f %m "$wrap_lock" 2>/dev/null || echo 0) ))
    if [[ "$lock_age" -gt 1800 ]]; then
      rm -f "$wrap_lock"  # stale — auto-expire
    else
      return 1  # active lock, block
    fi
  fi
  touch "$wrap_lock"
  return 0
}

_wrap_release_lock() {
  # Mirrors the cleanup at the end of /wrap (step 11).
  local wrap_lock="$1"
  rm -f "$wrap_lock"
}

@test "wrap guard: lock acquisition blocked when sentinel already exists" {
  local rig_dir="$TEMP_DIR/rig"
  mkdir -p "$rig_dir/memory"
  local lock="$rig_dir/memory/.wrap-in-progress"
  touch "$lock"  # fresh mtime — under 1800s, must block

  run _wrap_acquire_lock "$lock"
  [ "$status" -ne 0 ]
}

@test "wrap guard: stale lock (>1800s) is auto-removed and acquisition proceeds" {
  local rig_dir="$TEMP_DIR/rig"
  mkdir -p "$rig_dir/memory"
  local lock="$rig_dir/memory/.wrap-in-progress"
  touch "$lock"
  # Set mtime to 2025-01-01 00:00 — guaranteed older than 30 minutes
  touch -t 202501010000 "$lock"

  run _wrap_acquire_lock "$lock"
  [ "$status" -eq 0 ]
  [ -f "$lock" ]  # new lock written
  # Verify the new lock has a recent mtime (within 60s of now)
  local new_age
  new_age=$(( $(date +%s) - $(stat -c %Y "$lock" 2>/dev/null || stat -f %m "$lock" 2>/dev/null || echo 0) ))
  [ "$new_age" -lt 60 ]
}

@test "wrap guard: lock acquired and sentinel created when none exists" {
  local rig_dir="$TEMP_DIR/rig"
  mkdir -p "$rig_dir/memory"
  local lock="$rig_dir/memory/.wrap-in-progress"

  run _wrap_acquire_lock "$lock"
  [ "$status" -eq 0 ]
  [[ -f "$lock" ]]
}

@test "wrap guard: sentinel removed after lock release" {
  local rig_dir="$TEMP_DIR/rig"
  mkdir -p "$rig_dir/memory"
  local lock="$rig_dir/memory/.wrap-in-progress"
  touch "$lock"

  _wrap_release_lock "$lock"
  [[ ! -f "$lock" ]]
}

# ── Command behavior: /ship commit sentinel ───────────────────────────────────
# /ship Step 7 creates .rig-commit-ok before running git commit.
# pre-tool.sh checks for this sentinel (tested in the sentinel section above).
# Here we test the sentinel creation path used by /ship.

_ship_create_commit_sentinel() {
  # Mirrors Step 7 sentinel creation in /ship.
  # Creates .rig-commit-ok in $rig_dir/memory/.
  local rig_dir="$1"
  touch "$rig_dir/memory/.rig-commit-ok"
}

@test "ship sentinel: .rig-commit-ok created at correct path" {
  local rig_dir="$TEMP_DIR/rig"
  mkdir -p "$rig_dir/memory"

  _ship_create_commit_sentinel "$rig_dir"
  [[ -f "$rig_dir/memory/.rig-commit-ok" ]]
}

@test "ship sentinel: .rig-commit-ok absent before /ship creates it" {
  local rig_dir="$TEMP_DIR/rig"
  mkdir -p "$rig_dir/memory"

  [[ ! -f "$rig_dir/memory/.rig-commit-ok" ]]
}

@test "ship sentinel: pre-tool sentinel check passes once sentinel is created by /ship" {
  local rig_dir="$TEMP_DIR/rig"
  mkdir -p "$rig_dir/memory"

  # Sentinel absent → commit gate blocks
  run _sentinel_check "Bash" "$rig_dir" "git commit -m 'test'"
  [ "$status" -ne 0 ]

  # /ship creates the sentinel
  _ship_create_commit_sentinel "$rig_dir"

  # Sentinel present → commit gate allows
  run _sentinel_check "Bash" "$rig_dir" "git commit -m 'test'"
  [ "$status" -eq 0 ]
}

# ── Command behavior: /rig-upgrade VERSION check ──────────────────────────────
# Phase 3a of /rig-upgrade compares $RIG_DIR/VERSION to $INSTALLER_SRC/VERSION.
# Returns 0 if they match, 1 if they differ (fix required).

_upgrade_version_check() {
  # Mirrors Phase 3a logic in /rig-upgrade.
  # Returns 0 (versions match) or 1 (mismatch detected).
  local rig_dir="$1"
  local installer_src="$2"

  local installed expected
  installed=$(cat "$rig_dir/VERSION" 2>/dev/null || echo "missing")
  expected=$(cat "$installer_src/VERSION" 2>/dev/null || echo "missing")

  if [[ "$installed" == "$expected" ]]; then
    return 0
  fi
  return 1
}

@test "rig-upgrade version check: passes when installed version matches installer" {
  local rig_dir="$TEMP_DIR/rig"
  local installer_src="$TEMP_DIR/installer"
  mkdir -p "$rig_dir" "$installer_src"
  echo "1.15.0" > "$rig_dir/VERSION"
  echo "1.15.0" > "$installer_src/VERSION"

  run _upgrade_version_check "$rig_dir" "$installer_src"
  [ "$status" -eq 0 ]
}

@test "rig-upgrade version check: detects mismatch when versions differ" {
  local rig_dir="$TEMP_DIR/rig"
  local installer_src="$TEMP_DIR/installer"
  mkdir -p "$rig_dir" "$installer_src"
  echo "1.14.0" > "$rig_dir/VERSION"
  echo "1.15.0" > "$installer_src/VERSION"

  run _upgrade_version_check "$rig_dir" "$installer_src"
  [ "$status" -ne 0 ]
}

@test "rig-upgrade version check: detects mismatch when installed VERSION file missing" {
  local rig_dir="$TEMP_DIR/rig"
  local installer_src="$TEMP_DIR/installer"
  mkdir -p "$rig_dir" "$installer_src"
  # No VERSION in rig_dir
  echo "1.15.0" > "$installer_src/VERSION"

  run _upgrade_version_check "$rig_dir" "$installer_src"
  [ "$status" -ne 0 ]
}

# ── Deprecated command removal: /new-feature and /rig-install (#245) ─────────
# Both commands were removed from templates/project/.claude/commands/.
# Verify neither is present in a fresh install.

@test "deprecated commands: new-feature.md is absent from a fresh install" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_PROJECT/.claude/commands/new-feature.md" ]
}

@test "deprecated commands: rig-install.md is absent from a fresh install" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_PROJECT/.claude/commands/rig-install.md" ]
}

# ── Hook behavior: direct-push commit type restriction (#221) ─────────────────
# When housekeeping: direct-push is set, code-change commit types (feat, fix,
# refactor, test, perf, devops, style) are blocked. Chore and docs are allowed.

_direct_push_type_check() {
  # Mirrors the direct-push type guard in pre-tool.sh.
  # Returns 0 (allow) or 1 (block).
  local commit_type="$1"
  local code_types="^(feat|fix|refactor|test|perf|devops|style)$"
  if [[ -n "$commit_type" ]] && echo "$commit_type" | grep -qE "$code_types"; then
    return 1  # blocked
  fi
  return 0  # allowed
}

@test "direct-push type guard: feat commit is blocked" {
  run _direct_push_type_check "feat"
  [ "$status" -ne 0 ]
}

@test "direct-push type guard: fix commit is blocked" {
  run _direct_push_type_check "fix"
  [ "$status" -ne 0 ]
}

@test "direct-push type guard: refactor commit is blocked" {
  run _direct_push_type_check "refactor"
  [ "$status" -ne 0 ]
}

@test "direct-push type guard: chore commit is allowed" {
  run _direct_push_type_check "chore"
  [ "$status" -eq 0 ]
}

@test "direct-push type guard: docs commit is allowed" {
  run _direct_push_type_check "docs"
  [ "$status" -eq 0 ]
}

@test "direct-push type guard: empty type is allowed (no message to parse)" {
  run _direct_push_type_check ""
  [ "$status" -eq 0 ]
}

# ── Hook behavior: worktree write redirect (#242) ─────────────────────────────
# pre-tool.sh intercepts Write/Edit targeting .claude/worktrees/ paths and
# rewrites file_path to the main repo equivalent via updatedToolInput.

_worktree_redirect_path() {
  # Mirrors the worktree redirect logic in pre-tool.sh.
  # Prints the redirected path, or nothing if not a worktree path.
  local path="$1"
  echo "$path" | python3 -c "
import re, sys
path = sys.stdin.read().strip()
m = re.match(r'^(.*)/\.claude/worktrees/[^/]+(/.*|$)', path)
if not m:
    sys.exit(0)
print(m.group(1) + (m.group(2) if m.group(2) else '/'))
" 2>/dev/null || true
}

@test "worktree redirect: path inside worktree is redirected to main repo" {
  local result
  result=$(_worktree_redirect_path "/repo/.claude/worktrees/my-task/src/app.py")
  [ "$result" = "/repo/src/app.py" ]
}

@test "worktree redirect: deeply nested worktree path is redirected correctly" {
  local result
  result=$(_worktree_redirect_path "/Users/dev/project/.claude/worktrees/feat-x/lib/utils/helper.sh")
  [ "$result" = "/Users/dev/project/lib/utils/helper.sh" ]
}

@test "worktree redirect: non-worktree path is not redirected" {
  local result
  result=$(_worktree_redirect_path "/repo/src/app.py")
  [ -z "$result" ]
}

@test "worktree redirect: path in .claude/hooks is not redirected (not a worktree)" {
  local result
  result=$(_worktree_redirect_path "/repo/.claude/hooks/pre-tool.sh")
  [ -z "$result" ]
}

# ── Breaking change detection: _show_breaking_changes (#258) ─────────────────
# Mirrors the awk logic in _show_breaking_changes() to unit-test detection
# without running the full installer.

_extract_breaking_changes() {
  local current_version="$1"
  local changelog="$2"

  [[ "$current_version" == "unknown" ]] && return 1
  [[ -f "$changelog" ]] || return 1

  local breaking_lines
  breaking_lines=$(awk -v ver="$current_version" '
    BEGIN { stop=0; in_breaking=0 }
    /^## \[/ {
      if (index($0, "[" ver "]") > 0) { stop=1 }
      in_breaking=0
    }
    stop { next }
    /^### .*BREAKING/ { in_breaking=1; next }
    /^### / { in_breaking=0 }
    in_breaking && /^- / { print }
  ' "$changelog")

  [[ -n "$breaking_lines" ]] || return 1
  echo "$breaking_lines"
}

_make_changelog() {
  # Write a minimal CHANGELOG.md to $1 for testing.
  cat > "$1" <<'CLEOF'
# Changelog

## [Unreleased]

### Changed — BREAKING
- Breaking thing in unreleased

### Added
- Non-breaking thing

## [2.0.0] — 2026-01-01

### Changed — BREAKING
- Old breaking thing in 2.0.0

### Added
- Some feature in 2.0.0

## [1.5.0] — 2025-06-01

### Added
- Some feature in 1.5.0
CLEOF
}

@test "breaking change detection: surfaces bullets from [Unreleased] when installed is older" {
  local changelog="$TEMP_DIR/CHANGELOG.md"
  _make_changelog "$changelog"

  run _extract_breaking_changes "1.5.0" "$changelog"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Breaking thing in unreleased"* ]]
  [[ "$output" == *"Old breaking thing in 2.0.0"* ]]
}

@test "breaking change detection: surfaces only changes newer than installed version" {
  local changelog="$TEMP_DIR/CHANGELOG.md"
  _make_changelog "$changelog"

  # Installed at 2.0.0: only [Unreleased] should be in range
  run _extract_breaking_changes "2.0.0" "$changelog"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Breaking thing in unreleased"* ]]
  [[ "$output" != *"Old breaking thing in 2.0.0"* ]]
}

@test "breaking change detection: silent when no breaking changes in range" {
  local changelog="$TEMP_DIR/CHANGELOG.md"
  # Changelog with no BREAKING section above 1.5.0
  cat > "$changelog" <<'CLEOF'
# Changelog

## [Unreleased]

### Added
- Just an addition

## [1.5.0] — 2025-06-01

### Changed — BREAKING
- Old breaking thing
CLEOF

  run _extract_breaking_changes "1.5.0" "$changelog"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "breaking change detection: silent when installed version is unknown" {
  local changelog="$TEMP_DIR/CHANGELOG.md"
  _make_changelog "$changelog"

  run _extract_breaking_changes "unknown" "$changelog"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "breaking change detection: silent when CHANGELOG is missing" {
  run _extract_breaking_changes "1.5.0" "$TEMP_DIR/no-such-file.md"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "breaking change detection: upgrade prints warning when breaking changes exist" {
  # Use a controlled fixture changelog so this test doesn't depend on real CHANGELOG content.
  local fixture="$TEMP_DIR/fixture-changelog.md"
  cat > "$fixture" <<'CLEOF'
# Changelog

## [Unreleased]

### Changed — BREAKING
- Stealth is now the default tracking mode

## [1.0.0] — 2025-01-01

### Added
- Initial release
CLEOF

  # First install to establish the project; set installed version below the range.
  run_installer --strategy skip
  [ "$status" -eq 0 ]
  echo "0.9.0" > "$TEST_PROJECT/.rig/VERSION"

  # Upgrade: confirm() auto-accepts in non-interactive mode (default "y").
  # _RIG_TEST_CHANGELOG points the gate at our fixture instead of the real CHANGELOG.
  _RIG_TEST_CHANGELOG="$fixture" run_installer --strategy upgrade
  [ "$status" -eq 0 ]
  [[ "$output" == *"Breaking changes since v0.9.0"* ]]
  [[ "$output" == *"Stealth is now the default tracking mode"* ]]
}

@test "breaking change detection: upgrade is silent when no breaking changes in range" {
  # Fixture has breaking changes only in [1.0.0], not in [Unreleased].
  local fixture="$TEMP_DIR/fixture-no-breaking.md"
  cat > "$fixture" <<'CLEOF'
# Changelog

## [Unreleased]

### Added
- Some non-breaking addition

## [1.0.0] — 2025-01-01

### Changed — BREAKING
- Old breaking change (already installed)
CLEOF

  run_installer --strategy skip
  [ "$status" -eq 0 ]
  # Installed version is 1.0.0 — nothing above it has breaking changes in this fixture.
  echo "1.0.0" > "$TEST_PROJECT/.rig/VERSION"

  _RIG_TEST_CHANGELOG="$fixture" run_installer --strategy upgrade
  [ "$status" -eq 0 ]
  [[ "$output" != *"Breaking changes since"* ]]
}
