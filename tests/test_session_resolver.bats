#!/usr/bin/env bats

setup() {
  export CASE_DIR="$BATS_TEST_TMPDIR/project"
  mkdir -p "$CASE_DIR/bin" "$CASE_DIR/.rig/memory/sessions/done"
  cp "$BATS_TEST_DIRNAME/../templates/project/bin/rig" "$CASE_DIR/bin/rig"
  cp "$BATS_TEST_DIRNAME/../templates/project/bin/rig-tab-title-watch" "$CASE_DIR/bin/rig-tab-title-watch"
  chmod +x "$CASE_DIR/bin/rig" "$CASE_DIR/bin/rig-tab-title-watch"
  git -C "$CASE_DIR" init -q
  git -C "$CASE_DIR" checkout -q -b feat/current
  unset RIG_SESSION_FILE RIG_SESSION_ANCHOR RIG_SESSION_PID RIG_SESSION_BRANCH
}

write_session() {
  local path="$1" anchor="$2" branch="$3" status="${4:-active}"
  SESSION_F="$path" ANCHOR="$anchor" BRANCH="$branch" STATUS="$status" python3 -c 'import json,os; json.dump({"anchor":os.environ["ANCHOR"],"pid":123,"branch":os.environ["BRANCH"],"status":os.environ["STATUS"],"tentative_name":None,"final_name":None},open(os.environ["SESSION_F"],"w"))'
}

@test "resolver uses launcher file before all fallback signals" {
  write_session "$CASE_DIR/.rig/memory/sessions/session-1.json" launcher feat/other
  write_session "$CASE_DIR/.rig/memory/sessions/session-2.json" fallback feat/current
  run env RIG_SESSION_FILE="$CASE_DIR/.rig/memory/sessions/session-1.json" "$CASE_DIR/bin/rig" session resolve --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"anchor": "launcher"'* && "$output" == *'"confidence": "exact"'* ]]
}

@test "resolver never infers from branch or lone active records" {
  write_session "$CASE_DIR/.rig/memory/sessions/session-1.json" one feat/current
  write_session "$CASE_DIR/.rig/memory/sessions/session-2.json" two feat/current
  write_session "$CASE_DIR/.rig/memory/sessions/done/session-old.json" done feat/current complete
  run env RIG_SESSION_PID=999999 "$CASE_DIR/bin/rig" session resolve --json
  [ "$status" -eq 1 ]
  [[ "$output" == *'"reason": "not_found"'* ]]
  [[ "$output" != *'/done/'* ]]
}

@test "invalid explicit launcher file fails closed instead of selecting another session" {
  write_session "$CASE_DIR/.rig/memory/sessions/session-1.json" other feat/current
  write_session "$CASE_DIR/.rig/memory/sessions/done/session-old.json" done feat/current complete
  run env RIG_SESSION_FILE="$CASE_DIR/.rig/memory/sessions/done/session-old.json" "$CASE_DIR/bin/rig" session resolve --json
  [ "$status" -eq 3 ]
  [[ "$output" == *'"session_file": null'* && "$output" == *'"reason": "invalid_launcher_file"'* ]]
  [[ "$output" != *'session-1.json'* ]]
}

@test "unmatched explicit launcher anchor fails closed" {
  write_session "$CASE_DIR/.rig/memory/sessions/session-1.json" other feat/current
  run env RIG_SESSION_ANCHOR=missing "$CASE_DIR/bin/rig" session resolve --json
  [ "$status" -eq 3 ]
  [[ "$output" == *'"reason": "launcher_anchor_not_found"'* && "$output" != *'session-1.json'* ]]
}

@test "resolver supports legacy PPID sentinel" {
  write_session "$CASE_DIR/.rig/memory/sessions/session-7.json" legacy feat/other
  printf legacy > /tmp/.rig-session-778899.uuid
  run env RIG_SESSION_PID=778899 "$CASE_DIR/bin/rig" session resolve --json
  rm -f /tmp/.rig-session-778899.uuid
  [ "$status" -eq 0 ]
  [[ "$output" == *'"reason": "anchor"'* ]]
}

