#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TEST_ROOT="$(mktemp -d)"
  TEST_PROJECT="$TEST_ROOT/project"
  mkdir -p "$TEST_PROJECT/.claude/hooks" "$TEST_PROJECT/.codex/hooks" \
    "$TEST_PROJECT/.rig/memory/sessions" "$TEST_PROJECT/.rig/rules"
  TEST_PROJECT="$(cd "$TEST_PROJECT" && pwd -P)"
  git -C "$TEST_PROJECT" init -q
  git -C "$TEST_PROJECT" commit --allow-empty -m initial -q

  cp "$REPO_ROOT/templates/project/.claude/hooks/pre-tool.sh" \
    "$TEST_PROJECT/.claude/hooks/pre-tool.sh"
  cp "$REPO_ROOT/templates/project/.claude/hooks/post-tool.sh" \
    "$TEST_PROJECT/.claude/hooks/post-tool.sh"
  cp "$REPO_ROOT/templates/project/.claude/hooks/session-start.sh" \
    "$TEST_PROJECT/.claude/hooks/session-start.sh"
  cp "$REPO_ROOT/templates/project/.codex/hooks/rig-adapter.sh" \
    "$TEST_PROJECT/.codex/hooks/rig-adapter.sh"
  mkdir -p "$TEST_PROJECT/bin"
  cp "$REPO_ROOT/templates/project/bin/rig" "$TEST_PROJECT/bin/rig"
  cp "$REPO_ROOT/templates/project/bin/rig-session-resolve.py" "$TEST_PROJECT/bin/rig-session-resolve.py"
  chmod +x "$TEST_PROJECT/bin/rig"
  cp "$REPO_ROOT/templates/project/.rig/rules/protected-paths.txt" \
    "$TEST_PROJECT/.rig/rules/protected-paths.txt"
  printf 'abc123  .rig/rules/protected-paths.txt\n' \
    > "$TEST_PROJECT/.rig/memory/.rig-manifest"
  printf '# Parity snapshot\nshared context\n' \
    > "$TEST_PROJECT/.rig/memory/CONTEXT_SNAPSHOT.md"
  DIRECT_SESSION_PID="$$"
  CODEX_SESSION_PID="$(( $$ + 1 ))"
}

teardown() {
  rm -rf "$TEST_ROOT"
  rm -f "/tmp/.rig-session-${DIRECT_SESSION_PID}.uuid" \
    "/tmp/.rig-session-${CODEX_SESSION_PID}.uuid"
}

run_claude_pretool() {
  local tool="$1" payload="$2"
  run bash -c 'cd "$1" && printf "%s" "$3" | bash .claude/hooks/pre-tool.sh "$2"' \
    _ "$TEST_PROJECT" "$tool" "$payload"
}

run_claude_pretool_from_settings() {
  local payload="$1"
  run bash -c 'cd "$1" && printf "%s" "$2" | bash .claude/hooks/pre-tool.sh' \
    _ "$TEST_PROJECT" "$payload"
}

setup_linked_hook_worktrees() {
  git -C "$TEST_PROJECT" checkout -q -B main
  LINKED_FEATURE="$TEST_ROOT/feature-worktree"
  git -C "$TEST_PROJECT" worktree add -q -b feature/hook-check "$LINKED_FEATURE"
  mkdir -p "$LINKED_FEATURE/.claude/hooks" "$LINKED_FEATURE/.rig/rules" \
    "$LINKED_FEATURE/.rig/memory"
  cp "$TEST_PROJECT/.claude/hooks/pre-tool.sh" "$LINKED_FEATURE/.claude/hooks/pre-tool.sh"
  cp "$TEST_PROJECT/.rig/rules/protected-paths.txt" "$LINKED_FEATURE/.rig/rules/protected-paths.txt"
}

run_linked_pretool() {
  local payload="$1"
  run bash -c 'cd "$1" && printf "%s" "$2" | bash .claude/hooks/pre-tool.sh' \
    _ "$LINKED_FEATURE" "$payload"
}

run_codex_adapter() {
  local payload="$1"
  run bash -c 'cd "$1" && printf "%s" "$2" | bash .codex/hooks/rig-adapter.sh' \
    _ "$TEST_PROJECT" "$payload"
}

