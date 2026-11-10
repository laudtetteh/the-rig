#!/usr/bin/env bats

setup() {
  export CASE_DIR="$BATS_TEST_TMPDIR/project"
  mkdir -p "$CASE_DIR/bin" "$CASE_DIR/.rig/memory/sessions/done"
  cp "$BATS_TEST_DIRNAME/../templates/project/bin/rig" "$CASE_DIR/bin/rig"
  cp "$BATS_TEST_DIRNAME/../templates/project/bin/rig-session-resolve.py" "$CASE_DIR/bin/rig-session-resolve.py"
  chmod +x "$CASE_DIR/bin/rig"
  git -C "$CASE_DIR" init -q
  git -C "$CASE_DIR" checkout -q -b feat/review
  unset RIG_SESSION_FILE RIG_SESSION_ANCHOR RIG_SESSION_PID CODEX_THREAD_ID CLAUDE_CODE_SESSION_ID
}

bind_file() {
  "$CASE_DIR/bin/rig" session bind --agent "$1" --native-session-id "$2" --source startup |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["session_file"])'
}

@test "Claude launcher isolates inherited Codex identity and launcher context" {
  local codex_file fakebin
  codex_file=$(bind_file codex parent-thread)
  fakebin="$BATS_TEST_TMPDIR/fakebin"; mkdir -p "$fakebin"
  cat > "$fakebin/claude" <<'SH'
#!/usr/bin/env bash
[[ -z "${CODEX_THREAD_ID:-}" ]] || exit 11
[[ "$RIG_SESSION_FILE" != "$OLD_SESSION_FILE" ]] || exit 12
CLAUDE_CODE_SESSION_ID=claude-child "$RIG_BIN" session bind --agent claude --native-session-id claude-child --source startup >/dev/null || exit 13
CLAUDE_CODE_SESSION_ID=claude-child "$RIG_BIN" session current --json || exit 14
CLAUDE_CODE_SESSION_ID=claude-child "$RIG_BIN" session-name set --final --json 'Claude child' || exit 15
SH
  chmod +x "$fakebin/claude"
  run env PATH="$fakebin:$PATH" RIG_BIN="$CASE_DIR/bin/rig" OLD_SESSION_FILE="$codex_file" \
    CODEX_THREAD_ID=parent-thread RIG_SESSION_FILE="$codex_file" \
    "$CASE_DIR/bin/rig" claude
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c 'import json,sys; rows=[json.loads(line) for line in sys.stdin if line.strip()]; assert rows[0]["agent"]=="claude" and rows[0]["confidence"]=="exact" and rows[1]["ok"]'
  run env CODEX_THREAD_ID=parent-thread "$CASE_DIR/bin/rig" session current --agent codex --native-session-id parent-thread --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"agent": "codex"'* ]] || return 1
}

@test "Codex launcher isolates inherited Claude identity and launcher context" {
  local claude_file fakebin
  claude_file=$(bind_file claude parent-session)
  fakebin="$BATS_TEST_TMPDIR/fakebin"; mkdir -p "$fakebin"
  cat > "$fakebin/codex" <<'SH'
#!/usr/bin/env bash
[[ -z "${CLAUDE_CODE_SESSION_ID:-}" && -z "${RIG_SESSION_FILE:-}" && -z "${RIG_SESSION_ANCHOR:-}" ]] || exit 11
printf 'isolated\n'
SH
  chmod +x "$fakebin/codex"
  run env PATH="$fakebin:$PATH" CLAUDE_CODE_SESSION_ID=parent-session \
    RIG_SESSION_FILE="$claude_file" RIG_SESSION_ANCHOR=parent-anchor \
    "$CASE_DIR/bin/rig" codex
  [ "$status" -eq 0 ]
  [ "$output" = isolated ]
}