@test "atomic writer preserves shell metacharacters and newlines literally" {
  local file="$CASE_DIR/.rig/memory/sessions/session-1.json" name
  write_session "$file" safe feat/current
  name=$'$(touch /tmp/rig-343-injected); `nope` "quote"\nsecond line'
  run env RIG_SESSION_FILE="$file" "$CASE_DIR/bin/rig" session-name set --final "$name"
  [ "$status" -eq 0 ]
  [ ! -e /tmp/rig-343-injected ]
  SESSION_F="$file" EXPECTED="$name" python3 -c 'import json,os; assert json.load(open(os.environ["SESSION_F"]))["final_name"] == os.environ["EXPECTED"]'
}

@test "watcher title priority is final then tentative then project branch then project" {
  local file="$CASE_DIR/.rig/memory/sessions/session-1.json" tty="$BATS_TEST_TMPDIR/tty"
  write_session "$file" a feat/current
  : > "$tty"
  python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["tentative_name"]="tent"; d["final_name"]="final"; json.dump(d,open(p,"w"))' "$file"
  run env RIG_SESSION_FILE="$file" RIG_PROJECT_NAME=demo RIG_TITLE_TTY="$tty" RIG_TITLE_ONCE=1 "$CASE_DIR/bin/rig-tab-title-watch"
  [ "$status" -eq 0 ]; [[ "$(<"$tty")" == *'final'* ]]
  python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["final_name"]=None; json.dump(d,open(p,"w"))' "$file"; : > "$tty"
  env RIG_SESSION_FILE="$file" RIG_PROJECT_NAME=demo RIG_TITLE_TTY="$tty" RIG_TITLE_ONCE=1 "$CASE_DIR/bin/rig-tab-title-watch"
  [[ "$(<"$tty")" == *'tent'* ]]
  python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["tentative_name"]=None; json.dump(d,open(p,"w"))' "$file"; : > "$tty"
  env RIG_SESSION_FILE="$file" RIG_PROJECT_NAME=demo RIG_TITLE_TTY="$tty" RIG_TITLE_ONCE=1 "$CASE_DIR/bin/rig-tab-title-watch"
  [[ "$(<"$tty")" == *'demo: feat/current'* ]]
}

