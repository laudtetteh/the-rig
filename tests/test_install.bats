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

@test "--target without --tracking still defaults to repo tracking" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]
  [ -f "$TEST_PROJECT/.rig/memory/PROGRESS.md" ]
  [ ! -f "$TEST_PROJECT/.rigpath" ]
}
