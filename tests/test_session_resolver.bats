#!/usr/bin/env bats

setup() {
  export CASE_DIR="$BATS_TEST_TMPDIR/project"
  mkdir -p "$CASE_DIR/bin" "$CASE_DIR/.rig/memory/sessions/done"
  cp "$BATS_TEST_DIRNAME/../templates/project/bin/rig" "$CASE_DIR/bin/rig"
  cp "$BATS_TEST_DIRNAME/../templates/project/bin/rig-session-resolve.py" "$CASE_DIR/bin/rig-session-resolve.py"
  cp "$BATS_TEST_DIRNAME/../templates/project/bin/rig-tab-title-watch" "$CASE_DIR/bin/rig-tab-title-watch"
  mkdir -p "$CASE_DIR/.claude/hooks"
  cp "$BATS_TEST_DIRNAME/../templates/project/.claude/hooks/prompt-submit.sh" "$CASE_DIR/.claude/hooks/prompt-submit.sh"
  cp "$BATS_TEST_DIRNAME/../templates/project/.claude/hooks/stop.sh" "$CASE_DIR/.claude/hooks/stop.sh"
  chmod +x "$CASE_DIR/bin/rig" "$CASE_DIR/bin/rig-tab-title-watch"
  git -C "$CASE_DIR" init -q
  git -C "$CASE_DIR" checkout -q -b feat/current
  unset RIG_SESSION_FILE RIG_SESSION_ANCHOR RIG_SESSION_PID RIG_SESSION_BRANCH CODEX_THREAD_ID CLAUDE_CODE_SESSION_ID
}

@test "macOS Bash 3.2 current without a record reports a reason for JSON and human callers" {
  run env RIG_SESSION_PID=999999 /bin/bash "$CASE_DIR/bin/rig" session current --json
  [ "$status" -eq 1 ]
  [[ "$output" == *'"reason": "not_found"'* ]] || return 1
  [[ "$output" != *'unbound variable'* ]] || return 1

  run env RIG_SESSION_PID=999999 /bin/bash "$CASE_DIR/bin/rig" session current
  [ "$status" -eq 1 ]
  [[ "$output" == *'session not resolved: not_found'* ]] || return 1
  [[ "$output" != *'unbound variable'* ]] || return 1

  run env RIG_SESSION_PID=999999 /bin/bash "$CASE_DIR/bin/rig" session resolve
  [ "$status" -eq 1 ]
  [[ "$output" == *'session not resolved: not_found'* ]] || return 1
}

@test "resolver and current exact lookup work in a read-only process sandbox" {
  [ -x /usr/bin/sandbox-exec ] || skip "macOS sandbox-exec is unavailable"
  write_session "$CASE_DIR/.rig/memory/sessions/session-1.json" exact feat/current
  session_file="$CASE_DIR/.rig/memory/sessions/session-1.json"
  run /usr/bin/sandbox-exec -p '(version 1) (allow default) (deny file-write*)' \
    env RIG_SESSION_FILE="$session_file" /bin/bash "$CASE_DIR/bin/rig" session resolve --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"anchor": "exact"'* ]] || return 1

  run /usr/bin/sandbox-exec -p '(version 1) (allow default) (deny file-write*)' \
    env RIG_SESSION_FILE="$session_file" /bin/bash "$CASE_DIR/bin/rig" session current --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"anchor": "exact"'* ]] || return 1
}

@test "installer ships and manifests the read-only resolver helper" {
  installed="$BATS_TEST_TMPDIR/installed"
  external_rig="$BATS_TEST_TMPDIR/rig-external"
  mkdir -p "$installed"
  git -C "$installed" init -q
  run bash "$BATS_TEST_DIRNAME/../install.sh" --project-only --target "$installed" \
    --project-name Test --tracking stealth --rig-dir "$external_rig" --strategy upgrade
  [ "$status" -eq 0 ]
  [ -f "$installed/bin/rig-session-resolve.py" ]
  grep -q 'bin/rig-session-resolve.py' "$external_rig/memory/.rig-manifest"
  run env RIG_SESSION_PID=999999 "$installed/bin/rig" session resolve --json
  [ "$status" -eq 1 ]
  [[ "$output" == *'"reason": "not_found"'* ]] || return 1
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
  [[ "$output" == *'"anchor": "launcher"'* && "$output" == *'"confidence": "exact"'* ]] || return 1
}

@test "resolver never infers from branch or lone active records" {
  write_session "$CASE_DIR/.rig/memory/sessions/session-1.json" one feat/current
  write_session "$CASE_DIR/.rig/memory/sessions/session-2.json" two feat/current
  write_session "$CASE_DIR/.rig/memory/sessions/done/session-old.json" done feat/current complete
  run env RIG_SESSION_PID=999999 "$CASE_DIR/bin/rig" session resolve --json
  [ "$status" -eq 1 ]
  [[ "$output" == *'"reason": "not_found"'* ]] || return 1
  [[ "$output" != *'/done/'* ]] || return 1
}

@test "invalid explicit launcher file fails closed instead of selecting another session" {
  write_session "$CASE_DIR/.rig/memory/sessions/session-1.json" other feat/current
  write_session "$CASE_DIR/.rig/memory/sessions/done/session-old.json" done feat/current complete
  run env RIG_SESSION_FILE="$CASE_DIR/.rig/memory/sessions/done/session-old.json" "$CASE_DIR/bin/rig" session resolve --json
  [ "$status" -eq 3 ]
  [[ "$output" == *'"session_file": null'* && "$output" == *'"reason": "invalid_launcher_file"'* ]] || return 1
  [[ "$output" != *'session-1.json'* ]] || return 1
}

@test "resolver rejects an outside launcher path without reading or writing it" {
  local outside="$BATS_TEST_TMPDIR/outside-session.json" before after
  write_session "$outside" outside feat/outside
  before=$(cksum "$outside")
  run env RIG_SESSION_FILE="$outside" "$CASE_DIR/bin/rig" session resolve --json
  [ "$status" -eq 3 ]
  [[ "$output" == *'"reason": "invalid_launcher_file"'* && "$output" == *'"session_file": null'* ]] || return 1
  after=$(cksum "$outside"); [ "$before" = "$after" ]
}

@test "resolver rejects traversal and symlink launcher paths" {
  local outside="$BATS_TEST_TMPDIR/outside-session.json" link="$CASE_DIR/.rig/memory/sessions/session-link.json"
  write_session "$outside" outside feat/outside
  ln -s "$outside" "$link"
  run env RIG_SESSION_FILE="$CASE_DIR/.rig/memory/sessions/../sessions/session-link.json" "$CASE_DIR/bin/rig" session resolve --json
  [ "$status" -eq 3 ]
  [[ "$output" == *'"reason": "invalid_launcher_file"'* ]] || return 1
  rm "$link"
  ln -s "$CASE_DIR/.rig/memory/sessions/missing.json" "$link"
  run env RIG_SESSION_FILE="$link" "$CASE_DIR/bin/rig" session resolve --json
  [ "$status" -eq 3 ]
  [[ "$output" == *'"reason": "invalid_launcher_file"'* ]] || return 1
}

