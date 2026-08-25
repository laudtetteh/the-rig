#!/usr/bin/env bats
#
# tests/test_install_e.bats — Integration tests for install.sh (shard e)
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
# Run with: bats tests/test_install_e.bats
# Install bats: brew install bats-core  (macOS)
#               apt-get install bats    (Debian/Ubuntu)
#
# These tests call install.sh with --strategy, --target, and --project-name
# flags to drive non-interactive installation into temporary directories.
# Each test is fully isolated — temp dirs are created and destroyed per test.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
INSTALLER="$REPO_ROOT/install.sh"

# ── Helpers ───────────────────────────────────────────────────────────────────

setup_file() {
  local shared_project="$BATS_FILE_TMPDIR/commit-msg-project"
  mkdir -p "$shared_project"
  git -C "$shared_project" init -q
  git -C "$shared_project" config user.email "test@test.com"
  git -C "$shared_project" config user.name "Test"
  bash "$INSTALLER" --project-only \
    --target "$shared_project" \
    --project-name "TestProject" \
    --tracking repo \
    --strategy skip >/dev/null
}

teardown_file() {
  rm -rf "$BATS_FILE_TMPDIR/commit-msg-project"
}

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

copy_shared_commit_msg_project() {
  rm -rf "$TEST_PROJECT"
  mkdir -p "$TEST_PROJECT"
  cp -R "$BATS_FILE_TMPDIR/commit-msg-project/." "$TEST_PROJECT/"
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
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# ── Fresh install — skip strategy ─────────────────────────────────────────────

@test "skip strategy: creates files that do not exist" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]
  [ -f "$TEST_PROJECT/.rig/processes/SHIP_WORKFLOW.md" ]
  [ -f "$TEST_PROJECT/.claude/hooks/pre-tool.sh" ]
  [ -f "$TEST_PROJECT/.rig/memory/RIG_GAPS.md" ]
  [ -x "$TEST_PROJECT/bin/rig" ]
  grep -q "  bin/rig$" "$TEST_PROJECT/.rig/memory/.rig-manifest"
}

@test "dispatcher: help, version, and memory validation follow the contract" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]
  run "$TEST_PROJECT/bin/rig" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"rig session resolve"* ]] || return 1
  run "$TEST_PROJECT/bin/rig" --version
  [ "$status" -eq 0 ]
  [ "$output" = "The Rig v$(cat "$REPO_ROOT/VERSION")" ]
  run "$TEST_PROJECT/bin/rig" memory validate --json
  [ "$status" -eq 0 ]
  [[ "$output" == '{"ok":true,"command":"memory validate"'* ]] || return 1
}

@test "dispatcher: stealth install excludes bin/rig and reads external version" {
  local rig_ext="$TEMP_DIR/external-rig"
  run_installer --strategy skip --tracking stealth --rig-dir "$rig_ext"
  [ "$status" -eq 0 ]
  [ -x "$TEST_PROJECT/bin/rig" ]
  grep -qx "bin/rig" "$TEST_PROJECT/.git/info/exclude"
  grep -q "  bin/rig$" "$rig_ext/memory/.rig-manifest"
  run "$TEST_PROJECT/bin/rig" version --json
  [ "$status" -eq 0 ]
  [ "$output" = "{\"version\":\"$(cat "$REPO_ROOT/VERSION")\"}" ]
}

@test "stealth install excludes every generated bin/rig* launcher, not just bin/rig" {
  local rig_ext="$TEMP_DIR/external-rig"
  run_installer --strategy skip --tracking stealth --rig-dir "$rig_ext"
  [ "$status" -eq 0 ]

  # Every file actually shipped under templates/project/bin/ must have its
  # own exact-line entry in .git/info/exclude — not merely a substring hit
  # against another entry (bin/rig is itself a substring of the other
  # three launcher names, so an exact-line check matters here).
  local launcher
  for launcher in "$REPO_ROOT/templates/project/bin/"*; do
    grep -qx "bin/$(basename "$launcher")" "$TEST_PROJECT/.git/info/exclude"
  done

  # git status must show zero untracked bin/ artifacts — this is the
  # actual zero-trace guarantee, not just presence of exclude lines.
  run git -C "$TEST_PROJECT" status --porcelain --untracked-files=all
  [ "$status" -eq 0 ]
  [[ "$output" != *"bin/rig"* ]] || return 1
}

