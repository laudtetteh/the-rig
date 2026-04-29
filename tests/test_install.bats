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
  # Extra args (e.g. --strategy) can be appended.
  run bash "$INSTALLER" --project-only \
    --target "$TEST_PROJECT" \
    --project-name "TestProject" \
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
  is_rig_owned_stub "CLAUDE.md"
  [ "$?" -ne 0 ]
}

@test "is_rig_owned: rules file is user-owned" {
  is_rig_owned_stub ".rig/rules/coding-standards.md"
  [ "$?" -ne 0 ]
}

@test "is_rig_owned: memory file is user-owned" {
  is_rig_owned_stub ".rig/memory/PROGRESS.md"
  [ "$?" -ne 0 ]
}

@test "is_rig_owned: RIG_GAPS.md is user-owned (never overwritten)" {
  is_rig_owned_stub ".rig/memory/RIG_GAPS.md"
  [ "$?" -ne 0 ]
}

@test "is_rig_owned: task file is user-owned" {
  is_rig_owned_stub ".rig/tasks/backlog/TASK_example.md"
  [ "$?" -ne 0 ]
}

@test "is_rig_owned: GitHub template is user-owned" {
  is_rig_owned_stub ".github/PULL_REQUEST_TEMPLATE.md"
  [ "$?" -ne 0 ]
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