@test "watcher exits quietly when tty is unwritable" {
  write_session "$CASE_DIR/.rig/memory/sessions/session-1.json" a feat/current
  run env RIG_SESSION_FILE="$CASE_DIR/.rig/memory/sessions/session-1.json" RIG_TITLE_TTY="$BATS_TEST_TMPDIR/missing/tty" "$CASE_DIR/bin/rig-tab-title-watch"
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "watcher notices a live name change" {
  local file="$CASE_DIR/.rig/memory/sessions/session-1.json" tty="$BATS_TEST_TMPDIR/tty"
  write_session "$file" a feat/current; : > "$tty"
  run env SESSION_F="$file" WATCHER="$CASE_DIR/bin/rig-tab-title-watch" TITLE_TTY="$tty" bash -c '
    RIG_SESSION_FILE="$SESSION_F" RIG_PROJECT_NAME=demo RIG_TITLE_TTY="$TITLE_TTY" RIG_TITLE_INTERVAL=.05 "$WATCHER" & watcher_pid=$!
    sleep .25
    python3 -c '\''import json,os; p=os.environ["SESSION_F"]; d=json.load(open(p)); d["final_name"]="changed"; json.dump(d,open(p,"w"))'\''
    sleep .25
    kill "$watcher_pid" 2>/dev/null || true
    wait "$watcher_pid" 2>/dev/null || true
  '
  [ "$status" -eq 0 ]; [[ "$(<"$tty")" == *changed* ]]
}

@test "watcher strips terminal controls and preserves printable metacharacters byte-for-byte" {
  local file="$CASE_DIR/.rig/memory/sessions/session-1.json" tty="$BATS_TEST_TMPDIR/tty"
  write_session "$file" a feat/current; : > "$tty"
  SESSION_F="$file" python3 -c 'import json,os; p=os.environ["SESSION_F"]; d=json.load(open(p)); d["final_name"]="safe;$() `tick`\033]0;INJECT\007\r\nnext\u0085end"; json.dump(d,open(p,"w"))'
  env RIG_SESSION_FILE="$file" RIG_PROJECT_NAME=demo RIG_TITLE_TTY="$tty" RIG_TITLE_ONCE=1 "$CASE_DIR/bin/rig-tab-title-watch"
  TTY_F="$tty" python3 -c 'import os; assert open(os.environ["TTY_F"],"rb").read() == b"\x1b]0;safe;$() `tick`]0;INJECT nextend\x07"'
}

@test "codex launcher execs native codex without starting title watcher" {
  mkdir -p "$BATS_TEST_TMPDIR/fakebin"
  printf '#!/usr/bin/env bash\nprintf "codex:%%s watcher:%%s\\n" "$*" "${RIG_SESSION_FILE:-unset}"\n' > "$BATS_TEST_TMPDIR/fakebin/codex"
  chmod +x "$BATS_TEST_TMPDIR/fakebin/codex"
  run env PATH="$BATS_TEST_TMPDIR/fakebin:$PATH" "$CASE_DIR/bin/rig" codex -- --help
  [ "$status" -eq 0 ]; [[ "$output" == 'codex:--help watcher:'* ]]
}

@test "native bind creates a redacted versioned record and exact resolve is read-only" {
  run "$CASE_DIR/bin/rig" session bind --agent codex --native-session-id thread-secret --source startup
  [ "$status" -eq 0 ]
  local file
  file=$(printf '%s' "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["native_session_id"] is None; print(d["session_file"])')
  SESSION_F="$file" python3 -c 'import json,os; d=json.load(open(os.environ["SESSION_F"])); assert d["schema_version"]==1 and d["agent"]=="codex" and d["native"]["session_id"]=="thread-secret" and d["lifecycle"]["state"]=="active"'
  local before after
  before=$(cksum "$file")
  run "$CASE_DIR/bin/rig" session resolve --agent codex --native-session-id thread-secret --json
  [ "$status" -eq 0 ]; [[ "$output" == *'"reason": "native_id"'* && "$output" != *'thread-secret'* ]]
  after=$(cksum "$file"); [ "$before" = "$after" ]
}

@test "native resolver fails closed on wrong project and duplicate bindings" {
  run "$CASE_DIR/bin/rig" session bind --agent claude --native-session-id native-a --source startup
  [ "$status" -eq 0 ]
  local file duplicate
  file=$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["session_file"])')
  duplicate="$CASE_DIR/.rig/memory/sessions/session-duplicate.json"
  cp "$file" "$duplicate"
  run "$CASE_DIR/bin/rig" session resolve --agent claude --native-session-id native-a --json
  [ "$status" -eq 2 ]; [[ "$output" == *'"reason": "duplicate_native_id"'* ]]
}

@test "native binding rejects a launcher hint already bound to another ID without writing" {
  run "$CASE_DIR/bin/rig" session bind --agent claude --native-session-id native-a --source startup
  [ "$status" -eq 0 ]
  local file before after
  file=$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["session_file"])')
  before=$(cksum "$file")
  run env RIG_SESSION_FILE="$file" "$CASE_DIR/bin/rig" session bind --agent claude --native-session-id native-b --source startup
  [ "$status" -eq 3 ]; [[ "$output" == *'"reason": "native_conflict"'* ]]
  after=$(cksum "$file"); [ "$before" = "$after" ]
}

@test "native resolution rejects malformed and future records without writes" {
  local bad="$CASE_DIR/.rig/memory/sessions/session-bad.json" before after
  printf '{bad json' > "$bad"; before=$(cksum "$bad")
  run "$CASE_DIR/bin/rig" session resolve --agent codex --native-session-id missing --json
  [ "$status" -eq 4 ]; [[ "$output" == *'"reason": "malformed_record"'* ]]
  after=$(cksum "$bad"); [ "$before" = "$after" ]
}