@test "non-stealth install: bin/rig* launchers are untouched by stealth exclusion logic" {
  # Regression check: repo tracking (the default here) must never write a
  # stealth block into .git/info/exclude, and every launcher must remain
  # a plain, visible, untracked file the user is expected to git-add
  # themselves — exactly the pre-existing non-stealth behaviour.
  run_installer --strategy skip --tracking repo
  [ "$status" -eq 0 ]

  local launcher
  for launcher in "$REPO_ROOT/templates/project/bin/"*; do
    [ -f "$TEST_PROJECT/bin/$(basename "$launcher")" ]
  done

  if [ -f "$TEST_PROJECT/.git/info/exclude" ]; then
    run grep -c "The Rig — stealth mode" "$TEST_PROJECT/.git/info/exclude"
    [ "$status" -ne 0 ]
  fi

  run git -C "$TEST_PROJECT" status --porcelain --untracked-files=all
  [ "$status" -eq 0 ]
  [[ "$output" == *"?? bin/rig"* ]] || return 1
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

@test "skip strategy: installs rig-status.md command" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]
  [ -f "$TEST_PROJECT/.claude/commands/rig-status.md" ]
  grep -q "^# Command: /rig-status" "$TEST_PROJECT/.claude/commands/rig-status.md"
}

@test "skip strategy: installs protected-path policy with hooks" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]
  [ -f "$TEST_PROJECT/.rig/rules/protected-paths.txt" ]
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

_run_pre_tool_write() {
  local file_path="$1"
  local input
  input=$(printf '{"file_path":"%s"}' "$file_path")
  run bash -c 'cd "$1" && printf "%s" "$2" | RIG_SESSION_LOG="$3" bash "$4" Write' \
    _ "$TEST_PROJECT" "$input" "$TEMP_DIR/session.log" \
    "$REPO_ROOT/templates/project/.claude/hooks/pre-tool.sh"
}

_install_protected_path_policy() {
  mkdir -p "$TEST_PROJECT/.rig/rules"
  cp "$REPO_ROOT/templates/project/.rig/rules/protected-paths.txt" \
    "$TEST_PROJECT/.rig/rules/protected-paths.txt"
}

@test "path policy: real hook blocks protected target" {
  _install_protected_path_policy
  local repo_root
  repo_root=$(git -C "$TEST_PROJECT" rev-parse --show-toplevel)
  _run_pre_tool_write "$repo_root/CLAUDE.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"is a The Rig governance file"* ]] || return 1
}

@test "path policy: real hook allows unprotected target" {
  _install_protected_path_policy
  _run_pre_tool_write "$TEST_PROJECT/src/app.sh"
  [ "$status" -eq 0 ]
}

@test "path policy: real hook fails closed when policy is missing" {
  _run_pre_tool_write "$TEST_PROJECT/src/app.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"policy is missing or unreadable"* ]] || return 1
}

@test "path policy: real hook fails closed when policy is malformed" {
  mkdir -p "$TEST_PROJECT/.rig/rules"
  printf 'relative/path\n' > "$TEST_PROJECT/.rig/rules/protected-paths.txt"
  _run_pre_tool_write "$TEST_PROJECT/src/app.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"policy is malformed"* ]] || return 1
}

# ── Self-install detector ─────────────────────────────────────────────────────

@test "self-install detector: skips cleanup when install.sh is git-tracked" {
  local rig_dir="$TEMP_DIR/rig-self"
  mkdir -p "$rig_dir"
  cp "$INSTALLER" "$rig_dir/install.sh"
  cp -r "$REPO_ROOT/installer" "$rig_dir/installer"
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
  [[ "$output" != *"run from inside the target"* ]] || return 1
}

@test "self-install detector: offers cleanup when install.sh is not git-tracked" {
  local rig_dir="$TEMP_DIR/rig-self"
  mkdir -p "$rig_dir"
  cp "$INSTALLER" "$rig_dir/install.sh"
  cp -r "$REPO_ROOT/installer" "$rig_dir/installer"
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

# ── Gap 5: commit-msg validates Conventional Commits format ───────────────────

@test "commit-msg: rejects non-conventional commit message" {
  copy_shared_commit_msg_project

  local hook="$TEST_PROJECT/.husky/commit-msg"
  local msg_file="$TEMP_DIR/COMMIT_EDITMSG"

  # Overwrite CLAUDE.md with minimal content; hook only reads issue-tracking
  printf 'issue-tracking: none\n' > "$TEST_PROJECT/CLAUDE.md"

  printf 'fixed stuff\n' > "$msg_file"
  run bash -c "cd '$TEST_PROJECT' && sh '$hook' '$msg_file'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Conventional Commits"* ]] || return 1
}

@test "commit-msg: accepts valid conventional commit message" {
  copy_shared_commit_msg_project

  local hook="$TEST_PROJECT/.husky/commit-msg"
  local msg_file="$TEMP_DIR/COMMIT_EDITMSG"

  printf 'issue-tracking: none\n' > "$TEST_PROJECT/CLAUDE.md"

  printf 'feat(auth): add login flow\n' > "$msg_file"
  run bash -c "cd '$TEST_PROJECT' && sh '$hook' '$msg_file'"
  [ "$status" -eq 0 ]
}