install_runtime_git_hook() {
  local layout="${1:-native}" hook_dir
  if [ "$layout" = husky ]; then
    hook_dir="$TEST_PROJECT/.husky"
    mkdir -p "$hook_dir"
    git -C "$TEST_PROJECT" config core.hooksPath .husky
  else
    hook_dir="$TEST_PROJECT/.git/hooks"
  fi
  cp "$REPO_ROOT/templates/project/.husky/commit-msg" "$hook_dir/commit-msg"
  cp "$REPO_ROOT/templates/project/.husky/filter-commit-message-inplace.sh" "$hook_dir/filter-commit-message-inplace.sh"
  chmod +x "$hook_dir/commit-msg"
}

bash_payload() {
  python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"Bash","cwd":sys.argv[1],"tool_input":{"command":sys.argv[2]}}))' "$1" "$2"
}

@test "normal Claude PreToolUse Edit denies a protected path with blocking exit 2" {
  payload="$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":sys.argv[1],"old_string":"old","new_string":"new"}}))' "$TEST_PROJECT/CLAUDE.md")"
  run_claude_pretool_from_settings "$payload"
  [ "$status" -eq 2 ]
  [[ "$output" == *"governance file"* ]] || return 1
}

@test "normal Claude PreToolUse NotebookEdit checks notebook_path" {
  payload="$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"NotebookEdit","tool_input":{"notebook_path":sys.argv[1],"cell_number":0,"new_source":"unsafe"}}))' "$TEST_PROJECT/CLAUDE.md")"
  run_claude_pretool_from_settings "$payload"
  [ "$status" -eq 2 ]
  [[ "$output" == *"governance file"* ]] || return 1
}

@test "native Bash hook blocks plain unmarked commit even with approval" {
  touch "$TEST_PROJECT/.rig/memory/.rig-commit-ok"
  payload='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git commit -m \"fix: example\""}}'
  run_claude_pretool_from_settings "$payload"
  [ "$status" -eq 2 ]
  [[ "$output" == *'Commit blocked by The Rig'* ]] || return 1
  [ -f "$TEST_PROJECT/.rig/memory/.rig-commit-ok" ]
  install_runtime_git_hook
  payload='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"RIG_COMMIT_POLICY=guarded git commit -m \"fix: example\""}}'
  mv "$TEST_PROJECT/.rig/memory/.rig-commit-ok" "$TEST_ROOT/approval-held"
  run_claude_pretool_from_settings "$payload"
  [ "$status" -eq 2 ]
  [[ "$output" == *'Approval is missing'* ]] || return 1
  mv "$TEST_ROOT/approval-held" "$TEST_PROJECT/.rig/memory/.rig-commit-ok"
  run_claude_pretool_from_settings "$payload"
  [ "$status" -eq 0 ]
  [ -f "$TEST_PROJECT/.rig/memory/.rig-commit-ok" ]
}

@test "marked visible commit falls back without a Git hook and rejects an incompatible installed hook" {
  git -C "$TEST_PROJECT" checkout -qb fix/hookless
  touch "$TEST_PROJECT/.rig/memory/.rig-commit-ok"
  payload='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"RIG_COMMIT_POLICY=guarded git commit -m \"fix: skipped\""}}'
  run_claude_pretool_from_settings "$payload"
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_PROJECT/.rig/memory/.rig-commit-ok" ]
  touch "$TEST_PROJECT/.rig/memory/.rig-commit-ok"
  cat > "$TEST_PROJECT/.git/hooks/commit-msg" <<'HOOK'
#!/bin/sh
# RIG_COMMIT_POLICY=guarded appears only in this comment; no approval is checked.
exit 0
HOOK
  chmod +x "$TEST_PROJECT/.git/hooks/commit-msg"
  run_claude_pretool_from_settings "$payload"
  [ "$status" -eq 2 ]
  [[ "$output" == *'does not support guarded commits'* ]] || return 1
  [ -f "$TEST_PROJECT/.rig/memory/.rig-commit-ok" ]
  install_runtime_git_hook
  run_claude_pretool_from_settings "$payload"
  [ "$status" -eq 0 ]
  [ -f "$TEST_PROJECT/.rig/memory/.rig-commit-ok" ]
}