@test "raw Claude child cannot use an inherited Codex launcher file when both IDs are present" {
  local codex_file claude_file before
  codex_file=$(bind_file codex parent-thread)
  claude_file=$(bind_file claude child-thread)
  before=$(cksum "$codex_file")
  run env CODEX_THREAD_ID=parent-thread CLAUDE_CODE_SESSION_ID=child-thread RIG_SESSION_FILE="$codex_file" \
    "$CASE_DIR/bin/rig" session current --json
  [ "$status" -eq 2 ]
  printf '%s' "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["reason"]=="ambiguous_native_provider" and d["no_write"] is True'
  run env CODEX_THREAD_ID=parent-thread CLAUDE_CODE_SESSION_ID=child-thread RIG_SESSION_FILE="$codex_file" \
    "$CASE_DIR/bin/rig" session-name set --final --json 'wrong parent name'
  [ "$status" -eq 2 ]
  [ "$(cksum "$codex_file")" = "$before" ]
  run env CODEX_THREAD_ID=parent-thread CLAUDE_CODE_SESSION_ID=child-thread RIG_SESSION_FILE="$claude_file" \
    "$CASE_DIR/bin/rig" session current --json
  [ "$status" -eq 2 ]
  run env CODEX_THREAD_ID=parent-thread CLAUDE_CODE_SESSION_ID=child-thread RIG_SESSION_FILE="$codex_file" \
    "$CASE_DIR/bin/rig" session current --agent claude --native-session-id child-thread --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["agent"]=="claude" and d["reason"]=="native_id"'
  run env CODEX_THREAD_ID=parent-thread RIG_SESSION_FILE="$codex_file" \
    "$CASE_DIR/bin/rig" session current --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["agent"]=="codex" and d["reason"]=="launcher_file"'
  run env CLAUDE_CODE_SESSION_ID=child-thread RIG_SESSION_FILE="$claude_file" \
    "$CASE_DIR/bin/rig" session current --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["agent"]=="claude" and d["reason"]=="launcher_file"'
  run env CLAUDE_CODE_SESSION_ID=wrong-thread RIG_SESSION_FILE="$claude_file" \
    "$CASE_DIR/bin/rig" session current --json
  [ "$status" -eq 3 ]
  [[ "$output" == *'"reason": "native_conflict"'* ]] || return 1
}

@test "raw startup with both native provider IDs is ambiguous and cannot name either record" {
  local codex_file claude_file codex_before claude_before
  codex_file=$(bind_file codex parent-thread)
  claude_file=$(bind_file claude child-thread)
  codex_before=$(cksum "$codex_file"); claude_before=$(cksum "$claude_file")
  run env CODEX_THREAD_ID=parent-thread CLAUDE_CODE_SESSION_ID=child-thread RIG_SESSION_PID=999999 \
    "$CASE_DIR/bin/rig" session current --json
  [ "$status" -eq 2 ]
  printf '%s' "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["reason"]=="ambiguous_native_provider" and d["no_write"] is True and d["session_file"] is None'
  run env CODEX_THREAD_ID=parent-thread CLAUDE_CODE_SESSION_ID=child-thread RIG_SESSION_PID=999999 \
    "$CASE_DIR/bin/rig" session-name set --final --json 'wrong name'
  [ "$status" -eq 2 ]
  printf '%s' "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["reason"]=="ambiguous_native_provider" and d["no_write"] is True'
  [ "$(cksum "$codex_file")" = "$codex_before" ]
  [ "$(cksum "$claude_file")" = "$claude_before" ]
  run env CODEX_THREAD_ID=parent-thread CLAUDE_CODE_SESSION_ID=child-thread \
    "$CASE_DIR/bin/rig" session current --agent claude --native-session-id child-thread --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"agent": "claude"'* ]] || return 1
}