@test "commit-msg: rejects message missing issue ref when issue-tracking: github" {
  copy_shared_commit_msg_project

  local hook="$TEST_PROJECT/.husky/commit-msg"
  local msg_file="$TEMP_DIR/COMMIT_EDITMSG"

  # Overwrite with controlled minimal content so first grep match is github
  printf 'issue-tracking: github\n' > "$TEST_PROJECT/CLAUDE.md"

  printf 'feat(auth): add login flow\n' > "$msg_file"
  run bash -c "cd '$TEST_PROJECT' && sh '$hook' '$msg_file'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"issue reference"* ]] || return 1
}

@test "commit-msg: accepts message with [#N] issue ref when issue-tracking: github" {
  copy_shared_commit_msg_project

  local hook="$TEST_PROJECT/.husky/commit-msg"
  local msg_file="$TEMP_DIR/COMMIT_EDITMSG"

  printf 'issue-tracking: github\n' > "$TEST_PROJECT/CLAUDE.md"

  printf 'feat(auth): add login flow [#42]\n' > "$msg_file"
  run bash -c "cd '$TEST_PROJECT' && sh '$hook' '$msg_file'"
  [ "$status" -eq 0 ]
}

@test "commit-msg: skips validation for merge commits" {
  copy_shared_commit_msg_project

  local hook="$TEST_PROJECT/.husky/commit-msg"
  local msg_file="$TEMP_DIR/COMMIT_EDITMSG"

  printf 'issue-tracking: github\n' > "$TEST_PROJECT/CLAUDE.md"

  printf "Merge branch 'feat/foo' into main\n" > "$msg_file"
  run bash -c "cd '$TEST_PROJECT' && sh '$hook' '$msg_file'"
  [ "$status" -eq 0 ]
}

@test "commit-msg: bypass with SKIP_COMMIT_VALIDATION=1" {
  copy_shared_commit_msg_project

  local hook="$TEST_PROJECT/.husky/commit-msg"
  local msg_file="$TEMP_DIR/COMMIT_EDITMSG"

  printf 'this is not conventional\n' > "$msg_file"
  run bash -c "cd '$TEST_PROJECT' && SKIP_COMMIT_VALIDATION=1 sh '$hook' '$msg_file'"
  [ "$status" -eq 0 ]
}

@test "commit-msg: rejects message missing Linear ref when issue-tracking: linear" {
  copy_shared_commit_msg_project

  local hook="$TEST_PROJECT/.husky/commit-msg"
  local msg_file="$TEMP_DIR/COMMIT_EDITMSG"

  printf 'issue-tracking: linear\n' > "$TEST_PROJECT/CLAUDE.md"

  printf 'feat(auth): add login flow\n' > "$msg_file"
  run bash -c "cd '$TEST_PROJECT' && sh '$hook' '$msg_file'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Linear"* ]] || return 1
}

@test "commit-msg: accepts message with Linear ref when issue-tracking: linear" {
  copy_shared_commit_msg_project

  local hook="$TEST_PROJECT/.husky/commit-msg"
  local msg_file="$TEMP_DIR/COMMIT_EDITMSG"

  printf 'issue-tracking: linear\n' > "$TEST_PROJECT/CLAUDE.md"

  printf 'feat(auth): add login flow [ENG-123]\n' > "$msg_file"
  run bash -c "cd '$TEST_PROJECT' && sh '$hook' '$msg_file'"
  [ "$status" -eq 0 ]
}

@test "commit-msg: rejects message missing Trello ref when issue-tracking: trello" {
  copy_shared_commit_msg_project

  local hook="$TEST_PROJECT/.husky/commit-msg"
  local msg_file="$TEMP_DIR/COMMIT_EDITMSG"

  printf 'issue-tracking: trello\n' > "$TEST_PROJECT/CLAUDE.md"

  printf 'feat(auth): add login flow\n' > "$msg_file"
  run bash -c "cd '$TEST_PROJECT' && sh '$hook' '$msg_file'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Trello"* ]] || return 1
}

@test "commit-msg: accepts message with Trello ref when issue-tracking: trello" {
  copy_shared_commit_msg_project

  local hook="$TEST_PROJECT/.husky/commit-msg"
  local msg_file="$TEMP_DIR/COMMIT_EDITMSG"

  printf 'issue-tracking: trello\n' > "$TEST_PROJECT/CLAUDE.md"

  printf 'feat(auth): add login flow [trello:abc123]\n' > "$msg_file"
  run bash -c "cd '$TEST_PROJECT' && sh '$hook' '$msg_file'"
  [ "$status" -eq 0 ]
}