@test "unmatched explicit launcher anchor fails closed" {
  write_session "$CASE_DIR/.rig/memory/sessions/session-1.json" other feat/current
  run env RIG_SESSION_ANCHOR=missing "$CASE_DIR/bin/rig" session resolve --json
  [ "$status" -eq 3 ]
  [[ "$output" == *'"reason": "launcher_anchor_not_found"'* && "$output" != *'session-1.json'* ]] || return 1
}

@test "resolver supports legacy PPID sentinel" {
  write_session "$CASE_DIR/.rig/memory/sessions/session-7.json" legacy feat/other
  printf legacy > /tmp/.rig-session-778899.uuid
  run env RIG_SESSION_PID=778899 "$CASE_DIR/bin/rig" session resolve --json
  rm -f /tmp/.rig-session-778899.uuid
  [ "$status" -eq 0 ]
  [[ "$output" == *'"reason": "anchor"'* ]] || return 1
}

write_native_session() {
  # Writes a v1-schema record, matching the exact shape session_bind produces,
  # so it is eligible for native-id matching (unlike write_session's legacy
  # shape, which has no schema_version/native/project fields at all).
  local path="$1" anchor="$2" native_id="$3" state="${4:-active}" agent="${5:-claude}" project_identity
  project_identity=$(git -C "$CASE_DIR" rev-parse --git-common-dir 2>/dev/null)
  project_identity=$(SHA_INPUT="$(cd "$CASE_DIR" && cd "$project_identity" && pwd -P)" python3 -c 'import hashlib,os; print(hashlib.sha256(os.environ["SHA_INPUT"].encode()).hexdigest())')
  PATH_F="$path" ANCHOR="$anchor" NATIVE="$native_id" STATE="$state" PROJECT_ID="$project_identity" AGENT="$agent" python3 -c '
import json, os
json.dump({
    "schema_version": 1, "anchor": os.environ["ANCHOR"], "agent": os.environ["AGENT"],
    "native": {"session_id": os.environ["NATIVE"]},
    "project": {"identity": os.environ["PROJECT_ID"]},
    "lifecycle": {"state": os.environ["STATE"]}, "revision": 1
}, open(os.environ["PATH_F"], "w"))'
}

@test "resolver binds an ambient Claude host session id with no launcher file or PID sentinel" {
  write_native_session "$CASE_DIR/.rig/memory/sessions/session-native.json" native-anchor ambient-native-id
  run env CLAUDE_CODE_SESSION_ID=ambient-native-id RIG_SESSION_PID=999999 "$CASE_DIR/bin/rig" session resolve --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"anchor": "native-anchor"'* && "$output" == *'"confidence": "exact"'* && "$output" == *'"reason": "native_id"'* ]] || return 1
}

@test "resolver binds an ambient Codex thread id with no launcher file or PID sentinel" {
  write_native_session "$CASE_DIR/.rig/memory/sessions/session-codex-native.json" codex-anchor codex-thread-id active codex
  run env CODEX_THREAD_ID=codex-thread-id RIG_SESSION_PID=999999 "$CASE_DIR/bin/rig" session resolve --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"anchor": "codex-anchor"'* && "$output" == *'"agent": "codex"'* && "$output" == *'"reason": "native_id"'* ]] || return 1
}

@test "resolver prefers Codex thread id when both native host env vars are present" {
  write_native_session "$CASE_DIR/.rig/memory/sessions/session-claude-native.json" claude-anchor claude-native-id active claude
  write_native_session "$CASE_DIR/.rig/memory/sessions/session-codex-native.json" codex-anchor codex-thread-id active codex
  run env CLAUDE_CODE_SESSION_ID=claude-native-id CODEX_THREAD_ID=codex-thread-id RIG_SESSION_PID=999999 "$CASE_DIR/bin/rig" session resolve --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"anchor": "codex-anchor"'* && "$output" == *'"agent": "codex"'* && "$output" == *'"reason": "native_id"'* ]] || return 1
}

@test "ambient native session id fails closed on a duplicate binding instead of guessing" {
  write_native_session "$CASE_DIR/.rig/memory/sessions/session-native-a.json" anchor-a dup-native-id
  write_native_session "$CASE_DIR/.rig/memory/sessions/session-native-b.json" anchor-b dup-native-id
  run env CLAUDE_CODE_SESSION_ID=dup-native-id "$CASE_DIR/bin/rig" session resolve --json
  [ "$status" -eq 2 ]
  [[ "$output" == *'"reason": "duplicate_native_id"'* ]] || return 1
}

@test "ambient native session id bound to another project fails closed instead of falling back" {
  write_native_session "$CASE_DIR/.rig/memory/sessions/session-foreign.json" foreign-anchor foreign-native-id
  PATH_F="$CASE_DIR/.rig/memory/sessions/session-foreign.json" python3 -c 'import json,os; p=os.environ["PATH_F"]; d=json.load(open(p)); d["project"]["identity"]="a-different-project"; json.dump(d,open(p,"w"))'
  run env CLAUDE_CODE_SESSION_ID=foreign-native-id "$CASE_DIR/bin/rig" session resolve --json
  [ "$status" -eq 3 ]
  [[ "$output" == *'"reason": "cross_project"'* ]] || return 1
}

@test "ambient native session id with no matching record falls through to legacy anchor fallback unchanged" {
  write_session "$CASE_DIR/.rig/memory/sessions/session-7.json" legacy feat/other
  printf legacy > /tmp/.rig-session-778899.uuid
  run env CLAUDE_CODE_SESSION_ID=unrelated-id RIG_SESSION_PID=778899 "$CASE_DIR/bin/rig" session resolve --json
  rm -f /tmp/.rig-session-778899.uuid
  [ "$status" -eq 0 ]
  [[ "$output" == *'"reason": "anchor"'* && "$output" == *'"anchor": "legacy"'* ]] || return 1
}

@test "ambient native session id that matches nothing at all still fails closed with not_found" {
  write_session "$CASE_DIR/.rig/memory/sessions/session-1.json" one feat/current
  run env CLAUDE_CODE_SESSION_ID=nothing-matches-this RIG_SESSION_PID=999999 "$CASE_DIR/bin/rig" session resolve --json
  [ "$status" -eq 1 ]
  [[ "$output" == *'"reason": "not_found"'* ]] || return 1
}

@test "ambient native session id does not resolve a completed session" {
  write_native_session "$CASE_DIR/.rig/memory/sessions/done/session-ended.json" ended-anchor ended-native-id complete
  run env CLAUDE_CODE_SESSION_ID=ended-native-id "$CASE_DIR/bin/rig" session resolve --json
  [ "$status" -eq 3 ]
  [[ "$output" == *'"reason": "ended_record"'* ]] || return 1
}

