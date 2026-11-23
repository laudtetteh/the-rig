#!/usr/bin/env bats
#
# tests/test_permission_scope.bats — Scope of PermissionRequest auto-approval
# and protection of files that Rig hooks source (issue #675).
#
# Run with: bats tests/test_permission_scope.bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TEST_ROOT="$(mktemp -d)"
  TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)"
  TEST_PROJECT="$TEST_ROOT/project"
  RIG_DIR="$TEST_PROJECT/.rig"
  export HOME="$TEST_ROOT/home"
  mkdir -p "$HOME" "$TEST_PROJECT/.claude/hooks" "$TEST_PROJECT/.codex/hooks" \
    "$RIG_DIR/memory" "$RIG_DIR/tasks/active" "$RIG_DIR/docs" "$RIG_DIR/rules" \
    "$RIG_DIR/processes"
  git -C "$TEST_PROJECT" init -q
  git -C "$TEST_PROJECT" config user.email test@example.com
  git -C "$TEST_PROJECT" config user.name "Test User"
  git -C "$TEST_PROJECT" commit --allow-empty -m initial -q

  local hook
  for hook in permission-request.sh pre-tool.sh; do
    cp "$REPO_ROOT/templates/project/.claude/hooks/$hook" "$TEST_PROJECT/.claude/hooks/$hook"
  done
  mkdir -p "$TEST_PROJECT/bin"
  cp "$REPO_ROOT/templates/project/bin/rig-path.py" "$TEST_PROJECT/bin/rig-path.py"
  cp "$REPO_ROOT/templates/project/.codex/hooks/rig-adapter.sh" \
    "$TEST_PROJECT/.codex/hooks/rig-adapter.sh"
  cp "$REPO_ROOT/templates/project/.rig/contextual-tips.sh" "$RIG_DIR/contextual-tips.sh"
  cp "$REPO_ROOT/templates/project/.rig/rules/protected-paths.txt" \
    "$RIG_DIR/rules/protected-paths.txt"
  printf 'abc123  .rig/rules/protected-paths.txt\n' > "$RIG_DIR/memory/.rig-manifest"
}

teardown() {
  rm -rf "$TEST_ROOT"
}

# Pipe a PermissionRequest payload into the installed Claude hook.
perm_request() {
  local tool="$1" key="$2" value="$3" payload
  payload=$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PermissionRequest","tool_name":sys.argv[1],"tool_input":{sys.argv[2]:sys.argv[3]}}))' "$tool" "$key" "$value")
  run bash -c 'cd "$1" && printf "%s" "$2" | bash .claude/hooks/permission-request.sh' \
    _ "$TEST_PROJECT" "$payload"
}

# Replace the policy file with an older copy that predates the
# contextual-tips.sh entry, as on an existing install with a customized policy.
write_legacy_policy() {
  printf '%s\n' '[RIG_DIR]/processes/' '[RIG_DIR]/rules/' '[REPO]/.husky/' \
    '[REPO]/CLAUDE.md' '[REPO]/.claude/hooks/' > "$RIG_DIR/rules/protected-paths.txt"
}

assert_allowed() {
  [ "$status" -eq 0 ]
  [[ "$output" == *'"behavior": "allow"'* ]] || return 1
}

assert_not_allowed() {
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "permission scope: bats test runs are not auto-approved" {
  perm_request Bash command "bats tests/example.bats"
  assert_not_allowed
}

@test "permission scope: bats chained after a read-only command is not auto-approved" {
  perm_request Bash command "git status; bats $RIG_DIR/memory/check.bats"
  assert_not_allowed
}

@test "permission scope: Codex PermissionRequest for bats is not auto-approved" {
  local payload
  payload=$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "bats tests/example.bats")
  run bash -c 'cd "$1" && printf "%s" "$2" | bash .codex/hooks/rig-adapter.sh' \
    _ "$TEST_PROJECT" "$payload"
  assert_not_allowed
}

@test "permission scope: read-only inspection is still auto-approved" {
  perm_request Bash command "git status; cat README.md"
  assert_allowed
}

@test "permission scope: Markdown notes in memory, tasks, and docs are auto-approved" {
  perm_request Write file_path "$RIG_DIR/memory/PROGRESS.md"
  assert_allowed
  perm_request Edit file_path "$RIG_DIR/tasks/active/TASK_example.md"
  assert_allowed
  perm_request Write file_path "$RIG_DIR/docs/plan.md"
  assert_allowed
}