@test "guarded hook probe confines an accidental wrapper write outside the project" {
  install_runtime_git_hook
  touch "$TEST_PROJECT/.rig/memory/.rig-commit-ok"
  mv "$TEST_PROJECT/.git/hooks/commit-msg" "$TEST_PROJECT/.git/hooks/commit-msg-real"
  cat > "$TEST_PROJECT/.git/hooks/commit-msg" <<'HOOK'
#!/bin/sh
"$(dirname "$0")/commit-msg-real" "$1" || exit $?
printf 'wrapper wrote here\n' >> "$1"
HOOK
  chmod +x "$TEST_PROJECT/.git/hooks/commit-msg"
  local payload
  payload='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"RIG_COMMIT_POLICY=guarded git commit -m \"fix: probe [#593]\""}}'
  run_claude_pretool_from_settings "$payload"
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_PROJECT/--rig-policy-probe" ]
  [ -f "$TEST_PROJECT/.rig/memory/.rig-commit-ok" ]
}

@test "hookless fallback keeps base-branch chore/docs policy and claims one approval" {
  git -C "$TEST_PROJECT" checkout -q -B main
  touch "$TEST_PROJECT/.rig/memory/.rig-commit-ok"
  payload="$(bash_payload "$TEST_PROJECT" 'RIG_COMMIT_POLICY=guarded git commit -m "docs: allowed [#593]"')"
  run_claude_pretool_from_settings "$payload"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Commit to 'main' blocked"* ]] || return 1
  [ -f "$TEST_PROJECT/.rig/memory/.rig-commit-ok" ]

  printf 'housekeeping: direct-push\n' > "$TEST_PROJECT/CLAUDE.md"
  payload="$(bash_payload "$TEST_PROJECT" 'RIG_COMMIT_POLICY=guarded git commit -m "fix: blocked [#593]"')"
  run_claude_pretool_from_settings "$payload"
  [ "$status" -eq 2 ]
  [[ "$output" == *'Direct-to-main commit blocked'* ]] || return 1
  [ -f "$TEST_PROJECT/.rig/memory/.rig-commit-ok" ]

  payload="$(bash_payload "$TEST_PROJECT" 'RIG_COMMIT_POLICY=guarded git commit -m "docs: allowed [#593]"')"
  run_claude_pretool_from_settings "$payload"
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_PROJECT/.rig/memory/.rig-commit-ok" ]
  [ -f "$TEST_PROJECT/.rig/memory/.rig-commit-fallback-pending-legacy" ]
  run_claude_pretool_from_settings "$payload"
  [ "$status" -eq 2 ]
}

@test "hookless fallback rejects and clears stale approval" {
  git -C "$TEST_PROJECT" checkout -qb fix/hookless-ttl
  touch "$TEST_PROJECT/.rig/memory/.rig-commit-ok"
  touch -t 200001010000 "$TEST_PROJECT/.rig/memory/.rig-commit-ok"
  payload="$(bash_payload "$TEST_PROJECT" 'RIG_COMMIT_POLICY=guarded git commit -m "fix: stale [#593]"')"
  run_claude_pretool_from_settings "$payload"
  [ "$status" -eq 2 ]
  [[ "$output" == *'stale'* ]] || return 1
  [ ! -f "$TEST_PROJECT/.rig/memory/.rig-commit-ok" ]
}

@test "Codex adapter uses the same hookless one-shot fallback" {
  git -C "$TEST_PROJECT" checkout -qb fix/codex-hookless
  touch "$TEST_PROJECT/.rig/memory/.rig-commit-ok"
  payload="$(bash_payload "$TEST_PROJECT" 'RIG_COMMIT_POLICY=guarded git commit -m "fix: codex fallback [#593]"')"
  run_codex_adapter "$payload"
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_PROJECT/.rig/memory/.rig-commit-ok" ]
  [ -f "$TEST_PROJECT/.rig/memory/.rig-commit-fallback-pending-legacy" ]
}

@test "marked visible commit refuses explicit Git and Husky hook bypass flags" {
  install_runtime_git_hook
  touch "$TEST_PROJECT/.rig/memory/.rig-commit-ok"
  local command payload
  for command in \
    'RIG_COMMIT_POLICY=guarded git commit --no-verify -m example' \
    'RIG_COMMIT_POLICY=guarded git commit -n -m example' \
    'RIG_COMMIT_POLICY=guarded git -c core.hooksPath=/dev/null commit -m example' \
    'HUSKY=0 RIG_COMMIT_POLICY=guarded git commit -m example'; do
    payload="$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$command")"
    run_claude_pretool_from_settings "$payload"
    [ "$status" -eq 2 ] || { echo "Unexpectedly allowed: $command" >&3; return 1; }
  done
}

@test "marked visible commit checks native linked worktree target and Husky path" {
  setup_linked_hook_worktrees
  install_runtime_git_hook
  touch "$TEST_PROJECT/.rig/memory/.rig-commit-ok"
  payload="$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "RIG_COMMIT_POLICY=guarded git -C '$LINKED_FEATURE' commit -m example")"
  run_linked_pretool "$payload"
  [ "$status" -eq 2 ]
  touch "$LINKED_FEATURE/.rig/memory/.rig-commit-ok"
  run_linked_pretool "$payload"
  [ "$status" -eq 0 ]

  install_runtime_git_hook husky
  payload='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"RIG_COMMIT_POLICY=guarded git commit -m example"}}'
  run_claude_pretool_from_settings "$payload"
  [ "$status" -eq 0 ]
  git -C "$TEST_PROJECT" config core.hooksPath /dev/null
  run_claude_pretool_from_settings "$payload"
  [ "$status" -eq 2 ]
}

@test "marked visible commit cannot use project approval in an unrelated repository" {
  install_runtime_git_hook
  touch "$TEST_PROJECT/.rig/memory/.rig-commit-ok"
  other="$TEST_ROOT/unrelated"
  mkdir -p "$other"
  git -C "$other" init -q
  payload="$(bash_payload "$TEST_PROJECT" "RIG_COMMIT_POLICY=guarded git -C '$other' commit -m example")"
  run_claude_pretool_from_settings "$payload"
  [ "$status" -eq 2 ]
  [[ "$output" == *'outside the installed project'* ]] || return 1
  [ -f "$TEST_PROJECT/.rig/memory/.rig-commit-ok" ]
}

@test "marked commit resolves nested shell, cd dash, subshell and pipeline cwd safely" {
  setup_linked_hook_worktrees
  install_runtime_git_hook
  touch "$LINKED_FEATURE/.rig/memory/.rig-commit-ok"
  local command payload
  for command in \
    "bash -c 'cd \"$TEST_PROJECT\" && RIG_COMMIT_POLICY=guarded git commit -m example'" \
    "cd '$LINKED_FEATURE' && cd - && RIG_COMMIT_POLICY=guarded git commit -m example" \
    "( cd '$LINKED_FEATURE'; true ); RIG_COMMIT_POLICY=guarded git commit -m example" \
    "cd '$LINKED_FEATURE' | true; RIG_COMMIT_POLICY=guarded git commit -m example" \
    "true | cd '$LINKED_FEATURE'; RIG_COMMIT_POLICY=guarded git commit -m example"; do
    payload="$(bash_payload "$TEST_PROJECT" "$command")"
    run_claude_pretool_from_settings "$payload"
    [ "$status" -eq 2 ] || { echo "Unexpectedly allowed: $command" >&3; return 1; }
  done
}

@test "marked multi-repository commit chain is blocked before execution" {
  setup_linked_hook_worktrees
  install_runtime_git_hook
  touch "$LINKED_FEATURE/.rig/memory/.rig-commit-ok" "$TEST_PROJECT/.rig/memory/.rig-commit-ok"
  payload="$(bash_payload "$TEST_PROJECT" "RIG_COMMIT_POLICY=guarded git -C '$LINKED_FEATURE' commit -m first; RIG_COMMIT_POLICY=guarded git -C '$TEST_PROJECT' commit -m second")"
  run_claude_pretool_from_settings "$payload"
  [ "$status" -eq 2 ]
  [ -f "$LINKED_FEATURE/.rig/memory/.rig-commit-ok" ]
  [ -f "$TEST_PROJECT/.rig/memory/.rig-commit-ok" ]
}

@test "marked visible Git environment override is refused before target inference" {
  setup_linked_hook_worktrees
  install_runtime_git_hook
  touch "$LINKED_FEATURE/.rig/memory/.rig-commit-ok" "$TEST_PROJECT/.rig/memory/.rig-commit-ok"
  payload="$(bash_payload "$TEST_PROJECT" "GIT_DIR='$TEST_PROJECT/.git' GIT_WORK_TREE='$LINKED_FEATURE' RIG_COMMIT_POLICY=guarded git commit -m example")"
  run_claude_pretool_from_settings "$payload"
  [ "$status" -eq 2 ]
  [[ "$output" == *'environment overrides'* ]] || return 1
}

@test "early Bash check distinguishes inert script heredoc from executable substitution" {
  local command payload
  command=$'cat > example.sh <<\x27EOF\x27\n#!/bin/sh\ngit commit -m "text only"\nEOF'
  payload="$(bash_payload "$TEST_PROJECT" "$command")"
  run_claude_pretool_from_settings "$payload"
  [ "$status" -eq 0 ]

  command=$'cat <<EOF\n$(git commit -m "executed")\nEOF'
  payload="$(bash_payload "$TEST_PROJECT" "$command")"
  run_claude_pretool_from_settings "$payload"
  [ "$status" -eq 2 ]
}

@test "normal Claude PreToolUse rejects malformed payload and allows ordinary read" {
  run_claude_pretool_from_settings '{broken'
  [ "$status" -eq 2 ]
  run_claude_pretool_from_settings '{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"/tmp/example"}}'
  [ "$status" -eq 0 ]
}

@test "legacy positional payload retains protected block and approved-push behavior" {
  run_claude_pretool Edit "$(python3 -c 'import json,sys; print(json.dumps({"file_path":sys.argv[1]}))' "$TEST_PROJECT/CLAUDE.md")"
  [ "$status" -eq 2 ]
  run_claude_pretool_from_settings '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git push origin current-branch"}}'
  [ "$status" -eq 0 ]
}

@test "normal Claude hook denies external Rig governance path and missing policy" {
  external_rig="$TEST_ROOT/external-rig"
  mkdir -p "$external_rig/rules"
  cp "$REPO_ROOT/templates/project/.rig/rules/protected-paths.txt" "$external_rig/rules/protected-paths.txt"
  printf '%s\n' "$external_rig" > "$TEST_PROJECT/.rigpath"
  payload="$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":sys.argv[1],"content":"unsafe"}}))' "$external_rig/rules/protected-paths.txt")"
  run_claude_pretool_from_settings "$payload"
  [ "$status" -eq 2 ]
  [[ "$output" == *"governance file"* ]] || return 1
  rm "$external_rig/rules/protected-paths.txt"
  run_claude_pretool_from_settings "$payload"
  [ "$status" -eq 2 ]
  [[ "$output" == *"missing or unreadable"* ]] || return 1
}

