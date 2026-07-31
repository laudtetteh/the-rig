#!/usr/bin/env bats

setup() {
  export CASE_DIR="$BATS_TEST_TMPDIR/project"
  mkdir -p "$CASE_DIR/bin" "$CASE_DIR/.claude/hooks" "$CASE_DIR/.rig/memory/sessions/done"
  cp "$BATS_TEST_DIRNAME/../templates/project/bin/rig" "$CASE_DIR/bin/rig"
  cp "$BATS_TEST_DIRNAME/../templates/project/.claude/hooks/session-start.sh" "$CASE_DIR/.claude/hooks/session-start.sh"
  chmod +x "$CASE_DIR/bin/rig" "$CASE_DIR/.claude/hooks/session-start.sh"
  git -C "$CASE_DIR" init -q
  git -C "$CASE_DIR" checkout -q -b feat/lineage
  printf '# Snapshot\n' > "$CASE_DIR/.rig/memory/CONTEXT_SNAPSHOT.md"
  unset RIG_SESSION_FILE RIG_SESSION_ANCHOR RIG_SESSION_PID RIG_AGENT
}

bind_file() {
  printf '%s' "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin)["session_file"])'
}

run_start() {
  local payload="$1"
  run env RIG_SESSION_PID=4242 bash -c 'cd "$1" && printf "%s" "$2" | .claude/hooks/session-start.sh' _ "$CASE_DIR" "$payload"
}

@test "public fork source creates a distinct fork anchor without inventing a parent" {
  run "$CASE_DIR/bin/rig" session bind --agent claude --native-session-id root --source startup
  [ "$status" -eq 0 ]
  local root_file root_anchor fork_file
  root_file=$(bind_file "$output")
  root_anchor=$(SESSION_F="$root_file" python3 -c 'import json,os; print(json.load(open(os.environ["SESSION_F"]))["anchor"])')

  run "$CASE_DIR/bin/rig" session bind --agent claude --native-session-id fork --source fork
  [ "$status" -eq 0 ]
  fork_file=$(bind_file "$output")
  ROOT_ANCHOR="$root_anchor" SESSION_F="$fork_file" python3 -c 'import json,os; d=json.load(open(os.environ["SESSION_F"])); assert d["anchor"] != os.environ["ROOT_ANCHOR"]; assert d["lineage"] == {"parent_anchor":None,"parent_native_session_id":None,"kind":"fork"}'
}

@test "documented Codex tree and parent IDs produce immutable exact lineage" {
  run "$CASE_DIR/bin/rig" session bind --agent codex --native-session-id thread-parent --root-session-id tree-root --source startup
  [ "$status" -eq 0 ]
  local parent_file parent_anchor fork_file before
  parent_file=$(bind_file "$output")
  parent_anchor=$(SESSION_F="$parent_file" python3 -c 'import json,os; print(json.load(open(os.environ["SESSION_F"]))["anchor"])')
  run "$CASE_DIR/bin/rig" session bind --agent codex --native-session-id thread-fork --root-session-id tree-root --parent-native-session-id thread-parent --source fork --native-title 'Native fork'
  [ "$status" -eq 0 ]
  fork_file=$(bind_file "$output")
  before=$(SESSION_F="$fork_file" python3 -c 'import json,os; d=json.load(open(os.environ["SESSION_F"])); print(json.dumps(d["lineage"],sort_keys=True)); assert d["native"]["root_session_id"]=="tree-root" and d["names"]["native_title"]=="Native fork" and d["names"]["native_sync"]=="in-sync"')
  PARENT_ANCHOR="$parent_anchor" SESSION_F="$fork_file" python3 -c 'import json,os; d=json.load(open(os.environ["SESSION_F"])); assert d["lineage"]["parent_anchor"]==os.environ["PARENT_ANCHOR"]'

  run "$CASE_DIR/bin/rig" session bind --agent codex --native-session-id thread-fork --root-session-id different --parent-native-session-id missing --source fork
  [ "$status" -eq 0 ]
  [ "$before" = "$(SESSION_F="$fork_file" python3 -c 'import json,os; print(json.dumps(json.load(open(os.environ["SESSION_F"]))["lineage"],sort_keys=True))')" ]
}

@test "Rig naming records display intent and public sync state" {
  run "$CASE_DIR/bin/rig" session bind --agent claude --native-session-id named --source startup --native-title 'Old title'
  [ "$status" -eq 0 ]
  local file
  file=$(bind_file "$output")
  run env RIG_SESSION_FILE="$file" "$CASE_DIR/bin/rig" session-name set --final 'New title'
  [ "$status" -eq 0 ]
  SESSION_F="$file" python3 -c 'import json,os; n=json.load(open(os.environ["SESSION_F"]))["names"]; assert n["final"]==n["display_title"]=="New title" and n["native_title"]=="Old title" and n["native_sync"]=="suggested"'
}

@test "Claude SessionStart ingests and emits only documented public title fields" {
  run_start '{"source":"startup","session_id":"claude-title","session_title":"Existing title"}'
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["hookSpecificOutput"]["sessionTitle"]=="Existing title"'
  local file
  file=$(find "$CASE_DIR/.rig/memory/sessions" -name 'session-*.json' -print | head -1)
  run env RIG_SESSION_FILE="$file" "$CASE_DIR/bin/rig" session-name set --final 'Rig display title'
  [ "$status" -eq 0 ]
  run_start '{"source":"resume","session_id":"claude-title","session_title":"Existing title"}'
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["hookSpecificOutput"]["sessionTitle"]=="Rig display title"'
}

@test "public title ingestion preserves multiline metacharacters as data" {
  run_start '{"source":"startup","session_id":"claude-adversarial","session_title":"line one\n$(touch /tmp/rig-409-title-injected); `nope`"}'
  [ "$status" -eq 0 ]
  [ ! -e /tmp/rig-409-title-injected ]
  printf '%s' "$output" | python3 -c 'import json,sys; assert json.load(sys.stdin)["hookSpecificOutput"]["sessionTitle"]=="line one\n$(touch /tmp/rig-409-title-injected); `nope`"'
  local file
  file=$(find "$CASE_DIR/.rig/memory/sessions" -name 'session-*.json' -print | head -1)
  SESSION_F="$file" python3 -c 'import json,os; assert json.load(open(os.environ["SESSION_F"]))["names"]["native_title"]=="line one\n$(touch /tmp/rig-409-title-injected); `nope`"'
}

@test "subagent SessionStart is read-only and cannot bootstrap or title a root" {
  run_start '{"source":"startup","session_id":"missing","agent_id":"child-1","session_title":"Child"}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(find "$CASE_DIR/.rig/memory/sessions" -name 'session-*.json' | wc -l | tr -d ' ')" -eq 0 ]

  run "$CASE_DIR/bin/rig" session bind --agent claude --native-session-id root --source startup --native-title 'Root title'
  [ "$status" -eq 0 ]
  local file before after
  file=$(bind_file "$output")
  before=$(cksum "$file")
  run_start '{"source":"startup","session_id":"root","agent_id":"child-2","session_title":"Child title"}'
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c 'import json,sys; assert "sessionTitle" not in json.load(sys.stdin)["hookSpecificOutput"]'
  after=$(cksum "$file")
  [ "$before" = "$after" ]
}
