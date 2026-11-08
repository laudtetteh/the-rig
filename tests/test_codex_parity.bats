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
  cp "$REPO_ROOT/templates/project/.claude/hooks/session-start.sh" \
    "$TEST_PROJECT/.claude/hooks/session-start.sh"
  cp "$REPO_ROOT/templates/project/.codex/hooks/rig-adapter.sh" \
    "$TEST_PROJECT/.codex/hooks/rig-adapter.sh"
  mkdir -p "$TEST_PROJECT/bin"
  cp "$REPO_ROOT/templates/project/bin/rig" "$TEST_PROJECT/bin/rig"
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

@test "normal Claude PreToolUse Edit denies a protected path with blocking exit 2" {
  payload="$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":sys.argv[1],"old_string":"old","new_string":"new"}}))' "$TEST_PROJECT/CLAUDE.md")"
  run_claude_pretool_from_settings "$payload"
  [ "$status" -eq 2 ]
  [[ "$output" == *"governance file"* ]] || return 1
}

@test "normal Claude PreToolUse Bash blocks commit without sentinel" {
  payload='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git commit -m \"fix: unsafe\""}}'
  run_claude_pretool_from_settings "$payload"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Commit blocked by The Rig."* ]] || return 1
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

@test "normal Claude commit gate checks installed project's branch after cwd changes" {
  git -C "$TEST_PROJECT" checkout -q -B main
  touch "$TEST_PROJECT/.rig/memory/.rig-commit-ok"
  payload='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git commit -m \"fix: unsafe\""}}'
  run bash -c 'cd "$1" && printf "%s" "$3" | bash "$2/.claude/hooks/pre-tool.sh"' \
    _ "$TEST_ROOT" "$TEST_PROJECT" "$payload"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Commit to 'main' blocked"* ]] || return 1
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

run_claude_pretool_with_ttl() {
  local ttl="$1" tool="$2" payload="$3"
  run env RIG_COMMIT_OK_TTL_SECONDS="$ttl" bash -c 'cd "$1" && printf "%s" "$3" | bash .claude/hooks/pre-tool.sh "$2"' \
    _ "$TEST_PROJECT" "$tool" "$payload"
}

run_claude_pretool_with_path() {
  local path="$1" tool="$2" payload="$3"
  run env PATH="$path" bash -c 'cd "$1" && printf "%s" "$3" | bash .claude/hooks/pre-tool.sh "$2"' \
    _ "$TEST_PROJECT" "$tool" "$payload"
}

run_codex_adapter() {
  local payload="$1"
  run bash -c 'cd "$1" && printf "%s" "$2" | bash .codex/hooks/rig-adapter.sh' \
    _ "$TEST_PROJECT" "$payload"
}

@test "Claude and Codex Bash payloads produce the same outcome" {
  command='git push origin parity'
  claude_payload="$(python3 -c 'import json,sys; print(json.dumps({"command":sys.argv[1]}))' "$command")"
  codex_payload="$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$command")"

  run_claude_pretool Bash "$claude_payload"
  claude_status="$status"
  run_codex_adapter "$codex_payload"
  codex_status="$status"

  [ "$claude_status" -eq "$codex_status" ]
}

@test "commit sentinel blocks missing authorization through shipped pre-tool hook" {
  command="git commit -m 'chore(memory): test [#1]'"
  claude_payload="$(python3 -c 'import json,sys; print(json.dumps({"command":sys.argv[1]}))' "$command")"

  run_claude_pretool Bash "$claude_payload"

  [ "$status" -ne 0 ]
  [[ "$output" == *"Commit blocked by The Rig."* ]] || return 1
  [[ "$output" == *"go-ahead before I commit"* ]] || return 1
}

@test "commit sentinel allows fresh authorization through shipped pre-tool hook" {
  git -C "$TEST_PROJECT" checkout -q -b chore/sentinel-fresh
  touch "$TEST_PROJECT/.rig/memory/.rig-commit-ok"
  command="git commit -m 'chore(memory): test [#1]'"
  claude_payload="$(python3 -c 'import json,sys; print(json.dumps({"command":sys.argv[1]}))' "$command")"

  run_claude_pretool Bash "$claude_payload"

  [ "$status" -eq 0 ]
}

@test "commit sentinel rejects and clears stale authorization" {
  git -C "$TEST_PROJECT" checkout -q -b chore/sentinel-stale
  touch "$TEST_PROJECT/.rig/memory/.rig-commit-ok"
  touch -t 200001010000 "$TEST_PROJECT/.rig/memory/.rig-commit-ok"
  command="git commit -m 'chore(memory): test [#1]'"
  claude_payload="$(python3 -c 'import json,sys; print(json.dumps({"command":sys.argv[1]}))' "$command")"

  run_claude_pretool_with_ttl 900 Bash "$claude_payload"

  [ "$status" -ne 0 ]
  [[ "$output" == *"commit authorization is stale"* ]] || return 1
  [ ! -f "$TEST_PROJECT/.rig/memory/.rig-commit-ok" ]
}

@test "commit sentinel honors external rig directory from .rigpath" {
  git -C "$TEST_PROJECT" checkout -q -b chore/sentinel-external
  external_rig="$TEST_ROOT/external-rig"
  mkdir -p "$external_rig/memory"
  printf '%s\n' "$external_rig" > "$TEST_PROJECT/.rigpath"
  touch "$external_rig/memory/.rig-commit-ok"
  command="git commit -m 'chore(memory): test [#1]'"
  claude_payload="$(python3 -c 'import json,sys; print(json.dumps({"command":sys.argv[1]}))' "$command")"

  run_claude_pretool Bash "$claude_payload"

  [ "$status" -eq 0 ]
}

@test "commit sentinel prefers GNU stat mtime before BSD filesystem stat fallback" {
  git -C "$TEST_PROJECT" checkout -q -b chore/sentinel-gnu-stat
  touch "$TEST_PROJECT/.rig/memory/.rig-commit-ok"
  fake_bin="$TEST_ROOT/bin"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/stat" <<'EOF'
#!/bin/sh
if [ "$1" = "-c" ]; then
  python3 -c 'import os,sys; print(int(os.stat(sys.argv[1]).st_mtime))' "$3"
  exit 0
fi
if [ "$1" = "-f" ]; then
  printf 'gnu-filesystem-stat-output\n'
  exit 0
fi
exit 1
EOF
  chmod +x "$fake_bin/stat"
  command="git commit -m 'chore(memory): test [#1]'"
  claude_payload="$(python3 -c 'import json,sys; print(json.dumps({"command":sys.argv[1]}))' "$command")"

  run_claude_pretool_with_path "$fake_bin:$PATH" Bash "$claude_payload"

  if [ "$status" -ne 0 ]; then
    printf '%s\n' "$output"
    return 1
  fi
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
