#!/usr/bin/env bats

setup() {
  export CASE_DIR="$BATS_TEST_TMPDIR/project"
  mkdir -p "$CASE_DIR/bin" "$CASE_DIR/.rig/memory/sessions/done"
  cp "$BATS_TEST_DIRNAME/../templates/project/bin/rig" "$CASE_DIR/bin/rig"
  chmod +x "$CASE_DIR/bin/rig"
  git -C "$CASE_DIR" init -q
  git -C "$CASE_DIR" checkout -q -b feat/current
  unset RIG_SESSION_FILE RIG_SESSION_ANCHOR RIG_SESSION_PID
}

bind_record() {
  "$CASE_DIR/bin/rig" session bind --agent "$1" --native-session-id "$2" --source startup
}

make_orphan() {
  SESSION_F="$1" python3 -c '
import json,os
p=os.environ["SESSION_F"]
d=json.load(open(p))
d["native"]["session_id"]=None
d["native"]["root_session_id"]=None
d["lifecycle"]["state"]="orphaned"
json.dump(d,open(p,"w"),indent=2)
'
}

@test "session current is redacted by default and verbose only on request" {
  result=$(bind_record codex native-secret)
  file=$(printf '%s' "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin)["session_file"])')
  run env RIG_SESSION_FILE="$file" "$CASE_DIR/bin/rig" session current --json
  [ "$status" -eq 0 ]; [[ "$output" != *native-secret* && "$output" == *'"confidence": "exact"'* ]] || return 1
  run env RIG_SESSION_FILE="$file" "$CASE_DIR/bin/rig" session current --agent codex --native-session-id native-secret --json --verbose
  [ "$status" -eq 0 ]; [[ "$output" == *native-secret* ]] || return 1
}

@test "session list emits safe summaries and doctor reports healthy records" {
  bind_record claude claude-secret >/dev/null
  bind_record codex codex-secret >/dev/null
  run "$CASE_DIR/bin/rig" session list --json
  [ "$status" -eq 0 ]; [[ "$output" != *secret* ]] || return 1
  printf '%s' "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["ok"] and len(d["sessions"])==2'
  run "$CASE_DIR/bin/rig" session doctor --json
  [ "$status" -eq 0 ]; printf '%s' "$output" | python3 -c 'import json,sys; assert json.load(sys.stdin)["ok"]'
}

@test "session doctor detects duplicate native bindings without exposing IDs" {
  result=$(bind_record codex duplicate-secret)
  file=$(printf '%s' "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin)["session_file"])')
  cp "$file" "$CASE_DIR/.rig/memory/sessions/session-copy.json"
  run "$CASE_DIR/bin/rig" session doctor --json
  [ "$status" -eq 2 ]; [[ "$output" != *duplicate-secret* && "$output" == *unique_native_bindings* ]] || return 1
}

@test "repair preview is read-only and confirmation writes one audited binding" {
  result=$(bind_record codex original-id)
  file=$(printf '%s' "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin)["session_file"])')
  anchor=$(printf '%s' "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin)["anchor"])')
  make_orphan "$file"; before=$(cksum "$file")
  run "$CASE_DIR/bin/rig" session repair --anchor "$anchor" --agent codex --native-session-id repaired-secret --reason orphan_recovery --json
  [ "$status" -eq 0 ]; [[ "$output" == *repair_preview* && "$output" != *repaired-secret* ]] || return 1
  token=$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["confirmation_token"])')
  [ "$before" = "$(cksum "$file")" ]; [ ! -e "$CASE_DIR/.rig/memory/sessions/repair-audit.jsonl" ]
  run "$CASE_DIR/bin/rig" session repair --anchor "$anchor" --agent codex --native-session-id repaired-secret --reason orphan_recovery --confirm "$token" --json
  [ "$status" -eq 0 ]; [[ "$output" == *repair_applied* && "$output" != *repaired-secret* ]] || return 1
  SESSION_F="$file" python3 -c 'import json,os; d=json.load(open(os.environ["SESSION_F"])); assert d["native"]["session_id"]=="repaired-secret" and d["native"]["source"]=="repair" and d["lifecycle"]["state"]=="active"'
  audit="$CASE_DIR/.rig/memory/sessions/repair-audit.jsonl"; [ -f "$audit" ]
  if grep -q 'repaired-secret\|original-id\|prompt\|transcript\|native_session_id' "$audit"; then
    return 1
  fi
  [ "$(python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "$audit")" = 0o600 ]
  run "$CASE_DIR/bin/rig" session doctor --json
  [ "$status" -eq 0 ]; [[ "$output" == *repair_audit_privacy* ]] || return 1
}

@test "repair rejects unknown options and sensitive audit reasons without writes" {
  result=$(bind_record codex orphan-id)
  file=$(printf '%s' "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin)["session_file"])')
  anchor=$(printf '%s' "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin)["anchor"])')
  make_orphan "$file"; before=$(cksum "$file")
  run "$CASE_DIR/bin/rig" session repair --anchor "$anchor" --agent codex --native-session-id sensitive-id --reason sensitive-id --confirm bogus --json
  [ "$status" -eq 3 ]; [[ "$output" == *unsafe_reason* ]] || return 1
  run "$CASE_DIR/bin/rig" session repair --anchor "$anchor" --agent codex --native-session-id safe-id --reason recovery --confirm "$anchor" --private-database /tmp/db --json
  [ "$status" -eq 3 ]; [[ "$output" == *invalid_input* ]] || return 1
  [ "$before" = "$(cksum "$file")" ]
}

@test "repair collisions fail without writes" {
  bind_record claude claimed-id >/dev/null
  second=$(bind_record claude orphan-id)
  file=$(printf '%s' "$second" | python3 -c 'import json,sys; print(json.load(sys.stdin)["session_file"])')
  anchor=$(printf '%s' "$second" | python3 -c 'import json,sys; print(json.load(sys.stdin)["anchor"])')
  make_orphan "$file"; before=$(cksum "$file")
  run "$CASE_DIR/bin/rig" session repair --anchor "$anchor" --agent claude --native-session-id claimed-id --reason recovery --confirm bogus --json
  [ "$status" -eq 2 ]; [[ "$output" == *duplicate_native_id* ]] || return 1
  [ "$before" = "$(cksum "$file")" ]
}

@test "last-resort content matching requires authorization and stays no-write without documented export" {
  result=$(bind_record codex orphan-id)
  file=$(printf '%s' "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin)["session_file"])')
  anchor=$(printf '%s' "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin)["anchor"])')
  make_orphan "$file"; before=$(cksum "$file")
  run "$CASE_DIR/bin/rig" session repair --anchor "$anchor" --agent codex --native-session-id new-id --match-transcript --json
  [ "$status" -eq 3 ]; [[ "$output" == *last_resort_not_authorized* ]] || return 1
  run "$CASE_DIR/bin/rig" session repair --anchor "$anchor" --agent codex --native-session-id new-id --authorize-last-resort --match-transcript --json
  [ "$status" -eq 4 ]; [[ "$output" == *documented_export_surface_unavailable* && "$output" == *'"no_write": true'* ]] || return 1
  [ "$before" = "$(cksum "$file")" ]
}