@test "normal Claude hook uses installed project root after cwd changes" {
  payload="$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":sys.argv[1]}}))' "$TEST_PROJECT/CLAUDE.md")"
  run bash -c 'cd "$1" && printf "%s" "$3" | bash "$2/.claude/hooks/pre-tool.sh"' \
    _ "$TEST_ROOT" "$TEST_PROJECT" "$payload"
  [ "$status" -eq 2 ]
  [[ "$output" == *"governance file"* ]] || return 1
}

@test "Bash hook blocks an unmarked visible commit regardless of event cwd" {
  payload="$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"Bash","cwd":sys.argv[1],"tool_input":{"command":"git commit -m fix:example"}}))' "$TEST_ROOT")"
  run_claude_pretool_from_settings "$payload"
  [ "$status" -eq 2 ]
}

@test "normal Claude worktree redirect returns documented updatedInput" {
  target="$TEST_PROJECT/.claude/worktrees/other-session/src/app.py"
  payload="$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":sys.argv[1],"content":"hello"}}))' "$target")"
  run_claude_pretool_from_settings "$payload"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"updatedInput"'* ]] || return 1
  [[ "$output" == *"$TEST_PROJECT/src/app.py"* ]] || return 1
}

@test "worktree redirect cannot bypass governance protection at destination" {
  target="$TEST_PROJECT/.claude/worktrees/other-session/CLAUDE.md"
  payload="$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":sys.argv[1],"content":"unsafe"}}))' "$target")"
  run_claude_pretool_from_settings "$payload"
  [ "$status" -eq 2 ]
  [[ "$output" == *"governance file"* ]] || return 1
  [[ "$output" != *'"updatedInput"'* ]] || return 1
}