@test "session-name mutates v1 names and revision through exact launcher record" {
  run "$CASE_DIR/bin/rig" session bind --agent codex --native-session-id native-name --source startup
  [ "$status" -eq 0 ]
  local file
  file=$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["session_file"])')
  run env RIG_SESSION_FILE="$file" "$CASE_DIR/bin/rig" session-name set --final 'fix exact identity'
  [ "$status" -eq 0 ]
  SESSION_F="$file" python3 -c 'import json,os; d=json.load(open(os.environ["SESSION_F"])); assert d["names"]["final"]=="fix exact identity" and d["revision"]==2 and "final_name" not in d'
}

@test "concurrent bootstrap for one native ID converges on one record" {
  run env RIG_BIN="$CASE_DIR/bin/rig" OUT_A="$BATS_TEST_TMPDIR/a" OUT_B="$BATS_TEST_TMPDIR/b" bash -c '
    "$RIG_BIN" session bind --agent codex --native-session-id concurrent --source startup >"$OUT_A" & a=$!
    "$RIG_BIN" session bind --agent codex --native-session-id concurrent --source startup >"$OUT_B" & b=$!
    wait "$a"; wait "$b"
  '
  [ "$status" -eq 0 ]
  [ "$(find "$CASE_DIR/.rig/memory/sessions" -name 'session-*.json' | wc -l | tr -d ' ')" -eq 1 ]
  A="$BATS_TEST_TMPDIR/a" B="$BATS_TEST_TMPDIR/b" python3 -c 'import json,os; a=json.load(open(os.environ["A"])); b=json.load(open(os.environ["B"])); assert a["anchor"]==b["anchor"]'
}

@test "claude launcher creates identity and exports exact resolver context" {
  mkdir -p "$BATS_TEST_TMPDIR/fakebin"
  printf '#!/usr/bin/env bash\nprintf "file=%%s anchor=%%s pid=%%s project=%%s args=%%s\\n" "$RIG_SESSION_FILE" "$RIG_SESSION_ANCHOR" "$RIG_SESSION_PID" "$RIG_PROJECT_NAME" "$*"\n' > "$BATS_TEST_TMPDIR/fakebin/claude"
  chmod +x "$BATS_TEST_TMPDIR/fakebin/claude"
  run env PATH="$BATS_TEST_TMPDIR/fakebin:$PATH" RIG_TITLE_ONCE=1 RIG_TITLE_TTY="$BATS_TEST_TMPDIR/tty" "$CASE_DIR/bin/rig" claude -- --model test
  [ "$status" -eq 0 ]
  [[ "$output" == file=*'/memory/sessions/session-'* && "$output" == *' anchor='* && "$output" == *' project=project args=--model test'* ]]
}

@test "pre-compact hook prefers launcher file and pid" {
  local file="$CASE_DIR/.rig/memory/sessions/session-launcher.json"
  mkdir -p "$CASE_DIR/.rig/memory" "$CASE_DIR/.rig/tasks/active"
  write_session "$file" env-anchor feat/env
  printf '# Snapshot\n\n---\n' > "$CASE_DIR/.rig/memory/CONTEXT_SNAPSHOT.md"
  printf '# Progress\n' > "$CASE_DIR/.rig/memory/PROGRESS.md"
  run env RIG_SESSION_FILE="$file" RIG_SESSION_PID=424242 bash -c 'cd "$1" && bash "$2"' _ "$CASE_DIR" "$BATS_TEST_DIRNAME/../templates/project/.claude/hooks/pre-compact.sh"
  [ "$status" -eq 0 ]
  [ -f "$CASE_DIR/.rig/memory/.compact-checkpoint-env-anchor.md" ]
  /usr/bin/grep -q 'Session anchor:\*\* env-anchor' "$CASE_DIR/.rig/memory/.compact-checkpoint-env-anchor.md"
}