@test "an active record in done cannot be a continuation parent" {
  first=$("$CASE_DIR/bin/rig" session bind --agent claude --native-session-id corrupt-parent --source startup)
  first_file=$(printf '%s' "$first" | python3 -c 'import json,sys; print(json.load(sys.stdin)["session_file"])')
  run env RIG_SESSION_FILE="$first_file" "$CASE_DIR/bin/rig" session-name set --final --complete 'first wrap'
  [ "$status" -eq 0 ]
  done_file=$(find "$CASE_DIR/.rig/memory/sessions/done" -name 'session-*.json' -print | head -1)
  DONE_F="$done_file" python3 -c 'import json,os; p=os.environ["DONE_F"]; d=json.load(open(p)); d["lifecycle"]["state"]="active"; json.dump(d,open(p,"w"))'

  run "$CASE_DIR/bin/rig" session resolve --agent claude --native-session-id corrupt-parent --json
  [ "$status" -eq 3 ]; [[ "$output" == *'"reason": "invalid_lifecycle_transition"'* ]] || return 1
  run "$CASE_DIR/bin/rig" session bind --agent claude --native-session-id corrupt-parent --source resume --allow-continuation
  [ "$status" -eq 3 ]; [[ "$output" == *'"reason": "invalid_lifecycle_transition"'* ]] || return 1
  [ "$(find "$CASE_DIR/.rig/memory/sessions" -maxdepth 1 -name 'session-*.json' | wc -l | tr -d ' ')" -eq 0 ]

  DONE_F="$done_file" python3 -c 'import json,os; p=os.environ["DONE_F"]; d=json.load(open(p)); d["lifecycle"]["state"]="complete"; json.dump(d,open(p,"w"))'
  second=$("$CASE_DIR/bin/rig" session bind --agent claude --native-session-id corrupt-parent --source resume --allow-continuation)
  second_file=$(printf '%s' "$second" | python3 -c 'import json,sys; print(json.load(sys.stdin)["session_file"])')
  DONE_F="$done_file" python3 -c 'import json,os; p=os.environ["DONE_F"]; d=json.load(open(p)); d["lifecycle"]["state"]="active"; json.dump(d,open(p,"w"))'
  before=$(cksum "$second_file")
  run "$CASE_DIR/bin/rig" session resolve --agent claude --native-session-id corrupt-parent --json
  [ "$status" -eq 2 ]; [[ "$output" == *'"reason": "duplicate_native_id"'* ]] || return 1
  run "$CASE_DIR/bin/rig" session bind --agent claude --native-session-id corrupt-parent --source resume --allow-continuation
  [ "$status" -eq 2 ]; [[ "$output" == *'"reason": "duplicate_native_id"'* ]] || return 1
  run "$CASE_DIR/bin/rig" session doctor --json
  [ "$status" -eq 2 ]
  printf '%s' "$output" | python3 -c 'import json,sys; checks={c["name"]:c["ok"] for c in json.load(sys.stdin)["checks"]}; assert not checks["continuation_lineage"] and not checks["unique_native_bindings"]'
  run env CLAUDE_CODE_SESSION_ID=corrupt-parent "$CASE_DIR/bin/rig" session-name set --final --json 'unsafe name'
  [ "$status" -eq 2 ]; [[ "$output" == *'"reason": "duplicate_native_id"'* ]] || return 1
  [ "$(cksum "$second_file")" = "$before" ]
}

@test "SessionEnd inactive record continues on prompt-only resume and keeps exact launcher identity" {
  first=$("$CASE_DIR/bin/rig" session bind --agent claude --native-session-id prompt-inactive --source startup)
  first_file=$(printf '%s' "$first" | python3 -c 'import json,sys; print(json.load(sys.stdin)["session_file"])')
  first_anchor=$(printf '%s' "$first" | python3 -c 'import json,sys; print(json.load(sys.stdin)["anchor"])')
  end_payload='{"source":"logout","session_id":"prompt-inactive"}'
  run env RIG_SESSION_LOG="$BATS_TEST_TMPDIR/session.log" bash -c 'cd "$1" && printf "%s" "$2" | bash .claude/hooks/stop.sh' _ "$CASE_DIR" "$end_payload"
  [ "$status" -eq 0 ]
  SESSION_F="$first_file" python3 -c 'import json,os; d=json.load(open(os.environ["SESSION_F"])); assert d["lifecycle"]["state"]=="inactive"'
  run "$CASE_DIR/bin/rig" session resolve --agent claude --native-session-id prompt-inactive --json
  [ "$status" -eq 3 ]; [[ "$output" == *'"reason": "ended_record"'* ]] || return 1

  wrong_payload='{"hook_event_name":"UserPromptSubmit","session_id":"other-native","prompt":"continue"}'
  run env RIG_SESSION_FILE="$first_file" RIG_SESSION_ANCHOR="$first_anchor" \
    bash -c 'cd "$1" && printf "%s" "$2" | bash .claude/hooks/prompt-submit.sh' _ "$CASE_DIR" "$wrong_payload"
  [ "$status" -eq 0 ]; [[ "$output" == *'could not attach'* ]] || return 1
  [ "$(find "$CASE_DIR/.rig/memory/sessions" -maxdepth 1 -name 'session-*.json' | wc -l | tr -d ' ')" -eq 1 ]

  payload='{"hook_event_name":"UserPromptSubmit","session_id":"prompt-inactive","prompt":"continue"}'
  run env RIG_SESSION_FILE="$first_file" RIG_SESSION_ANCHOR="$first_anchor" \
    bash -c 'cd "$1" && printf "%s" "$2" | bash .claude/hooks/prompt-submit.sh' _ "$CASE_DIR" "$payload"
  [ "$status" -eq 0 ]
  run env RIG_SESSION_FILE="$first_file" RIG_SESSION_ANCHOR="$first_anchor" "$CASE_DIR/bin/rig" session current --json
  [ "$status" -eq 0 ]; [[ "$output" == *'"reason": "launcher_continuation"'* ]] || return 1
  second_file=$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["session_file"])')
  SESSION_F="$second_file" FIRST_ANCHOR="$first_anchor" python3 -c 'import json,os; d=json.load(open(os.environ["SESSION_F"])); assert d["lifecycle"]["state"]=="active" and d["lineage"]["parent_anchor"]==os.environ["FIRST_ANCHOR"] and d["lineage"]["kind"]=="continuation"'
  run env RIG_SESSION_FILE="$first_file" RIG_SESSION_ANCHOR="$first_anchor" \
    bash -c 'cd "$1" && printf "%s" "$2" | bash .claude/hooks/prompt-submit.sh' _ "$CASE_DIR" "$payload"
  [ "$status" -eq 0 ]
  [ "$(find "$CASE_DIR/.rig/memory/sessions" -maxdepth 1 -name 'session-*.json' | wc -l | tr -d ' ')" -eq 2 ]
  run env -u RIG_SESSION_ANCHOR RIG_SESSION_FILE="$first_file" "$CASE_DIR/bin/rig" session current --json
  [ "$status" -eq 3 ]; [[ "$output" == *'"reason": "invalid_launcher_file"'* ]] || return 1
  run env RIG_SESSION_FILE="$first_file" RIG_SESSION_ANCHOR=wrong-anchor "$CASE_DIR/bin/rig" session current --json
  [ "$status" -eq 3 ]; [[ "$output" == *'"reason": "launcher_anchor_conflict"'* ]] || return 1
  run env RIG_SESSION_FILE="$first_file" RIG_SESSION_ANCHOR="$first_anchor" CLAUDE_CODE_SESSION_ID=other-native "$CASE_DIR/bin/rig" session current --json
  [ "$status" -eq 3 ]; [[ "$output" == *'"reason": "native_conflict"'* ]] || return 1
  run env RIG_SESSION_FILE="$first_file" RIG_SESSION_ANCHOR="$first_anchor" CLAUDE_CODE_SESSION_ID=prompt-inactive \
    "$CASE_DIR/bin/rig" session-name set --final --json 'resumed name'
  [ "$status" -eq 0 ]
  SESSION_F="$second_file" python3 -c 'import json,os; assert json.load(open(os.environ["SESSION_F"]))["names"]["final"]=="resumed name"'
  run "$CASE_DIR/bin/rig" session doctor --json
  [ "$status" -eq 0 ]
}