@test "symlink alias to protected governance path is denied" {
  printf 'governance\n' > "$TEST_PROJECT/CLAUDE.md"
  ln -s "$TEST_PROJECT/CLAUDE.md" "$TEST_PROJECT/alias.md"
  payload="$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":sys.argv[1]}}))' "$TEST_PROJECT/alias.md")"
  run_claude_pretool_from_settings "$payload"
  [ "$status" -eq 2 ]
  [[ "$output" == *"governance file"* ]] || return 1
}

@test "linked feature hook denies protected Write and Edit in main worktree" {
  setup_linked_hook_worktrees
  local tool payload
  for tool in Write Edit; do
    payload="$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","tool_name":sys.argv[1],"cwd":sys.argv[2],"tool_input":{"file_path":sys.argv[3]}}))' "$tool" "$LINKED_FEATURE" "$TEST_PROJECT/CLAUDE.md")"
    run_linked_pretool "$payload"
    [ "$status" -eq 2 ]
    [[ "$output" == *"governance file"* ]] || return 1
  done

  payload="$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"Write","cwd":sys.argv[1],"tool_input":{"file_path":sys.argv[2],"content":"unsafe"}}))' "$LINKED_FEATURE" "$TEST_PROJECT/.rig/rules/protected-paths.txt")"
  run_linked_pretool "$payload"
  [ "$status" -eq 2 ]
  [[ "$output" == *"governance file"* ]] || return 1

  payload="$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"Edit","cwd":sys.argv[1],"tool_input":{"file_path":"CLAUDE.md","old_string":"old","new_string":"unsafe"}}))' "$TEST_PROJECT")"
  run_linked_pretool "$payload"
  [ "$status" -eq 2 ]
  [[ "$output" == *"$TEST_PROJECT/CLAUDE.md"* ]] || return 1

  payload="$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"Write","cwd":sys.argv[1],"tool_input":{"file_path":sys.argv[2],"content":"safe"}}))' "$LINKED_FEATURE" "$TEST_PROJECT/src/ordinary.txt")"
  run_linked_pretool "$payload"
  [ "$status" -eq 0 ]
}