@test "commit-msg: rejects message missing GUS ref when issue-tracking: gus" {
  copy_shared_commit_msg_project

  local hook="$TEST_PROJECT/.husky/commit-msg"
  local msg_file="$TEMP_DIR/COMMIT_EDITMSG"

  printf 'issue-tracking: gus\n' > "$TEST_PROJECT/CLAUDE.md"

  printf 'feat(auth): add login flow\n' > "$msg_file"
  run bash -c "cd '$TEST_PROJECT' && sh '$hook' '$msg_file'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"GUS"* ]] || return 1
}

@test "commit-msg: accepts message with GUS ref when issue-tracking: gus" {
  copy_shared_commit_msg_project

  local hook="$TEST_PROJECT/.husky/commit-msg"
  local msg_file="$TEMP_DIR/COMMIT_EDITMSG"

  printf 'issue-tracking: gus\n' > "$TEST_PROJECT/CLAUDE.md"

  printf 'feat(auth): add login flow [W-1234567]\n' > "$msg_file"
  run bash -c "cd '$TEST_PROJECT' && sh '$hook' '$msg_file'"
  [ "$status" -eq 0 ]
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
    in_breaking && /^- / { print; next }
    in_breaking && /^  / { print }
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
  [[ "$output" == *"Breaking thing in unreleased"* ]] || return 1
  [[ "$output" == *"Old breaking thing in 2.0.0"* ]] || return 1
}

@test "breaking change detection: surfaces only changes newer than installed version" {
  local changelog="$TEMP_DIR/CHANGELOG.md"
  _make_changelog "$changelog"

  # Installed at 2.0.0: only [Unreleased] should be in range
  run _extract_breaking_changes "2.0.0" "$changelog"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Breaking thing in unreleased"* ]] || return 1
  [[ "$output" != *"Old breaking thing in 2.0.0"* ]] || return 1
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
  [[ "$output" == *"Breaking changes since v0.9.0"* ]] || return 1
  [[ "$output" == *"Stealth is now the default tracking mode"* ]] || return 1
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
  [[ "$output" != *"Breaking changes since"* ]] || return 1
}

@test "breaking change detection: multi-line bullet's indented continuation lines are not truncated to the first line (#481)" {
  local changelog="$TEMP_DIR/CHANGELOG.md"
  cat > "$changelog" <<'CLEOF'
# Changelog

## [Unreleased]

### Changed — BREAKING
- Default install tracking mode changed to stealth: the interactive
  prompt now defaults to option 4 (stealth) instead of option 1 (in-repo). All Rig
  files are stored in the external tracking dir by default — no `.rig/` is committed
  to the project repo. Users who prefer in-repo tracking must choose option 1 explicitly
  or pass `--tracking repo`. This affects all fresh installs where no `--tracking` flag
  is provided.

## [1.0.0] — 2025-01-01

### Added
- Initial release
CLEOF

  run _extract_breaking_changes "1.0.0" "$changelog"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Default install tracking mode changed to stealth"* ]] || return 1
  [[ "$output" == *"prompt now defaults to option 4 (stealth) instead of option 1 (in-repo)"* ]] || return 1
  [[ "$output" == *"files are stored in the external tracking dir by default"* ]] || return 1
  [[ "$output" == *"to the project repo. Users who prefer in-repo tracking"* ]] || return 1
  [[ "$output" == *"or pass \`--tracking repo\`. This affects all fresh installs"* ]] || return 1
  [[ "$output" == *"is provided."* ]] || return 1
}

@test "breaking change detection: upgrade prints every continuation line of a multi-line breaking bullet, not just the first (#481)" {
  local fixture="$TEMP_DIR/fixture-multiline-breaking.md"
  cat > "$fixture" <<'CLEOF'
# Changelog

## [Unreleased]

### Changed — BREAKING
- Default install tracking mode changed to stealth: the interactive
  prompt now defaults to option 4 (stealth) instead of option 1 (in-repo). All Rig
  files are stored in the external tracking dir by default — no `.rig/` is committed
  to the project repo.

## [1.0.0] — 2025-01-01

### Added
- Initial release
CLEOF

  run_installer --strategy skip
  [ "$status" -eq 0 ]
  echo "1.0.0" > "$TEST_PROJECT/.rig/VERSION"

  _RIG_TEST_CHANGELOG="$fixture" run_installer --strategy upgrade
  [ "$status" -eq 0 ]
  [[ "$output" == *"Default install tracking mode changed to stealth"* ]] || return 1
  [[ "$output" == *"prompt now defaults to option 4 (stealth) instead of option 1 (in-repo)"* ]] || return 1
  [[ "$output" == *"files are stored in the external tracking dir by default"* ]] || return 1
  [[ "$output" == *"to the project repo."* ]] || return 1
}
