#!/usr/bin/env bats
#
# tests/test_install_b.bats — Integration tests for install.sh (shard b)
#
# One of five files (test_install_a.bats .. test_install_e.bats) mechanically
# split from the original tests/test_install.bats (259 tests in one file,
# ~39% of the whole suite) for CI parallelism -- see
# .rig/memory/CI_PERFORMANCE_AUDIT_2026-08-09.md and issue #505. Each file is
# a pure move of complete, unmodified @test blocks along the original file's
# own "# ── section ───" boundaries -- no test content changed. setup(),
# teardown(), run_installer(), and two helpers that were called from outside
# their originally-defining section (_sentinel_check, _sha256) are
# duplicated identically into every file's header so each remains fully
# self-contained and independently runnable.
#
# Run with: bats tests/test_install_b.bats
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


# Hoisted into every split file's shared header -- _sentinel_check() is called
# from outside the section that originally defined it in test_install.bats.
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

# Hoisted into every split file's shared header -- _sha256() is called
# from outside the section that originally defined it in test_install.bats.
_sha256() {
  sha256sum "$1" 2>/dev/null | awk '{print $1}' || shasum -a 256 "$1" | awk '{print $1}'
}

# ── the actual #140/#470 precondition: no manifest entry at all ──────────────
# Every existing "never overwrites user-owned files" test above first runs an
# install/upgrade that WRITES a manifest entry for CLAUDE.md, then tests the
# "customized, differs from that recorded baseline" scenario. None of them
# reproduce the actual precondition that caused real, undetected data loss on
# real projects (docs/lessons-learned.md #14): a user-owned file with a real,
# pre-existing value and *zero* manifest entry at all — e.g. a project that
# predates manifest tracking for this file, or an old install never
# re-upgraded since. This precondition went completely untested from the
# original #140 fix (May 2026) until this test was added — the fix commit
# itself added no test (`git show 28b8756 -- tests/` is empty).
_seed_untracked_user_owned_file() {
  # A fresh project with real, hand-written CLAUDE.md content and no .rig/
  # manifest of any kind — reproduces "no manifest entry" without depending
  # on any prior installer run.
  printf 'MY REAL PROJECT-SPECIFIC CONTENT, WRITTEN BY HAND\n' > "$TEST_PROJECT/CLAUDE.md"
}

@test "merge strategy: never overwrites a user-owned file with no manifest entry" {
  _seed_untracked_user_owned_file
  run_installer --strategy merge
  [ "$status" -eq 0 ]
  grep -q "MY REAL PROJECT-SPECIFIC CONTENT" "$TEST_PROJECT/CLAUDE.md"
}

@test "overwrite strategy: never silently overwrites a user-owned file with no manifest entry (issue #470)" {
  _seed_untracked_user_owned_file
  run_installer --strategy overwrite
  [ "$status" -eq 0 ]
  grep -q "MY REAL PROJECT-SPECIFIC CONTENT" "$TEST_PROJECT/CLAUDE.md"
}

@test "upgrade strategy: never overwrites a user-owned file with no manifest entry (issue #140 precondition)" {
  _seed_untracked_user_owned_file
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]
  grep -q "MY REAL PROJECT-SPECIFIC CONTENT" "$TEST_PROJECT/CLAUDE.md"
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

@test "prompt-submit.sh: contains permission nudge logic" {
  local f="$REPO_ROOT/templates/project/.claude/hooks/prompt-submit.sh"
  grep -q "NUDGE_FLAG" "$f"
  grep -q "fewer-permission-prompts" "$f"
  grep -q "permission-nudge-offered" "$f"
  # Fast path must check nudge flag so it exits before building WARNINGS
  grep -q 'NUDGE_FLAG' "$f"
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

@test "post-compact: outputs systemMessage JSON when checkpoint exists" {
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
assert 'systemMessage' in d
assert 'test-branch' in d['systemMessage']
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
ctx = d['systemMessage']
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
  if grep -q '"SubagentStart"' "$tmpdir/.claude/settings.json"; then return 1; fi
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

# ── UUID-based session anchor in write_minimal_checkpoint ────────────────────

@test "stop.sh (SessionEnd): write_minimal_checkpoint omits session name when sentinel absent" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]

  local rig_dir="$TEST_PROJECT/.rig"
  local stop_hook="$TEST_PROJECT/.claude/hooks/stop.sh"
  local session_log="$TEMP_DIR/the-rig-session-test.log"

  # Snapshot has a name belonging to a sibling session
  printf '**Last updated:** 2026-01-01\n**Session name:** sibling-session-name\n\n---\n' \
    > "$rig_dir/memory/CONTEXT_SNAPSHOT.md"
  printf '[10:00:00] PROGRESS stub: abc1234 feat(x): first [#1]\n' >> "$session_log"
  printf '[10:01:00] PROGRESS stub: def5678 feat(x): second [#1]\n' >> "$session_log"
  rm -f "$rig_dir/memory/.snapshot-write-in-progress"

  # No UUID sentinel — no anchor should appear
  echo '{"source": "logout"}' \
    | ( cd "$TEST_PROJECT" && RIG_SESSION_LOG="$session_log" bash "$stop_hook" )

  # Sibling's session name must NOT appear in the checkpoint
  run grep "sibling-session-name" "$rig_dir/memory/CONTEXT_SNAPSHOT.md"
  [ "$status" -ne 0 ]
}

@test "stop.sh (SessionEnd): write_minimal_checkpoint writes session anchor from UUID sentinel" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]

  local rig_dir="$TEST_PROJECT/.rig"
  local stop_hook="$TEST_PROJECT/.claude/hooks/stop.sh"
  local session_log="$TEMP_DIR/the-rig-session-test.log"

  printf '**Last updated:** 2026-01-01\n\n---\n' \
    > "$rig_dir/memory/CONTEXT_SNAPSHOT.md"
  printf '[10:00:00] PROGRESS stub: abc1234 feat(x): first [#1]\n' >> "$session_log"
  printf '[10:01:00] PROGRESS stub: def5678 feat(x): second [#1]\n' >> "$session_log"
  rm -f "$rig_dir/memory/.snapshot-write-in-progress"

  # Run via bash -c so $$ inside = PPID seen by stop.sh
  local test_project="$TEST_PROJECT"
  bash -c "
    printf '%s' 'anchor-uuid-test' > \"/tmp/.rig-session-\$\$.uuid\"
    cd \"$test_project\"
    echo '{\"source\": \"logout\"}' \
      | RIG_SESSION_LOG=\"$session_log\" bash \"$stop_hook\"
    rm -f \"/tmp/.rig-session-\$\$.uuid\" 2>/dev/null
  "

  # Session anchor must appear in the checkpoint
  grep -q "anchor-uuid-test" "$rig_dir/memory/CONTEXT_SNAPSHOT.md"
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