@test "linked hook enforces both worktree policies and fails closed on a missing target policy" {
  setup_linked_hook_worktrees
  printf '[REPO]/sensitive.txt\n' >> "$TEST_PROJECT/.rig/rules/protected-paths.txt"
  printf '[REPO]/source-only.txt\n' >> "$LINKED_FEATURE/.rig/rules/protected-paths.txt"
  local path payload

  for path in "$TEST_PROJECT/sensitive.txt" "$TEST_PROJECT/source-only.txt"; do
    payload="$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"Write","cwd":sys.argv[1],"tool_input":{"file_path":sys.argv[2],"content":"unsafe"}}))' "$LINKED_FEATURE" "$path")"
    run_linked_pretool "$payload"
    [ "$status" -eq 2 ]
    [[ "$output" == *"governance file"* ]] || return 1
  done

  payload="$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"Write","cwd":sys.argv[1],"tool_input":{"file_path":sys.argv[2],"content":"safe"}}))' "$LINKED_FEATURE" "$TEST_PROJECT/ordinary.txt")"
  run_linked_pretool "$payload"
  [ "$status" -eq 0 ]

  rm "$TEST_PROJECT/.rig/rules/protected-paths.txt"
  run_linked_pretool "$payload"
  [ "$status" -eq 2 ]
  [[ "$output" == *"missing or unreadable"* ]] || return 1
}