@test "v1 launcher record without a native ID cannot be named" {
  local file before
  file=$(bind_file claude nullable-thread)
  SESSION_F="$file" python3 -c 'import json,os; p=os.environ["SESSION_F"]; d=json.load(open(p)); d["native"]["session_id"]=None; json.dump(d,open(p,"w"))'
  before=$(cksum "$file")
  run env RIG_SESSION_FILE="$file" "$CASE_DIR/bin/rig" session-name set --final --json 'unsafe name'
  [ "$status" -ne 0 ]
  printf '%s' "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["reason"]=="invalid_native_binding" and d["no_write"] is True'
  run env RIG_SESSION_FILE="$file" "$CASE_DIR/bin/rig" session-name set --final --complete --json 'unsafe completion'
  [ "$status" -ne 0 ]
  printf '%s' "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["reason"]=="invalid_native_binding" and d["no_write"] is True'
  [ "$(cksum "$file")" = "$before" ]
  [ "$(find "$CASE_DIR/.rig/memory/sessions/done" -name 'session-*.json' | wc -l | tr -d ' ')" -eq 0 ]
}

@test "future schema with malformed nested shape yields structured list and doctor diagnostics" {
  local file
  file=$(bind_file codex future-thread)
  SESSION_F="$file" python3 -c 'import json,os; p=os.environ["SESSION_F"]; d=json.load(open(p)); d["schema_version"]=2; d["native"]="future shape"; d["project"]=["future shape"]; json.dump(d,open(p,"w"))'
  run "$CASE_DIR/bin/rig" session list --json
  [ "$status" -eq 2 ]
  printf '%s' "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert not d["ok"] and d["errors"][0]["reason"]=="unsupported_schema" and not d["sessions"]'
  run "$CASE_DIR/bin/rig" session doctor --json
  [ "$status" -eq 2 ]
  printf '%s' "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert not d["ok"] and d["errors"][0]["reason"]=="unsupported_schema"'
}

@test "doctor flags a cross-native continuation of an active parent" {
  local parent child
  parent=$(bind_file codex active-parent)
  child=$(bind_file codex different-child)
  PARENT_F="$parent" CHILD_F="$child" python3 -c 'import json,os; p=json.load(open(os.environ["PARENT_F"])); q=os.environ["CHILD_F"]; d=json.load(open(q)); d["lineage"]={"kind":"continuation","parent_anchor":p["anchor"],"parent_native_session_id":"active-parent"}; json.dump(d,open(q,"w"))'
  run "$CASE_DIR/bin/rig" session doctor --json
  [ "$status" -eq 2 ]
  printf '%s' "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); checks={c["name"]:c["ok"] for c in d["checks"]}; assert not checks["continuation_lineage"]'
}

@test "bind rejects a cross-native continuation of an active parent" {
  local parent before
  parent=$(bind_file codex active-parent)
  before=$(cksum "$parent")
  run "$CASE_DIR/bin/rig" session bind --agent codex --native-session-id different-child --parent-native-session-id active-parent --source resume --allow-continuation
  [ "$status" -eq 3 ]
  printf '%s' "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["reason"]=="invalid_continuation_lineage" and d["no_write"] is True'
  [ "$(cksum "$parent")" = "$before" ]
  [ "$(find "$CASE_DIR/.rig/memory/sessions" -maxdepth 1 -name 'session-*.json' | wc -l | tr -d ' ')" -eq 1 ]
}

@test "bind accepts a cross-native continuation after its parent completes" {
  local parent child
  parent=$(bind_file codex completed-parent)
  run env RIG_SESSION_FILE="$parent" "$CASE_DIR/bin/rig" session-name set --final --complete 'completed work'
  [ "$status" -eq 0 ]
  run "$CASE_DIR/bin/rig" session bind --agent codex --native-session-id new-child \
    --parent-native-session-id completed-parent --source resume --allow-continuation
  [ "$status" -eq 0 ]
  child=$(printf '%s' "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["lineage"]["kind"]=="continuation"; print(d["session_file"])')
  [ -f "$child" ]
  run "$CASE_DIR/bin/rig" session doctor --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); checks={c["name"]:c["ok"] for c in d["checks"]}; assert checks["continuation_lineage"]'
}