@test "ended_no_wrap native record continues only from its exact prompt ID" {
  first=$("$CASE_DIR/bin/rig" session bind --agent claude --native-session-id needs-wrap --source startup)
  first_file=$(printf '%s' "$first" | python3 -c 'import json,sys; print(json.load(sys.stdin)["session_file"])')
  SESSION_F="$first_file" python3 -c 'import json,os; p=os.environ["SESSION_F"]; d=json.load(open(p)); d["flags"]["wrap_needed"]=True; json.dump(d,open(p,"w"))'
  run env RIG_SESSION_LOG="$BATS_TEST_TMPDIR/session.log" bash -c 'cd "$1" && printf "%s" "$2" | bash .claude/hooks/stop.sh' _ "$CASE_DIR" '{"source":"prompt_input_exit","session_id":"needs-wrap"}'
  [ "$status" -eq 0 ]
  SESSION_F="$first_file" python3 -c 'import json,os; assert json.load(open(os.environ["SESSION_F"]))["lifecycle"]["state"]=="ended_no_wrap"'
  run "$CASE_DIR/bin/rig" session resolve --agent claude --native-session-id needs-wrap --json
  [ "$status" -eq 3 ]; [[ "$output" == *'"reason": "ended_record"'* ]] || return 1
  run bash -c 'cd "$1" && printf "%s" "$2" | bash .claude/hooks/prompt-submit.sh' _ "$CASE_DIR" \
    '{"hook_event_name":"UserPromptSubmit","session_id":"needs-wrap","prompt":"continue"}'
  [ "$status" -eq 0 ]
  run "$CASE_DIR/bin/rig" session resolve --agent claude --native-session-id needs-wrap --json
  [ "$status" -eq 0 ]; [[ "$output" == *'"state": "active"'* ]] || return 1
  second_file=$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["session_file"])')
  [ "$second_file" != "$first_file" ]
  run env CLAUDE_CODE_SESSION_ID=needs-wrap "$CASE_DIR/bin/rig" session-name set --final 'continued wrap'
  [ "$status" -eq 0 ]
  run "$CASE_DIR/bin/rig" session doctor --json
  [ "$status" -eq 0 ]
}

@test "prompt-only legacy launcher migrates to exact native binding" {
  file="$CASE_DIR/.rig/memory/sessions/session-legacy.json"
  write_session "$file" legacy-prompt feat/current ended-no-wrap
  payload='{"hook_event_name":"UserPromptSubmit","session_id":"legacy-prompt-native","prompt":"continue"}'
  run env RIG_SESSION_FILE="$file" RIG_SESSION_ANCHOR=legacy-prompt \
    bash -c 'cd "$1" && printf "%s" "$2" | bash .claude/hooks/prompt-submit.sh' _ "$CASE_DIR" "$payload"
  [ "$status" -eq 0 ]
  run env RIG_SESSION_FILE="$file" RIG_SESSION_ANCHOR=legacy-prompt "$CASE_DIR/bin/rig" session current --json
  [ "$status" -eq 0 ]; [[ "$output" == *'"reason": "launcher_file"'* && "$output" == *'"state": "active"'* ]] || return 1
  SESSION_F="$file" python3 -c 'import json,os; d=json.load(open(os.environ["SESSION_F"])); assert d["schema_version"]==1 and d["native"]["session_id"]=="legacy-prompt-native" and d["migration"]["legacy_anchor"]=="legacy-prompt"'
  run env RIG_SESSION_FILE="$file" RIG_SESSION_ANCHOR=legacy-prompt "$CASE_DIR/bin/rig" session-name set --final 'legacy resumed name'
  [ "$status" -eq 0 ]
  run "$CASE_DIR/bin/rig" session resolve --agent claude --native-session-id unrelated-native --json
  [ "$status" -eq 1 ]; [[ "$output" == *'"reason": "not_found"'* ]] || return 1
}

@test "retrofit mints a continuation record for an ended native session" {
  write_native_session "$CASE_DIR/.rig/memory/sessions/done/session-ended.json" ended-anchor ended-native-id complete codex

  run env CODEX_THREAD_ID=ended-native-id "$CASE_DIR/bin/rig" session retrofit --agent codex --from-env --source resume --json

  [ "$status" -eq 0 ]
  [[ "$output" == *'"retrofitted": true'* && "$output" != *'ended-native-id'* ]] || return 1
  local file
  file=$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["session_file"])')
  [[ "$file" != *'/done/'* ]] || return 1
  SESSION_F="$file" python3 -c 'import json,os; d=json.load(open(os.environ["SESSION_F"])); assert d["lifecycle"]["state"]=="active"; assert d["lineage"]["kind"]=="continuation"; assert d["lineage"]["parent_anchor"]=="ended-anchor"'

  run env CODEX_THREAD_ID=ended-native-id RIG_SESSION_PID=999999 "$CASE_DIR/bin/rig" session resolve --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"reason": "native_id"'* && "$output" != *'/done/'* && "$output" != *'ended-native-id'* ]] || return 1
  run env CODEX_THREAD_ID=ended-native-id "$CASE_DIR/bin/rig" session resolve --json --verbose
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["lineage"]["parent_native_session_id"]=="ended-native-id"'

  run "$CASE_DIR/bin/rig" session doctor --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"unique_native_bindings", "ok": true'* || "$output" == *'"name":"unique_native_bindings","ok":true'* ]] || return 1
}

