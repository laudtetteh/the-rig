#!/usr/bin/env bats

setup() {
  export CASE_DIR="$BATS_TEST_TMPDIR/project"
  mkdir -p "$CASE_DIR/bin" "$CASE_DIR/.rig/memory/sessions/done"
  cp "$BATS_TEST_DIRNAME/../templates/project/bin/rig" "$CASE_DIR/bin/rig"
  cp "$BATS_TEST_DIRNAME/../templates/project/bin/rig-session-resolve.py" "$CASE_DIR/bin/rig-session-resolve.py"
  cp "$BATS_TEST_DIRNAME/../templates/project/bin/rig-session-index.py" "$CASE_DIR/bin/rig-session-index.py"
  cp "$BATS_TEST_DIRNAME/../templates/project/bin/rig_project_roots.py" "$CASE_DIR/bin/rig_project_roots.py"
  chmod +x "$CASE_DIR/bin/rig"
  git -C "$CASE_DIR" init -q
  git -C "$CASE_DIR" checkout -q -b feat/current
  unset RIG_SESSION_FILE RIG_SESSION_ANCHOR RIG_SESSION_PID CODEX_THREAD_ID CLAUDE_CODE_SESSION_ID
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

@test "session index covers current, explicit and external Rig projects without revealing native IDs" {
  bind_record claude current-secret >/dev/null
  other="$BATS_TEST_TMPDIR/other"; mkdir -p "$other/bin" "$other/.rig/memory/sessions"
  other=$(cd "$other" && pwd -P)
  cp "$CASE_DIR/bin/rig" "$CASE_DIR/bin/rig-session-resolve.py" "$CASE_DIR/bin/rig-session-index.py" "$CASE_DIR/bin/rig_project_roots.py" "$other/bin/"
  git -C "$other" init -q
  git -C "$other" checkout -q -b feat/other
  "$other/bin/rig" session bind --agent codex --native-session-id other-secret --source startup >/dev/null
  OTHER_DIR="$other" python3 -c 'import glob,json,os; p=glob.glob(os.environ["OTHER_DIR"]+"/.rig/memory/sessions/session-*.json")[0]; d=json.load(open(p)); d["names"]["tentative"]="Other session"; json.dump(d,open(p,"w"))'
  remote="$BATS_TEST_TMPDIR/remote"; catalog="$BATS_TEST_TMPDIR/home/.rig/projects/remote"
  mkdir -p "$remote/bin" "$catalog/memory/sessions"
  remote=$(cd "$remote" && pwd -P)
  catalog=$(cd "$catalog" && pwd -P)
  test_home=$(cd "$BATS_TEST_TMPDIR/home" && pwd -P)
  cp "$CASE_DIR/bin/rig" "$CASE_DIR/bin/rig-session-resolve.py" "$CASE_DIR/bin/rig-session-index.py" "$CASE_DIR/bin/rig_project_roots.py" "$remote/bin/"
  printf '%s\n' "$catalog" > "$remote/.rigpath"
  git -C "$remote" init -q
  git -C "$remote" checkout -q -b feat/remote
  "$remote/bin/rig" session bind --agent claude --native-session-id remote-secret --source startup >/dev/null
  run env HOME="$test_home" "$CASE_DIR/bin/rig" session index --root "$other" --json
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
  [[ "$output" != *current-secret* && "$output" != *other-secret* && "$output" != *remote-secret* ]] || return 1
  printf '%s' "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["ok"] and len(d["sessions"])==3 and len(d["coverage"]["scopes"])==3; assert all(r["provider_live_state"]=="unknown" and r["provenance"]["record"].startswith("session-") for r in d["sessions"])'
  run env HOME="$test_home" "$CASE_DIR/bin/rig" session index --root "$other" --project "$other" --provider codex --search OTHER --sort created --json --verbose
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert len(d["sessions"])==1 and d["sessions"][0]["native_session_id"]=="other-secret"'
}

@test "session index reports unsafe and ambiguous records without writing them" {
  result=$(bind_record codex private-secret)
  file=$(printf '%s' "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin)["session_file"])')
  before=$(cksum "$file")
  cp "$file" "$CASE_DIR/.rig/memory/sessions/session-duplicate.json"
  printf '{"schema_version":2}\n' > "$CASE_DIR/.rig/memory/sessions/session-future.json"
  printf 'private-secret\n' > "$BATS_TEST_TMPDIR/outside"
  ln -s "$BATS_TEST_TMPDIR/outside" "$CASE_DIR/.rig/memory/sessions/session-link.json"
  run env HOME="$BATS_TEST_TMPDIR/home" "$CASE_DIR/bin/rig" session index --json
  [ "$status" -eq 2 ]; [[ "$output" != *private-secret* ]] || return 1
  printf '%s' "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); reasons={e["reason"] for e in d["errors"]}; assert {"duplicate_anchor","unsupported_schema","unreadable_record"} <= reasons; assert len(d["sessions"])==2 and all(r["ambiguous"] and r["resume_hint"] is None for r in d["sessions"])'
  [ "$(cksum "$file")" = "$before" ]
}

@test "session index refuses cross-project records and symlinked explicit roots" {
  result=$(bind_record claude hidden-id)
  file=$(printf '%s' "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin)["session_file"])')
  SESSION_F="$file" python3 -c 'import json,os; p=os.environ["SESSION_F"]; d=json.load(open(p)); d["project"]["identity"]="0"*64; json.dump(d,open(p,"w"))'
  ln -s "$CASE_DIR" "$BATS_TEST_TMPDIR/alias"
  run env HOME="$BATS_TEST_TMPDIR/home" "$CASE_DIR/bin/rig" session index --root "$BATS_TEST_TMPDIR/alias" --json
  [ "$status" -eq 2 ]; [[ "$output" != *hidden-id* ]] || return 1
  printf '%s' "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["sessions"]==[] and {"cross_project_record","unsafe_project_root"} <= {e["reason"] for e in d["errors"]}'
}

@test "session index discovers immediate code projects and redacts IDs from paths" {
  neighbor="$BATS_TEST_TMPDIR/home/code/native-secret"
  mkdir -p "$neighbor/bin" "$neighbor/.rig/memory/sessions"
  neighbor=$(cd "$neighbor" && pwd -P)
  test_home=$(cd "$BATS_TEST_TMPDIR/home" && pwd -P)
  cp "$CASE_DIR/bin/rig" "$CASE_DIR/bin/rig-session-resolve.py" "$CASE_DIR/bin/rig-session-index.py" "$neighbor/bin/"
  git -C "$neighbor" init -q
  "$neighbor/bin/rig" session bind --agent codex --native-session-id native-secret --source startup >/dev/null
  run env HOME="$test_home" "$CASE_DIR/bin/rig" session index --json
  [ "$status" -eq 0 ]; [[ "$output" != *native-secret* ]] || return 1
  printf '%s' "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert len(d["sessions"])==1 and "code_catalog" in d["sessions"][0]["provenance"]["sources"] and "<redacted>" in d["sessions"][0]["project"]'
  run env HOME="$test_home" "$CASE_DIR/bin/rig" session index --json --verbose
  [ "$status" -eq 0 ]; [[ "$output" == *native-secret* ]] || return 1
}

@test "session index distinguishes valid continuations from ambiguous native bindings" {
  result=$(bind_record codex shared-native)
  file=$(printf '%s' "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin)["session_file"])')
  FILE="$file" python3 -c 'import json,os; p=os.environ["FILE"]; d=json.load(open(p)); d["anchor"]="second-anchor"; json.dump(d,open(p.replace(".json","-copy.json"),"w"))'
  run env HOME="$BATS_TEST_TMPDIR/home" "$CASE_DIR/bin/rig" session index --json
  [ "$status" -eq 2 ]
  printf '%s' "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert "duplicate_native_binding" in [e["reason"] for e in d["errors"]]; assert len(d["sessions"])==2 and all(r["ambiguous"] and r["resume_hint"] is None for r in d["sessions"])'
  rm "$CASE_DIR/.rig/memory/sessions/"*"-copy.json"
  FILE="$file" python3 -c 'import json,os,pathlib; p=pathlib.Path(os.environ["FILE"]); d=json.load(open(p)); d["lifecycle"]["state"]="complete"; d["lifecycle"]["last_event"]="wrap"; d["lifecycle"]["last_event_at"]=d["updated_at"]; (p.parent/"done"/p.name).write_text(json.dumps(d)); p.unlink(); child=dict(d); child["anchor"]="continuation-anchor"; child["lifecycle"]=dict(d["lifecycle"],state="active",last_event="session_start"); child["lineage"]={"kind":"continuation","parent_anchor":d["anchor"],"parent_native_session_id":"shared-native"}; (p.parent/"session-continuation-anchor.json").write_text(json.dumps(child))'
  run env HOME="$BATS_TEST_TMPDIR/home" "$CASE_DIR/bin/rig" session index --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert len(d["sessions"])==2 and all(not r["ambiguous"] and r["shared_native_binding"] for r in d["sessions"])'
}

@test "session index rejects invalid lifecycle state and active done record" {
  result=$(bind_record claude lifecycle-id)
  file=$(printf '%s' "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin)["session_file"])')
  FILE="$file" python3 -c 'import json,os,pathlib; p=pathlib.Path(os.environ["FILE"]); d=json.load(open(p)); d["lifecycle"]["state"]="paused"; p.write_text(json.dumps(d)); d["lifecycle"]["state"]="active"; d["anchor"]="done-active"; (p.parent/"done"/"session-done-active.json").write_text(json.dumps(d))'
  run env HOME="$BATS_TEST_TMPDIR/home" "$CASE_DIR/bin/rig" session index --json
  [ "$status" -eq 2 ]; [[ "$output" != *lifecycle-id* ]] || return 1
  printf '%s' "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["sessions"]==[] and [e["reason"] for e in d["errors"]].count("invalid_lifecycle")==2'
}

@test "session index includes historical PID records without inventing provider identity" {
  printf '{"anchor":"older-anchor","pid":123,"started_at":"2026-01-01T00:00:00Z","status":"complete","branch":"feat/older","final_name":"Older work"}\n' > "$CASE_DIR/.rig/memory/sessions/done/session-older-anchor.json"
  run env HOME="$BATS_TEST_TMPDIR/home" "$CASE_DIR/bin/rig" session index --project current --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); r=d["sessions"][0]; assert len(d["sessions"])==1 and r["schema"]=="legacy_pid" and r["provider"]=="unknown" and r["resume_hint"] is None and r["project_verified"] is False; assert d["coverage"]["scopes"][0]["legacy_count"]==1'
  run env HOME="$BATS_TEST_TMPDIR/home" "$CASE_DIR/bin/rig" session index --verbose
  [ "$status" -eq 0 ]; [[ "$output" != *Traceback* ]] || return 1
}

@test "session index filters unrelated project errors from a current-project query" {
  bind_record claude current-native >/dev/null
  catalog="$BATS_TEST_TMPDIR/home/.rig/projects/other"
  mkdir -p "$catalog/memory/sessions"
  test_home=$(cd "$BATS_TEST_TMPDIR/home" && pwd -P)
  printf 'not json\n' > "$catalog/memory/sessions/session-bad.json"
  run env HOME="$test_home" "$CASE_DIR/bin/rig" session index --project current --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["ok"] and len(d["sessions"])==1 and d["errors"]==[] and d["coverage"]["omitted_unrelated_errors"]==1'
}

@test "session index refuses a unique invalid continuation before offering a resume hint" {
  result=$(bind_record codex lineage-native)
  file=$(printf '%s' "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin)["session_file"])')
  FILE="$file" python3 -c 'import json,os; p=os.environ["FILE"]; d=json.load(open(p)); d["lineage"]={"kind":"continuation","parent_anchor":"missing","parent_native_session_id":"lineage-native"}; json.dump(d,open(p,"w"))'
  run env HOME="$BATS_TEST_TMPDIR/home" "$CASE_DIR/bin/rig" session index --json
  [ "$status" -eq 2 ]
  printf '%s' "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert "invalid_lineage" in [e["reason"] for e in d["errors"]] and d["sessions"][0]["ambiguous"] and d["sessions"][0]["resume_hint"] is None'
}

@test "session index invalidates both ends of a malformed root parent link" {
  first=$(bind_record claude first-native)
  first_anchor=$(printf '%s' "$first" | python3 -c 'import json,sys; print(json.load(sys.stdin)["anchor"])')
  second=$(bind_record claude second-native)
  second_file=$(printf '%s' "$second" | python3 -c 'import json,sys; print(json.load(sys.stdin)["session_file"])')
  FILE="$second_file" PARENT="$first_anchor" python3 -c 'import json,os; p=os.environ["FILE"]; d=json.load(open(p)); d["lineage"]={"kind":"root","parent_anchor":os.environ["PARENT"]}; json.dump(d,open(p,"w"))'
  run env HOME="$BATS_TEST_TMPDIR/home" "$CASE_DIR/bin/rig" session index --json
  [ "$status" -eq 2 ]
  printf '%s' "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert len(d["sessions"])==2 and all(r["ambiguous"] and r["resume_hint"] is None for r in d["sessions"]); assert [e["reason"] for e in d["errors"]].count("invalid_lineage")==2'
}

@test "session index never resolves lineage through another Rig directory" {
  first=$(bind_record codex parent-native)
  first_file=$(printf '%s' "$first" | python3 -c 'import json,sys; print(json.load(sys.stdin)["session_file"])')
  catalog="$BATS_TEST_TMPDIR/home/.rig/projects/other"
  mkdir -p "$catalog/memory/sessions"
  test_home=$(cd "$BATS_TEST_TMPDIR/home" && pwd -P)
  FILE="$first_file" CATALOG="$catalog" python3 -c 'import json,os,pathlib; p=pathlib.Path(os.environ["FILE"]); d=json.load(open(p)); d["lifecycle"]["state"]="complete"; p.write_text(json.dumps(d)); child=json.loads(json.dumps(d)); child["anchor"]="child-anchor"; child["native"]["session_id"]="child-native"; child["lifecycle"]["state"]="active"; child["lineage"]={"kind":"continuation","parent_anchor":d["anchor"],"parent_native_session_id":"parent-native"}; (pathlib.Path(os.environ["CATALOG"])/"memory/sessions/session-child-anchor.json").write_text(json.dumps(child))'
  run env HOME="$test_home" "$CASE_DIR/bin/rig" session index --json
  [ "$status" -eq 2 ]
  printf '%s' "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); child=next(r for r in d["sessions"] if r["anchor"]=="child-anchor"); assert child["ambiguous"] and child["resume_hint"] is None and "invalid_lineage" in [e["reason"] for e in d["errors"]]'
}

@test "session index invalidates a continuation parent when the child binding is wrong" {
  first=$(bind_record claude parent-native)
  first_file=$(printf '%s' "$first" | python3 -c 'import json,sys; print(json.load(sys.stdin)["session_file"])')
  first_anchor=$(printf '%s' "$first" | python3 -c 'import json,sys; print(json.load(sys.stdin)["anchor"])')
  FILE="$first_file" python3 -c 'import json,os; p=os.environ["FILE"]; d=json.load(open(p)); d["lifecycle"]["state"]="complete"; json.dump(d,open(p,"w"))'
  second=$(bind_record claude child-native)
  second_file=$(printf '%s' "$second" | python3 -c 'import json,sys; print(json.load(sys.stdin)["session_file"])')
  FILE="$second_file" PARENT="$first_anchor" python3 -c 'import json,os; p=os.environ["FILE"]; d=json.load(open(p)); d["lineage"]={"kind":"continuation","parent_anchor":os.environ["PARENT"],"parent_native_session_id":"wrong-native"}; json.dump(d,open(p,"w"))'
  run env HOME="$BATS_TEST_TMPDIR/home" "$CASE_DIR/bin/rig" session index --json
  [ "$status" -eq 2 ]
  printf '%s' "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert len(d["sessions"])==2 and all(r["ambiguous"] and r["resume_hint"] is None for r in d["sessions"]); assert [e["reason"] for e in d["errors"]].count("invalid_lineage")==2'
}

@test "session index does not promote an untyped no-PID record or corrupt output for a short native ID" {
  bind_record claude a >/dev/null
  printf '{"anchor":"fake-legacy","started_at":"2026-01-01T00:00:00Z","status":"complete"}\n' > "$CASE_DIR/.rig/memory/sessions/session-fake-legacy.json"
  run env HOME="$BATS_TEST_TMPDIR/home" "$CASE_DIR/bin/rig" session index --json
  [ "$status" -eq 2 ]
  printf '%s' "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); reasons={e["reason"] for e in d["errors"]}; assert {"unsafe_native_id_length","malformed_record"} <= reasons and d["sessions"]==[] and d["coverage"]["discovery"].startswith("current project")'
}

@test "session index redacts a rejected short native ID from path diagnostics" {
  neighbor="$BATS_TEST_TMPDIR/home/code/secret"
  mkdir -p "$neighbor/bin" "$neighbor/.rig/memory/sessions"
  neighbor=$(cd "$neighbor" && pwd -P)
  test_home=$(cd "$BATS_TEST_TMPDIR/home" && pwd -P)
  cp "$CASE_DIR/bin/rig" "$CASE_DIR/bin/rig-session-resolve.py" "$CASE_DIR/bin/rig-session-index.py" "$neighbor/bin/"
  git -C "$neighbor" init -q
  "$neighbor/bin/rig" session bind --agent codex --native-session-id secret --source startup >/dev/null
  run env HOME="$test_home" "$CASE_DIR/bin/rig" session index --json
  [ "$status" -eq 2 ]; [[ "$output" != *secret* ]] || return 1
  printf '%s' "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert "unsafe_native_id_length" in [e["reason"] for e in d["errors"]] and any("<redacted>" in x["rig_dir"] for x in d["coverage"]["scopes"])'
}

@test "session index keeps unrelated valid rows intact beside a one-letter invalid ID" {
  bind_record claude a >/dev/null
  bind_record codex healthy-native >/dev/null
  run env HOME="$BATS_TEST_TMPDIR/home" "$CASE_DIR/bin/rig" session index --json
  [ "$status" -eq 2 ]
  printf '%s' "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert len(d["sessions"])==1 and d["sessions"][0]["provider"]=="codex" and "<redacted>" not in d["sessions"][0]["project"]'
}

@test "session index attributes shared-store duplicate anchors to both projects" {
  shared="$BATS_TEST_TMPDIR/home/.rig/projects/shared"
  first="$BATS_TEST_TMPDIR/home/code/first"; second="$BATS_TEST_TMPDIR/home/code/second"
  mkdir -p "$shared/memory/sessions" "$first/bin" "$second/bin"
  shared=$(cd "$shared" && pwd -P); first=$(cd "$first" && pwd -P); second=$(cd "$second" && pwd -P)
  test_home=$(cd "$BATS_TEST_TMPDIR/home" && pwd -P)
  for project in "$first" "$second"; do
    cp "$CASE_DIR/bin/rig" "$CASE_DIR/bin/rig-session-resolve.py" "$CASE_DIR/bin/rig-session-index.py" "$project/bin/"
    printf '%s\n' "$shared" > "$project/.rigpath"
    git -C "$project" init -q
  done
  first_result=$("$first/bin/rig" session bind --agent claude --native-session-id first-native --source startup)
  first_anchor=$(printf '%s' "$first_result" | python3 -c 'import json,sys; print(json.load(sys.stdin)["anchor"])')
  second_result=$("$second/bin/rig" session bind --agent codex --native-session-id second-native --source startup)
  second_file=$(printf '%s' "$second_result" | python3 -c 'import json,sys; print(json.load(sys.stdin)["session_file"])')
  FILE="$second_file" ANCHOR="$first_anchor" python3 -c 'import json,os; p=os.environ["FILE"]; d=json.load(open(p)); d["anchor"]=os.environ["ANCHOR"]; json.dump(d,open(p,"w"))'
  run env HOME="$test_home" "$CASE_DIR/bin/rig" session index --project "$second" --json
  [ "$status" -eq 2 ]
  printf '%s' "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert len(d["sessions"])==1 and d["sessions"][0]["ambiguous"] and d["sessions"][0]["resume_hint"] is None and "duplicate_anchor" in [e["reason"] for e in d["errors"]]; assert any(x["error_count"]>=2 for x in d["coverage"]["scopes"])'
}

@test "session index escapes control characters in plain output" {
  result=$(bind_record claude control-native)
  file=$(printf '%s' "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin)["session_file"])')
  FILE="$file" python3 -c 'import json,os; p=os.environ["FILE"]; d=json.load(open(p)); d["names"]["tentative"]="first\nERROR forged\x1b[31m"; json.dump(d,open(p,"w"))'
  run env HOME="$BATS_TEST_TMPDIR/home" "$CASE_DIR/bin/rig" session index
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c 'import sys; lines=sys.stdin.read().splitlines(); assert len(lines)==2 and "\\n" in lines[0] and "\\u001b" in lines[0]'
}

@test "session index plain verbose output reveals the explicitly requested native ID" {
  bind_record codex verbose-native >/dev/null
  run env HOME="$BATS_TEST_TMPDIR/home" "$CASE_DIR/bin/rig" session index
  [ "$status" -eq 0 ]; [[ "$output" != *verbose-native* ]] || return 1
  run env HOME="$BATS_TEST_TMPDIR/home" "$CASE_DIR/bin/rig" session index --verbose
  [ "$status" -eq 0 ]; [[ "$output" == *verbose-native* ]] || return 1
}

@test "session index reports unhashable lineage fields without a traceback" {
  result=$(bind_record codex lineage-secret)
  file=$(printf '%s' "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin)["session_file"])')
  FILE="$file" python3 -c 'import json,os; p=os.environ["FILE"]; d=json.load(open(p)); d["lineage"]={"kind":"continuation","parent_anchor":[]}; json.dump(d,open(p,"w"))'
  run env HOME="$BATS_TEST_TMPDIR/home" "$CASE_DIR/bin/rig" session index --json
  [ "$status" -eq 2 ]; [[ "$output" != *Traceback* && "$output" != *lineage-secret* ]] || return 1
  printf '%s' "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["sessions"]==[] and "malformed_record" in [e["reason"] for e in d["errors"]]'
}

@test "session index refuses nonstring displayed name and branch fields" {
  result=$(bind_record claude malformed-native)
  file=$(printf '%s' "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin)["session_file"])')
  FILE="$file" python3 -c 'import json,os; p=os.environ["FILE"]; d=json.load(open(p)); d["names"]["final"]=123; json.dump(d,open(p,"w"))'
  run env HOME="$BATS_TEST_TMPDIR/home" "$CASE_DIR/bin/rig" session index --json
  [ "$status" -eq 2 ]
  printf '%s' "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["sessions"]==[] and d["errors"][0]["reason"]=="malformed_record"'
  FILE="$file" python3 -c 'import json,os; p=os.environ["FILE"]; d=json.load(open(p)); d["names"]["final"]=None; d["runtime"]["branch"]=123; json.dump(d,open(p,"w"))'
  run env HOME="$BATS_TEST_TMPDIR/home" "$CASE_DIR/bin/rig" session index --json
  [ "$status" -eq 2 ]
  printf '%s' "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["sessions"]==[] and d["errors"][0]["reason"]=="malformed_record"'
}

@test "session index skips unrelated code symlinks and reports the coverage limit" {
  bind_record claude current-native >/dev/null
  mkdir -p "$BATS_TEST_TMPDIR/home/code"
  ln -s /etc "$BATS_TEST_TMPDIR/home/code/current-native"
  test_home=$(cd "$BATS_TEST_TMPDIR/home" && pwd -P)
  run env HOME="$test_home" "$CASE_DIR/bin/rig" session index --json
  [ "$status" -eq 0 ]; [[ "$output" != *current-native* ]] || return 1
  printf '%s' "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["ok"] and len(d["sessions"])==1 and len(d["coverage"]["skipped_code_symlinks"])==1'
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

@test "repair refuses malformed nested v1 records with JSON and no write" {
  local result file anchor before
  result=$(bind_record codex old-thread)
  file=$(printf '%s' "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin)["session_file"])')
  anchor=$(printf '%s' "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin)["anchor"])')
  SESSION_F="$file" python3 -c 'import json,os; p=os.environ["SESSION_F"]; d=json.load(open(p)); d["native"]="bad type"; json.dump(d,open(p,"w"))'
  before=$(cksum "$file")
  run "$CASE_DIR/bin/rig" session repair --anchor "$anchor" --agent codex --native-session-id new-thread --json
  [ "$status" -eq 4 ]
  printf '%s' "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["reason"]=="malformed_record" and d["no_write"] is True'
  [ "$(cksum "$file")" = "$before" ]
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