@test "linked hooks resolve a shared external Rig policy against both worktree roots" {
  setup_linked_hook_worktrees
  local shared_rig="$TEST_ROOT/shared-rig" payload
  mkdir -p "$shared_rig/rules"
  cp "$TEST_PROJECT/.rig/rules/protected-paths.txt" "$shared_rig/rules/protected-paths.txt"
  printf '[REPO]/sensitive.txt\n' >> "$shared_rig/rules/protected-paths.txt"
  printf '%s\n' "$shared_rig" > "$TEST_PROJECT/.rigpath"
  printf '%s\n' "$shared_rig" > "$LINKED_FEATURE/.rigpath"

  payload="$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"Write","cwd":sys.argv[1],"tool_input":{"file_path":sys.argv[2],"content":"unsafe"}}))' "$LINKED_FEATURE" "$TEST_PROJECT/sensitive.txt")"
  run_linked_pretool "$payload"
  [ "$status" -eq 2 ]
  [[ "$output" == *"governance file"* ]] || return 1

  payload="$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"Write","cwd":sys.argv[1],"tool_input":{"file_path":sys.argv[2],"content":"safe"}}))' "$LINKED_FEATURE" "$TEST_PROJECT/ordinary.txt")"
  run_linked_pretool "$payload"
  [ "$status" -eq 0 ]
}

@test "Claude and Codex Bash hooks catch escaped g\\it and leave approval for Git" {
  touch "$TEST_PROJECT/.rig/memory/.rig-commit-ok"
  payload='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"g\\it commit -m example"}}'
  run_claude_pretool_from_settings "$payload"
  [ "$status" -eq 2 ]
  run_codex_adapter "$payload"
  [ "$status" -eq 2 ]
  [ -f "$TEST_PROJECT/.rig/memory/.rig-commit-ok" ]
  install_runtime_git_hook
  payload='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"RIG_COMMIT_POLICY=guarded g\\it commit -m example"}}'
  run_claude_pretool_from_settings "$payload"
  [ "$status" -eq 0 ]
  run_codex_adapter "$payload"
  [ "$status" -eq 0 ]
  [ -f "$TEST_PROJECT/.rig/memory/.rig-commit-ok" ]
}

@test "Codex adapter blocks plain unmarked Bash commit" {
  payload='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git commit -m example"}}'
  run_codex_adapter "$payload"
  [ "$status" -eq 2 ]
  [[ "$output" == *'Commit blocked by The Rig'* ]] || return 1
}

@test "PreToolUse rejects a compound call with a second visible commit" {
  payload='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"RIG_COMMIT_POLICY=guarded git commit -m first; git commit -m second"}}'
  run_claude_pretool_from_settings "$payload"
  [ "$status" -eq 2 ]
  run_codex_adapter "$payload"
  [ "$status" -eq 2 ]
}

@test "PreToolUse allows a guarded -F commit after creating its message file" {
  install_runtime_git_hook
  touch "$TEST_PROJECT/.rig/memory/.rig-commit-ok"
  payload='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"printf \"docs: approved\\n\" > message.txt; RIG_COMMIT_POLICY=guarded git commit -F message.txt"}}'
  run_claude_pretool_from_settings "$payload"
  [ "$status" -eq 0 ]
  run_codex_adapter "$payload"
  [ "$status" -eq 0 ]
}

@test "native PostToolUse does not duplicate Git post-commit progress" {
  printf '# Progress\n\n---\n' > "$TEST_PROJECT/.rig/memory/PROGRESS.md"
  payload='{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":{"stdout":"[fix/example abcdef0] fix: example"}}'
  run bash -c 'cd "$1" && printf "%s" "$2" | bash .claude/hooks/post-tool.sh' _ "$TEST_PROJECT" "$payload"
  [ "$status" -eq 0 ]
  if grep -q 'Auto-logged' "$TEST_PROJECT/.rig/memory/PROGRESS.md"; then return 1; fi
}

@test "Claude Edit and Codex apply_patch produce the same protected-file outcome" {
  protected="$TEST_PROJECT/CLAUDE.md"
  claude_payload="$(python3 -c 'import json,sys; print(json.dumps({"file_path":sys.argv[1]}))' "$protected")"
  patch='*** Begin Patch
*** Update File: CLAUDE.md
@@
-old
+new
*** End Patch'
  codex_payload="$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"apply_patch","tool_input":{"command":sys.argv[1]}}))' "$patch")"

  run_claude_pretool Edit "$claude_payload"
  claude_status="$status"
  run_codex_adapter "$codex_payload"
  codex_status="$status"

  [ "$claude_status" -ne 0 ]
  [ "$codex_status" -ne 0 ]
}