@test "a native thread can complete and resume more than once with an exact lineage chain" {
  run "$CASE_DIR/bin/rig" session bind --agent codex --native-session-id repeated-thread --source startup
  [ "$status" -eq 0 ]
  first_file=$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["session_file"])')
  first_anchor=$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["anchor"])')
  run env RIG_SESSION_FILE="$first_file" "$CASE_DIR/bin/rig" session-name set --final --complete 'first wrap'
  [ "$status" -eq 0 ]

  run env CODEX_THREAD_ID=repeated-thread "$CASE_DIR/bin/rig" session retrofit --agent codex --from-env --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"kind": "continuation"'* || "$output" == *'"kind":"continuation"'* ]] || return 1
  [[ "$output" == *"$first_anchor"* ]] || return 1
  second_file=$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["session_file"])')
  second_anchor=$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["anchor"])')
  run env RIG_SESSION_FILE="$second_file" "$CASE_DIR/bin/rig" session-name set --final --complete 'second wrap'
  [ "$status" -eq 0 ]

  run env CODEX_THREAD_ID=repeated-thread "$CASE_DIR/bin/rig" session retrofit --agent codex --from-env --json
  [ "$status" -eq 0 ]
  [[ "$output" == *"$second_anchor"* ]] || return 1
  [[ "$output" != *"$first_anchor"* ]] || return 1
  run "$CASE_DIR/bin/rig" session doctor --json
  [ "$status" -eq 0 ]
}

@test "retrofit redacts native ID by default and reveals it only with verbose" {
  run env CODEX_THREAD_ID=private-thread "$CASE_DIR/bin/rig" session retrofit --agent codex --from-env --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"native_session_id": "<redacted>"'* ]] || return 1
  [[ "$output" != *'private-thread'* ]] || return 1
  run env CODEX_THREAD_ID=private-thread "$CASE_DIR/bin/rig" session retrofit --agent codex --from-env --json --verbose
  [ "$status" -eq 0 ]
  [[ "$output" == *'private-thread'* ]] || return 1
}

@test "retrofit accepts an exact native ID when an app-server shell has no native ID environment" {
  run env -u CODEX_THREAD_ID "$CASE_DIR/bin/rig" session retrofit --agent codex --native-session-id app-server-thread --source resume --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"retrofitted": true'* && "$output" != *'app-server-thread'* ]] || return 1
  local file
  file=$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["session_file"])')
  SESSION_F="$file" python3 -c 'import json,os; d=json.load(open(os.environ["SESSION_F"])); assert d["agent"]=="codex"; assert d["native"]["session_id"]=="app-server-thread"; assert d["native"]["source"]=="resume"'

  run env -u CODEX_THREAD_ID "$CASE_DIR/bin/rig" session retrofit --agent codex --native-session-id app-server-thread --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"retrofitted": false'* ]] || return 1
  [ "$(find "$CASE_DIR/.rig/memory/sessions" -maxdepth 1 -name 'session-*.json' | wc -l | tr -d ' ')" -eq 1 ]
}

@test "retrofit rejects mixed environment and explicit native ID sources without writing" {
  run env CODEX_THREAD_ID=ambient-thread "$CASE_DIR/bin/rig" session retrofit --agent codex --from-env --native-session-id another-thread --json
  [ "$status" -eq 3 ]
  [[ "$output" == *'"reason":"invalid_input"'* ]] || return 1
  [ "$(find "$CASE_DIR/.rig/memory/sessions" -maxdepth 1 -name 'session-*.json' | wc -l | tr -d ' ')" -eq 0 ]
}

@test "explicit retrofit refuses an ambient native identity for another thread or provider" {
  run env CODEX_THREAD_ID=ambient-thread "$CASE_DIR/bin/rig" session retrofit --agent codex --native-session-id other-thread --json
  [ "$status" -eq 3 ]
  [[ "$output" == *'"reason":"native_conflict"'* ]] || return 1
  run env CLAUDE_CODE_SESSION_ID=claude-thread "$CASE_DIR/bin/rig" session retrofit --agent codex --native-session-id codex-thread --json
  [ "$status" -eq 3 ]
  [[ "$output" == *'"reason":"native_conflict"'* ]] || return 1
  [ "$(find "$CASE_DIR/.rig/memory/sessions" -maxdepth 1 -name 'session-*.json' | wc -l | tr -d ' ')" -eq 0 ]
}

@test "explicit retrofit rejects an option token or repeated native ID before binding" {
  run "$CASE_DIR/bin/rig" session retrofit --agent codex --native-session-id --json
  [ "$status" -eq 3 ]
  [[ "$output" == *'"reason":"invalid_input"'* ]] || return 1
  run "$CASE_DIR/bin/rig" session retrofit --agent codex --native-session-id first-thread --native-session-id second-thread --json
  [ "$status" -eq 3 ]
  [[ "$output" == *'"reason":"invalid_input"'* ]] || return 1
  [ "$(find "$CASE_DIR/.rig/memory/sessions" -maxdepth 1 -name 'session-*.json' | wc -l | tr -d ' ')" -eq 0 ]
}