@test "permission scope: hook-sourced catalog write is not auto-approved" {
  perm_request Write file_path "$RIG_DIR/contextual-tips.sh"
  assert_not_allowed
  perm_request Edit file_path "$RIG_DIR/contextual-tips.sh"
  assert_not_allowed
}

@test "permission scope: non-Markdown files under memory are not auto-approved" {
  local name
  for name in check.bats helper.sh session.json .rig-manifest .rig-commit-ok; do
    perm_request Write file_path "$RIG_DIR/memory/$name"
    assert_not_allowed
  done
}

@test "permission scope: hidden Markdown files under memory are not auto-approved" {
  perm_request Write file_path "$RIG_DIR/memory/.hidden.md"
  assert_not_allowed
}

@test "permission scope: Markdown outside memory, tasks, and docs is not auto-approved" {
  perm_request Write file_path "$RIG_DIR/notes.md"
  assert_not_allowed
  perm_request Write file_path "$RIG_DIR/rules/security.md"
  assert_not_allowed
  perm_request Write file_path "$RIG_DIR/processes/SHIP_WORKFLOW.md"
  assert_not_allowed
}

@test "permission scope: parent-directory segments cannot escape the allowed areas" {
  perm_request Write file_path "$RIG_DIR/memory/../contextual-tips.sh"
  assert_not_allowed
  perm_request Write file_path "$RIG_DIR/memory/../rules/security.md"
  assert_not_allowed
}

@test "permission scope: a Markdown-named symlink to another file is not auto-approved" {
  ln -s "$RIG_DIR/contextual-tips.sh" "$RIG_DIR/memory/notes.md"
  perm_request Write file_path "$RIG_DIR/memory/notes.md"
  assert_not_allowed
}

@test "permission scope: relative paths and NotebookEdit are not auto-approved" {
  perm_request Write file_path ".rig/memory/PROGRESS.md"
  assert_not_allowed
  perm_request NotebookEdit file_path "$RIG_DIR/memory/PROGRESS.md"
  assert_not_allowed
}

@test "permission scope: strict-permissions sentinel disables Markdown note approval" {
  touch "$RIG_DIR/memory/.rig-strict-permissions"
  perm_request Write file_path "$RIG_DIR/memory/PROGRESS.md"
  assert_not_allowed
}

@test "protected paths: template policy lists the hook-sourced tips catalog" {
  grep -qxF '[RIG_DIR]/contextual-tips.sh' \
    "$REPO_ROOT/templates/project/.rig/rules/protected-paths.txt"
}

@test "protected paths: PreToolUse blocks the tips catalog even with an older policy" {
  local payload
  write_legacy_policy
  payload=$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":sys.argv[1],"content":"x"}}))' "$RIG_DIR/contextual-tips.sh")
  run bash -c 'cd "$1" && printf "%s" "$2" | bash .claude/hooks/pre-tool.sh' \
    _ "$TEST_PROJECT" "$payload"
  [ "$status" -eq 2 ]
  [[ "$output" == *"governance file"* ]] || return 1
}

@test "protected paths: PreToolUse still permits Markdown notes in memory" {
  local payload
  payload=$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":sys.argv[1],"content":"x"}}))' "$RIG_DIR/memory/PROGRESS.md")
  run bash -c 'cd "$1" && printf "%s" "$2" | bash .claude/hooks/pre-tool.sh' \
    _ "$TEST_PROJECT" "$payload"
  [ "$status" -eq 0 ]
}

@test "protected paths: Codex apply_patch to the tips catalog is blocked with an older policy" {
  local payload patch
  write_legacy_policy
  patch=$'*** Begin Patch\n*** Update File: .rig/contextual-tips.sh\n@@\n-x\n+y\n*** End Patch'
  payload=$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"apply_patch","cwd":sys.argv[1],"tool_input":{"command":sys.argv[2]}}))' "$TEST_PROJECT" "$patch")
  run bash -c 'cd "$1" && printf "%s" "$2" | bash .codex/hooks/rig-adapter.sh' \
    _ "$TEST_PROJECT" "$payload"
  [ "$status" -eq 2 ]
  [[ "$output" == *"governance file"* ]] || return 1
}

