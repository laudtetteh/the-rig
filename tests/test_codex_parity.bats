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