@test "explicit retrofit identity can be carried into an exact name and completion write" {
  local result file anchor
  result=$("$CASE_DIR/bin/rig" session retrofit --agent codex --native-session-id app-server-name --json)
  file=$(printf '%s' "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin)["session_file"])')
  anchor=$(printf '%s' "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin)["anchor"])')
  run env RIG_SESSION_FILE="$file" RIG_SESSION_ANCHOR="$anchor" "$CASE_DIR/bin/rig" session-name set --final --complete --json 'App server name'
  [ "$status" -eq 0 ]
  [ ! -e "$file" ]
  local done_file
  done_file=$(find "$CASE_DIR/.rig/memory/sessions/done" -name 'session-*.json' -print | head -1)
  SESSION_F="$done_file" python3 -c 'import json,os; d=json.load(open(os.environ["SESSION_F"])); assert d["native"]["session_id"]=="app-server-name"; assert d["names"]["final"]=="App server name"; assert d["lifecycle"]["state"]=="complete"'
}

@test "explicit native ID retrofit continues a completed thread" {
  write_native_session "$CASE_DIR/.rig/memory/sessions/done/session-ended.json" ended-anchor app-server-ended complete codex
  run env -u CODEX_THREAD_ID "$CASE_DIR/bin/rig" session retrofit --agent codex --native-session-id app-server-ended --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"retrofitted": true'* && "$output" == *'"kind": "continuation"'* ]] || return 1
  [[ "$output" == *'"parent_anchor": "ended-anchor"'* && "$output" != *'app-server-ended'* ]] || return 1
}

@test "naming refuses a stale launcher file when a different native thread is active" {
  first=$("$CASE_DIR/bin/rig" session bind --agent codex --native-session-id thread-a --source startup)
  second=$("$CASE_DIR/bin/rig" session bind --agent codex --native-session-id thread-b --source startup)
  second_file=$(printf '%s' "$second" | python3 -c 'import json,sys; print(json.load(sys.stdin)["session_file"])')
  before=$(cksum "$second_file")
  run env CODEX_THREAD_ID=thread-a RIG_SESSION_FILE="$second_file" "$CASE_DIR/bin/rig" session-name set --final 'wrong target'
  [ "$status" -ne 0 ]
  [ "$(cksum "$second_file")" = "$before" ]
}

@test "not_found names the exact retrofit command when the native env ID is available" {
  run env CODEX_THREAD_ID=unbound-thread RIG_SESSION_PID=999999 "$CASE_DIR/bin/rig" session current --json
  [ "$status" -eq 1 ]
  [[ "$output" == *'"reason": "not_found"'* ]] || return 1
  [[ "$output" == *'bin/rig session retrofit --agent codex --from-env --source resume --json'* ]] || return 1
  run env CODEX_THREAD_ID=unbound-thread RIG_SESSION_PID=999999 "$CASE_DIR/bin/rig" session current
  [ "$status" -eq 1 ]
  [[ "$output" == *'Recovery: bin/rig session retrofit --agent codex --from-env --source resume --json'* ]] || return 1
}

@test "session-name recovery refreshes the anchor used by its final write guard" {
  local snippet="$BATS_TEST_TMPDIR/session-name-recovery.sh" session_file
  run env CODEX_THREAD_ID=recovered-name RIG_SESSION_PID=999999 "$CASE_DIR/bin/rig" session current --json
  [ "$status" -eq 1 ]
  run env CODEX_THREAD_ID=recovered-name "$CASE_DIR/bin/rig" session retrofit --agent codex --from-env --source resume --json
  [ "$status" -eq 0 ]
  session_file=$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["session_file"])')
  python3 - "$BATS_TEST_DIRNAME/../templates/project/.claude/commands/session-name.md" > "$snippet" <<'PY'
import pathlib, sys
content = pathlib.Path(sys.argv[1]).read_text()
start = content.index("then refresh every captured identity field")
start = content.index("```bash\n", start) + len("```bash\n")
end = content.index("\n```", start)
print(content[start:end])
PY
  cat >> "$snippet" <<'SH'
CURRENT_JSON=$("$REPO/bin/rig" session current --json) || exit 1
CURRENT_UUID=$(printf '%s' "$CURRENT_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("anchor") or "")')
[[ -n "$SESSION_UUID" && "$CURRENT_UUID" == "$SESSION_UUID" ]] || exit 1
"$REPO/bin/rig" session-name set --final --json 'Recovered exact name'
SH
  run env CODEX_THREAD_ID=recovered-name RIG_SESSION_PID=999999 REPO="$CASE_DIR" \
    /bin/bash "$snippet"
  [ "$status" -eq 0 ]
  SESSION_F="$session_file" python3 -c 'import json,os; d=json.load(open(os.environ["SESSION_F"])); assert d["names"]["final"]=="Recovered exact name"'
}

@test "doctor and resolver reject a broken continuation chain" {
  first=$("$CASE_DIR/bin/rig" session bind --agent codex --native-session-id chain-thread --source startup)
  first_file=$(printf '%s' "$first" | python3 -c 'import json,sys; print(json.load(sys.stdin)["session_file"])')
  run env RIG_SESSION_FILE="$first_file" "$CASE_DIR/bin/rig" session-name set --final --complete 'first wrap'
  [ "$status" -eq 0 ]
  second=$(env CODEX_THREAD_ID=chain-thread "$CASE_DIR/bin/rig" session retrofit --agent codex --from-env --json)
  second_file=$(printf '%s' "$second" | python3 -c 'import json,sys; print(json.load(sys.stdin)["session_file"])')
  SESSION_F="$second_file" python3 -c 'import json,os; p=os.environ["SESSION_F"]; d=json.load(open(p)); d["lineage"]["parent_anchor"]="unknown-anchor"; json.dump(d,open(p,"w"))'
  run "$CASE_DIR/bin/rig" session doctor --json
  [ "$status" -eq 2 ]
  [[ "$output" == *'"continuation_lineage", "ok": false'* ]] || return 1
  run "$CASE_DIR/bin/rig" session resolve --agent codex --native-session-id chain-thread --json
  [ "$status" -eq 2 ]
  [[ "$output" == *'"reason": "duplicate_native_id"'* ]] || return 1
}

@test "legacy PID records stay readable but cannot be named without an exact launcher" {
  file="$CASE_DIR/.rig/memory/sessions/session-778899.json"
  write_session "$file" legacy-anchor feat/current
  run env RIG_SESSION_PID=778899 "$CASE_DIR/bin/rig" session resolve --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"reason": "pid"'* ]] || return 1
  before=$(cksum "$file")
  run env RIG_SESSION_PID=778899 "$CASE_DIR/bin/rig" session-name set --final --json 'unsafe name'
  [ "$status" -eq 3 ]
  [[ "$output" == *'"reason": "migration_required"'* ]] || return 1
  [ "$(cksum "$file")" = "$before" ]
  run env RIG_SESSION_ANCHOR=legacy-anchor "$CASE_DIR/bin/rig" session-name set --final 'explicit legacy name'
  [ "$status" -eq 0 ]
  SESSION_F="$file" python3 -c 'import json,os; assert json.load(open(os.environ["SESSION_F"]))["final_name"]=="explicit legacy name"'
}

@test "prompt submit binds a resumed Codex thread from its event ID without an env variable" {
  payload='{"hook_event_name":"UserPromptSubmit","session_id":"prompt-thread","prompt":"continue"}'
  run bash -c 'cd "$1" && printf "%s" "$2" | RIG_AGENT=codex bash .claude/hooks/prompt-submit.sh' _ "$CASE_DIR" "$payload"
  [ "$status" -eq 0 ]
  run "$CASE_DIR/bin/rig" session resolve --agent codex --native-session-id prompt-thread --json
  [ "$status" -eq 0 ]
  file=$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["session_file"])')
  first_anchor=$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["anchor"])')
  run env RIG_SESSION_FILE="$file" "$CASE_DIR/bin/rig" session-name set --final --complete 'first wrap'
  [ "$status" -eq 0 ]

  run bash -c 'cd "$1" && printf "%s" "$2" | RIG_AGENT=codex bash .claude/hooks/prompt-submit.sh' _ "$CASE_DIR" "$payload"
  [ "$status" -eq 0 ]
  run "$CASE_DIR/bin/rig" session resolve --agent codex --native-session-id prompt-thread --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"reason": "native_id"'* ]] || return 1
  [[ "$output" == *"$first_anchor"* ]] || return 1
}