# Send a PreToolUse write payload for one tool and path to the Claude hook.
pretool_write() {
  local tool="$1" path="$2" payload
  payload=$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","tool_name":sys.argv[1],"tool_input":{"file_path":sys.argv[2],"content":"x"}}))' "$tool" "$path")
  run bash -c 'cd "$1" && printf "%s" "$2" | bash .claude/hooks/pre-tool.sh' \
    _ "$TEST_PROJECT" "$payload"
}

# Send a Codex apply_patch payload that updates one project-relative path.
codex_patch() {
  local target="$1" payload patch
  patch=$'*** Begin Patch\n*** Update File: '"$target"$'\n@@\n-x\n+y\n*** End Patch'
  payload=$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"apply_patch","cwd":sys.argv[1],"tool_input":{"command":sys.argv[2]}}))' "$TEST_PROJECT" "$patch")
  run bash -c 'cd "$1" && printf "%s" "$2" | bash .codex/hooks/rig-adapter.sh' \
    _ "$TEST_PROJECT" "$payload"
}

assert_governance_block() {
  [ "$status" -eq 2 ]
  [[ "$output" == *"governance file"* ]] || return 1
}

# Case-variant aliases only exist on case-insensitive volumes (macOS default).
require_case_insensitive_fs() {
  [ -e "$RIG_DIR/RULES" ] || skip "requires a case-insensitive filesystem (#675)"
}

@test "permission scope: owner-approved conventions are not auto-approved" {
  perm_request Write file_path "$RIG_DIR/memory/PROJECT_CONVENTIONS.md"
  assert_not_allowed
  perm_request Edit file_path "$RIG_DIR/memory/project_conventions.md"
  assert_not_allowed
}

@test "permission scope: a note with an extra sync-tool hard link is still auto-approved" {
  printf 'note\n' > "$RIG_DIR/memory/PROGRESS.md"
  mkdir -p "$RIG_DIR/memory/.tmp.driveupload"
  ln "$RIG_DIR/memory/PROGRESS.md" "$RIG_DIR/memory/.tmp.driveupload/12345"
  perm_request Write file_path "$RIG_DIR/memory/PROGRESS.md"
  assert_allowed
}

@test "protected paths: MultiEdit to a protected path is blocked" {
  pretool_write MultiEdit "$RIG_DIR/rules/security.md"
  assert_governance_block
}

@test "protected paths: missing protected file is matched case-insensitively" {
  [ ! -e "$TEST_PROJECT/CLAUDE.md" ]
  pretool_write Write "$TEST_PROJECT/claude.md"
  assert_governance_block
}

@test "protected paths: hard-link alias of a protected file is blocked" {
  ln "$RIG_DIR/contextual-tips.sh" "$RIG_DIR/memory/tips-alias.sh"
  pretool_write Write "$RIG_DIR/memory/tips-alias.sh"
  assert_governance_block
}

@test "protected paths: Markdown-named hard link to a protected file is blocked" {
  ln "$RIG_DIR/contextual-tips.sh" "$RIG_DIR/memory/hl.md"
  pretool_write Write "$RIG_DIR/memory/hl.md"
  assert_governance_block
}

@test "protected paths: case variant of a protected file is blocked" {
  require_case_insensitive_fs
  pretool_write Write "$RIG_DIR/CONTEXTUAL-TIPS.SH"
  assert_governance_block
}

@test "protected paths: case variant of a protected directory is blocked" {
  require_case_insensitive_fs
  pretool_write Write "$RIG_DIR/RULES/security.md"
  assert_governance_block
}

@test "protected paths: Codex apply_patch to a missing protected file is matched case-insensitively" {
  codex_patch claude.md
  assert_governance_block
}

@test "protected paths: Codex apply_patch to case variants of protected paths is blocked" {
  require_case_insensitive_fs
  codex_patch .rig/CONTEXTUAL-TIPS.SH
  assert_governance_block
  codex_patch .rig/RULES/security.md
  assert_governance_block
}

@test "protected paths: Codex apply_patch to an unprotected Markdown note is allowed" {
  codex_patch .rig/memory/PROGRESS.md
  [ "$status" -eq 0 ]
}