@test "Codex apply_patch checks project blocked paths and target worktree policy" {
  local claude_payload codex_payload patch
  claude_payload="$(python3 -c 'import json,sys; print(json.dumps({"file_path":sys.argv[1]}))' "$TEST_PROJECT/.env.production")"
  patch=$'*** Begin Patch\n*** Add File: .env.production\n+unsafe\n*** End Patch'
  codex_payload="$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"apply_patch","tool_input":{"command":sys.argv[1]}}))' "$patch")"
  run_claude_pretool Write "$claude_payload"
  [ "$status" -eq 2 ]
  run_codex_adapter "$codex_payload"
  [ "$status" -eq 2 ]

  patch=$'*** Begin Patch\n*** Add File: ordinary.txt\nsafe\n*** Add File: .env.production\nunsafe\n*** End Patch'
  codex_payload="$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"apply_patch","tool_input":{"command":sys.argv[1]}}))' "$patch")"
  run_codex_adapter "$codex_payload"
  [ "$status" -eq 2 ]

  setup_linked_hook_worktrees
  printf '[REPO]/sensitive.txt\n' >> "$LINKED_FEATURE/.rig/rules/protected-paths.txt"
  patch="$(printf '*** Begin Patch\n*** Add File: %s\nunsafe\n*** End Patch\n' "$LINKED_FEATURE/sensitive.txt")"
  codex_payload="$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"apply_patch","tool_input":{"command":sys.argv[1]}}))' "$patch")"
  run_codex_adapter "$codex_payload"
  [ "$status" -eq 2 ]

  patch=$'*** Begin Patch\n*** Add File: ordinary.txt\nsafe\n*** End Patch'
  codex_payload="$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"apply_patch","tool_input":{"command":sys.argv[1]}}))' "$patch")"
  run_codex_adapter "$codex_payload"
  [ "$status" -eq 0 ]
}

@test "Codex apply_patch resolves relative targets against event cwd" {
  mkdir -p "$TEST_PROJECT/nested"
  patch=$'*** Begin Patch\n*** Update File: ../CLAUDE.md\n@@\n-old\n+unsafe\n*** End Patch'
  codex_payload="$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"apply_patch","cwd":sys.argv[1],"tool_input":{"command":sys.argv[2]}}))' "$TEST_PROJECT/nested" "$patch")"
  run_codex_adapter "$codex_payload"
  [ "$status" -eq 2 ]
}

@test "Claude and Codex SessionStart payloads emit equivalent context" {
  direct_out="$TEST_ROOT/direct.json"
  codex_out="$TEST_ROOT/codex.json"
  (
    cd "$TEST_PROJECT"
    printf '%s' '{"source":"startup"}' | \
      RIG_SESSION_PID="$DIRECT_SESSION_PID" RIG_SESSION_ANCHOR=parity \
      bash .claude/hooks/session-start.sh > "$direct_out"
  )
  (
    cd "$TEST_PROJECT"
    printf '%s' '{"hookEventName":"SessionStart","source":"startup"}' | \
      RIG_SESSION_PID="$CODEX_SESSION_PID" RIG_SESSION_ANCHOR=parity \
      bash .codex/hooks/rig-adapter.sh > "$codex_out"
  )

  run python3 - "$direct_out" "$codex_out" <<'PY'
import json, pathlib, sys
direct = json.loads(pathlib.Path(sys.argv[1]).read_text())
codex = json.loads(pathlib.Path(sys.argv[2]).read_text())
assert direct == codex
assert direct["hookSpecificOutput"]["hookEventName"] == "SessionStart"
PY
  [ "$status" -eq 0 ]
}

@test "Codex SessionStart binds CODEX_THREAD_ID as native session identity" {
  run env CODEX_THREAD_ID=codex-thread-123 bash -c 'cd "$1" && printf "%s" "$2" | bash .codex/hooks/rig-adapter.sh' \
    _ "$TEST_PROJECT" '{"hookEventName":"SessionStart","source":"startup"}'
  [ "$status" -eq 0 ]
  run "$TEST_PROJECT/bin/rig" session resolve --agent codex --native-session-id codex-thread-123 --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"agent": "codex"'* && "$output" == *'"reason": "native_id"'* ]] || return 1
}