@test "prompt-only resume honors the inherited original launcher identity" {
  first=$("$CASE_DIR/bin/rig" session bind --agent claude --native-session-id prompt-launch --source startup)
  first_file=$(printf '%s' "$first" | python3 -c 'import json,sys; print(json.load(sys.stdin)["session_file"])')
  first_anchor=$(printf '%s' "$first" | python3 -c 'import json,sys; print(json.load(sys.stdin)["anchor"])')
  run env RIG_SESSION_FILE="$first_file" RIG_SESSION_ANCHOR="$first_anchor" \
    "$CASE_DIR/bin/rig" session-name set --final --complete 'first wrap'
  [ "$status" -eq 0 ]
  [ ! -e "$first_file" ]

  stale="$CASE_DIR/.rig/memory/sessions/session-unrelated.json"
  run env RIG_SESSION_FILE="$stale" RIG_SESSION_ANCHOR="$first_anchor" \
    "$CASE_DIR/bin/rig" session bind --agent claude --native-session-id prompt-launch --source prompt_resume --allow-continuation
  [ "$status" -eq 3 ]
  [[ "$output" == *'"reason": "native_conflict"'* ]] || return 1
  run env RIG_SESSION_FILE="$first_file" RIG_SESSION_ANCHOR=wrong-anchor \
    "$CASE_DIR/bin/rig" session bind --agent claude --native-session-id prompt-launch --source prompt_resume --allow-continuation
  [ "$status" -eq 3 ]
  [[ "$output" == *'"reason": "native_conflict"'* ]] || return 1

  payload='{"hook_event_name":"UserPromptSubmit","session_id":"prompt-launch","prompt":"continue"}'
  run env RIG_SESSION_FILE="$first_file" RIG_SESSION_ANCHOR="$first_anchor" \
    bash -c 'cd "$1" && printf "%s" "$2" | bash .claude/hooks/prompt-submit.sh' _ "$CASE_DIR" "$payload"
  [ "$status" -eq 0 ]
  run env RIG_SESSION_FILE="$first_file" RIG_SESSION_ANCHOR="$first_anchor" "$CASE_DIR/bin/rig" session current --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"reason": "launcher_continuation"'* ]] || return 1
  run env RIG_SESSION_FILE="$stale" RIG_SESSION_ANCHOR="$first_anchor" "$CASE_DIR/bin/rig" session current --json
  [ "$status" -eq 3 ]
  [[ "$output" == *'"reason": "invalid_launcher_file"'* ]] || return 1
  run env -u RIG_SESSION_ANCHOR RIG_SESSION_FILE="$first_file" "$CASE_DIR/bin/rig" session current --json
  [ "$status" -eq 3 ]
  [[ "$output" == *'"reason": "invalid_launcher_file"'* ]] || return 1
  run env RIG_SESSION_FILE="$first_file" RIG_SESSION_ANCHOR="$first_anchor" CLAUDE_CODE_SESSION_ID=other-native \
    "$CASE_DIR/bin/rig" session current --json
  [ "$status" -eq 3 ]
  [[ "$output" == *'"reason": "native_conflict"'* ]] || return 1

  done_file=$(find "$CASE_DIR/.rig/memory/sessions/done" -name 'session-*.json' -print | head -1)
  DONE_F="$done_file" python3 -c 'import json,os; p=os.environ["DONE_F"]; d=json.load(open(p)); d["project"]["identity"]="foreign-project"; json.dump(d,open(p,"w"))'
  run env RIG_SESSION_FILE="$first_file" RIG_SESSION_ANCHOR="$first_anchor" "$CASE_DIR/bin/rig" session current --json
  [ "$status" -eq 3 ]
  [[ "$output" == *'"reason": "cross_project"'* ]] || return 1
  run env RIG_SESSION_FILE="$first_file" RIG_SESSION_ANCHOR="$first_anchor" \
    "$CASE_DIR/bin/rig" session bind --agent claude --native-session-id prompt-launch --source prompt_resume --allow-continuation
  [ "$status" -eq 3 ]
  [[ "$output" == *'"reason": "cross_project"'* ]] || return 1
}

@test "duplicate completed origins cannot redirect an inherited launcher hint" {
  first=$("$CASE_DIR/bin/rig" session bind --agent claude --native-session-id origin-one --source startup)
  first_file=$(printf '%s' "$first" | python3 -c 'import json,sys; print(json.load(sys.stdin)["session_file"])')
  first_anchor=$(printf '%s' "$first" | python3 -c 'import json,sys; print(json.load(sys.stdin)["anchor"])')
  run env RIG_SESSION_FILE="$first_file" "$CASE_DIR/bin/rig" session-name set --final --complete 'first wrap'
  [ "$status" -eq 0 ]
  done_file=$(find "$CASE_DIR/.rig/memory/sessions/done" -name 'session-*.json' -print | head -1)
  duplicate="$CASE_DIR/.rig/memory/sessions/done/session-duplicate.json"
  cp "$done_file" "$duplicate"
  DUPLICATE="$duplicate" python3 -c 'import json,os; p=os.environ["DUPLICATE"]; d=json.load(open(p)); d["anchor"]="other-anchor"; d["native"]["session_id"]="origin-two"; json.dump(d,open(p,"w"))'

  run env RIG_SESSION_FILE="$first_file" RIG_SESSION_ANCHOR="$first_anchor" \
    "$CASE_DIR/bin/rig" session bind --agent claude --native-session-id origin-one --source resume --allow-continuation
  [ "$status" -eq 2 ]
  [[ "$output" == *'"reason": "duplicate_launcher_origin"'* ]] || return 1
  run env RIG_SESSION_FILE="$first_file" RIG_SESSION_ANCHOR="$first_anchor" "$CASE_DIR/bin/rig" session current --json
  [ "$status" -eq 2 ]
  [[ "$output" == *'"reason": "duplicate_launcher_origin"'* ]] || return 1
  [ "$(find "$CASE_DIR/.rig/memory/sessions" -maxdepth 1 -name 'session-*.json' | wc -l | tr -d ' ')" -eq 0 ]
}

@test "ended-record continuation refuses same native id bound to another project" {
  write_native_session "$CASE_DIR/.rig/memory/sessions/done/session-ended.json" ended-anchor shared-native complete codex
  write_native_session "$CASE_DIR/.rig/memory/sessions/session-foreign-active.json" foreign-anchor shared-native active codex
  PATH_F="$CASE_DIR/.rig/memory/sessions/session-foreign-active.json" python3 -c 'import json,os; p=os.environ["PATH_F"]; d=json.load(open(p)); d["project"]["identity"]="foreign-project"; json.dump(d,open(p,"w"))'

  run env CODEX_THREAD_ID=shared-native "$CASE_DIR/bin/rig" session retrofit --agent codex --from-env --source resume --json

  [ "$status" -eq 3 ]
  [[ "$output" == *'"reason":"cross_project"'* || "$output" == *'"reason": "cross_project"'* ]] || return 1
  [ "$(find "$CASE_DIR/.rig/memory/sessions" -maxdepth 1 -type f -name 'session-*.json' | wc -l | tr -d ' ')" -eq 1 ]
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
  [ "$status" -eq 0 ]; [[ "$(<"$tty")" == *'final'* ]] || return 1
  python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["final_name"]=None; json.dump(d,open(p,"w"))' "$file"; : > "$tty"
  env RIG_SESSION_FILE="$file" RIG_PROJECT_NAME=demo RIG_TITLE_TTY="$tty" RIG_TITLE_ONCE=1 "$CASE_DIR/bin/rig-tab-title-watch"
  [[ "$(<"$tty")" == *'tent'* ]] || return 1
  python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["tentative_name"]=None; json.dump(d,open(p,"w"))' "$file"; : > "$tty"
  env RIG_SESSION_FILE="$file" RIG_PROJECT_NAME=demo RIG_TITLE_TTY="$tty" RIG_TITLE_ONCE=1 "$CASE_DIR/bin/rig-tab-title-watch"
  [[ "$(<"$tty")" == *'demo: feat/current'* ]] || return 1
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
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
      [ -s "$TITLE_TTY" ] && break
      sleep .1
    done
    python3 -c '\''import json,os; p=os.environ["SESSION_F"]; d=json.load(open(p)); d["final_name"]="changed"; json.dump(d,open(p,"w"))'\''
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
      grep -q changed "$TITLE_TTY" && break
      sleep .1
    done
    kill "$watcher_pid" 2>/dev/null || true
    wait "$watcher_pid" 2>/dev/null || true
  '
  [ "$status" -eq 0 ]; [[ "$(<"$tty")" == *changed* ]] || return 1
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
  [ "$status" -eq 0 ]; [[ "$output" == 'codex:--help watcher:'* ]] || return 1
}

@test "native bind creates a redacted versioned record and exact resolve is read-only" {
  run "$CASE_DIR/bin/rig" session bind --agent codex --native-session-id thread-secret --source startup
  [ "$status" -eq 0 ]
  local file
  file=$(printf '%s' "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["native_session_id"] == "<redacted>"; print(d["session_file"])')
  SESSION_F="$file" python3 -c 'import json,os; d=json.load(open(os.environ["SESSION_F"])); assert d["schema_version"]==1 and d["agent"]=="codex" and d["native"]["session_id"]=="thread-secret" and d["lifecycle"]["state"]=="active"'
  local before after
  before=$(cksum "$file")
  run "$CASE_DIR/bin/rig" session resolve --agent codex --native-session-id thread-secret --json
  [ "$status" -eq 0 ]; [[ "$output" == *'"reason": "native_id"'* && "$output" != *'thread-secret'* ]] || return 1
  after=$(cksum "$file"); [ "$before" = "$after" ]
}

@test "current Codex retrofit binds from CODEX_THREAD_ID without leaking the native id" {
  run env CODEX_THREAD_ID=current-thread "$CASE_DIR/bin/rig" session retrofit --agent codex --from-env --source resume --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"retrofitted": true'* && "$output" != *'current-thread'* ]] || return 1
  local file
  file=$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["session_file"])')
  SESSION_F="$file" python3 -c 'import json,os; d=json.load(open(os.environ["SESSION_F"])); assert d["agent"]=="codex" and d["native"]["session_id"]=="current-thread" and d["native"]["source"]=="resume"'

  run env CODEX_THREAD_ID=current-thread RIG_SESSION_PID=999999 "$CASE_DIR/bin/rig" session resolve --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"reason": "native_id"'* && "$output" != *'current-thread'* ]] || return 1

  run env CODEX_THREAD_ID=current-thread "$CASE_DIR/bin/rig" session retrofit --agent codex --from-env --source resume --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"retrofitted": false'* && "$output" != *'current-thread'* ]] || return 1
}

@test "current Codex retrofit fails safely when CODEX_THREAD_ID is missing" {
  run env -u CODEX_THREAD_ID "$CASE_DIR/bin/rig" session retrofit --agent codex --from-env --json
  [ "$status" -eq 3 ]
  [[ "$output" == *'"reason":"missing_native_env"'* && "$output" == *'"no_write":true'* ]] || return 1
  [ "$(find "$CASE_DIR/.rig/memory/sessions" -type f -name 'session-*.json' | wc -l | tr -d ' ')" -eq 0 ]
}

@test "native resolver fails closed on wrong project and duplicate bindings" {
  run "$CASE_DIR/bin/rig" session bind --agent claude --native-session-id native-a --source startup
  [ "$status" -eq 0 ]
  local file duplicate
  file=$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["session_file"])')
  duplicate="$CASE_DIR/.rig/memory/sessions/session-duplicate.json"
  cp "$file" "$duplicate"
  run "$CASE_DIR/bin/rig" session resolve --agent claude --native-session-id native-a --json
  [ "$status" -eq 2 ]; [[ "$output" == *'"reason": "duplicate_native_id"'* ]] || return 1
}

@test "native binding rejects a launcher hint already bound to another ID without writing" {
  run "$CASE_DIR/bin/rig" session bind --agent claude --native-session-id native-a --source startup
  [ "$status" -eq 0 ]
  local file before after
  file=$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["session_file"])')
  before=$(cksum "$file")
  run env RIG_SESSION_FILE="$file" "$CASE_DIR/bin/rig" session bind --agent claude --native-session-id native-b --source startup
  [ "$status" -eq 3 ]; [[ "$output" == *'"reason": "native_conflict"'* ]] || return 1
  after=$(cksum "$file"); [ "$before" = "$after" ]
}

@test "native binding rejects outside, traversal, and symlink launcher hints" {
  local outside="$BATS_TEST_TMPDIR/outside-session.json" link="$CASE_DIR/.rig/memory/sessions/session-link.json"
  write_session "$outside" outside feat/outside
  run env RIG_SESSION_FILE="$outside" "$CASE_DIR/bin/rig" session bind --agent claude --native-session-id outside-id --source startup
  [ "$status" -eq 3 ]
  [[ "$output" == *'"reason": "invalid_session_path"'* && "$output" == *'"no_write": true'* ]] || return 1
  run env RIG_SESSION_FILE="$CASE_DIR/.rig/memory/sessions/../outside.json" "$CASE_DIR/bin/rig" session bind --agent claude --native-session-id traversal-id --source startup
  [ "$status" -eq 3 ]
  [[ "$output" == *'"reason": "invalid_session_path"'* ]] || return 1
  ln -s "$outside" "$link"
  run env RIG_SESSION_FILE="$link" "$CASE_DIR/bin/rig" session bind --agent claude --native-session-id symlink-id --source startup
  [ "$status" -eq 3 ]
  [[ "$output" == *'"reason": "invalid_session_path"'* ]] || return 1
  [ "$(find "$CASE_DIR/.rig/memory/sessions" -type f -name 'session-*.json' | wc -l | tr -d ' ')" -eq 0 ]
}

@test "native resolution rejects malformed and future records without writes" {
  local bad="$CASE_DIR/.rig/memory/sessions/session-bad.json" before after
  printf '{bad json' > "$bad"; before=$(cksum "$bad")
  run "$CASE_DIR/bin/rig" session resolve --agent codex --native-session-id missing --json
  [ "$status" -eq 4 ]; [[ "$output" == *'"reason": "malformed_record"'* ]] || return 1
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

@test "session-name reports a destination conflict without completing or overwriting" {
  run "$CASE_DIR/bin/rig" session bind --agent codex --native-session-id protected-name --source startup
  [ "$status" -eq 0 ]
  local file anchor destination
  file=$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["session_file"])')
  anchor=$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["anchor"])')
  destination="$CASE_DIR/.rig/memory/sessions/done/session-$(date +%Y%m%d)-$anchor.json"
  printf 'keep this file\n' > "$destination"
  run env RIG_SESSION_FILE="$file" "$CASE_DIR/bin/rig" session-name set --final --complete --json 'new final name'
  [ "$status" -eq 3 ]
  [[ "$output" == *'"reason": "destination_exists"'* && "$output" != *'"ok":true'* ]] || return 1
  [ "$(cat "$destination")" = 'keep this file' ]
  [ -f "$file" ]
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
  [[ "$output" == file=*'/memory/sessions/session-'* && "$output" == *' anchor='* && "$output" == *' project=project args=--model test'* ]] || return 1
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
