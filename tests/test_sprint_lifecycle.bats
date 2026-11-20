#!/usr/bin/env bats

setup() {
  export CASE_DIR="$BATS_TEST_TMPDIR/project"
  mkdir -p "$CASE_DIR/bin" "$CASE_DIR/.rig/tasks/backlog" "$CASE_DIR/.rig/tasks/active" "$CASE_DIR/.rig/tasks/done"
  cp "$BATS_TEST_DIRNAME/../templates/project/bin/rig" "$CASE_DIR/bin/rig"
  cp "$BATS_TEST_DIRNAME/../templates/project/bin/rig-session-resolve.py" "$CASE_DIR/bin/rig-session-resolve.py"
  cp "$BATS_TEST_DIRNAME/../templates/project/bin/rig-sprint" "$CASE_DIR/bin/rig-sprint"
  cp "$BATS_TEST_DIRNAME/../templates/project/bin/rig-tracker-config.py" "$CASE_DIR/bin/rig-tracker-config.py"
  chmod +x "$CASE_DIR/bin/rig" "$CASE_DIR/bin/rig-sprint"
  git -C "$CASE_DIR" init -q
  git -C "$CASE_DIR" checkout -q -b feat/sprint
  unset RIG_SESSION_FILE RIG_SESSION_ANCHOR RIG_SESSION_PID
  unset CLAUDE_CODE_SESSION_ID CLAUDECODE CODEX_THREAD_ID
}

task() {
  local slug="$1" issue="$2" priority="$3" files="$4" deps="${5:-}" lane="${6:-}"
  TASK_F="$CASE_DIR/.rig/tasks/backlog/$slug.md" TITLE="$slug" ISSUE="$issue" PRIORITY="$priority" FILES="$files" DEPS="$deps" LANE="$lane" python3 -c '
import os
lines=["# Task: "+os.environ["TITLE"],"", "**Status**: backlog","**Priority**: "+os.environ["PRIORITY"],"**GitHub issue**: "+os.environ["ISSUE"]]
if os.environ["DEPS"]: lines.append("**Depends on**: "+os.environ["DEPS"])
if os.environ["LANE"]: lines.append("**Sprint lane**: "+os.environ["LANE"])
lines += ["","## Goal","","goal","","## Acceptance criteria","","- [ ] done","","## Files likely affected",""]+["- `"+p+"`" for p in os.environ["FILES"].split(",") if p]+["","## Work checkpoint","","**Mode**: sprint (embedded)","**Phase**: plan","**Work status**: ready","**Next action**: launch"]
open(os.environ["TASK_F"],"w").write("\n".join(lines)+"\n")'
}

@test "audit reports tracker parity and preserves unavailable confidence" {
  task feat-a '#10' P1 src/a.py
  run "$CASE_DIR/bin/rig" sprint audit --all --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["schema_version"]==1 and d["result"]["tasks"][0]["canonical_ref"]=="#10"; assert d["result"]["parity"][0]["class"]=="evidence_unavailable"; assert "tracker_evidence_unavailable" in d["warnings"]'
}

@test "audit retains dependencies from an arbitrary tracker" {
  printf "issue-tracking: azure\nissue-ref-pattern: 'AB#[0-9]+'\n" > "$CASE_DIR/CLAUDE.md"
  task first 'AB#12' P1 src/a.py
  task second 'AB#13' P1 src/b.py 'AB#12'
  run "$CASE_DIR/bin/rig" sprint audit --all --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); rows={x["canonical_ref"]:x for x in d["result"]["tasks"]}; assert rows["AB#13"]["dependencies"]==["AB#12"]'
}

@test "audit treats a none dependency value as no dependency" {
  task no-dependency '#15' P1 src/a.py none
  run "$CASE_DIR/bin/rig" sprint audit --all --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["result"]["tasks"][0]["dependencies"]==[]'
}

@test "placeholder issue values keep cards distinct and out of tracker parity" {
  task no-tracker-a 'N/A (issue-tracking: none)' P1 src/a.py
  task no-tracker-b 'N/A (issue-tracking: none)' P1 src/b.py
  task pending-a 'TBD' P1 src/c.py
  task pending-b 'TBD' P1 src/d.py
  task local-explanation 'none — local card' P1 src/e.py
  task real-github '#10' P1 src/f.py
  task real-custom 'NONE-123' P1 src/g.py
  task fallback 'TBD' P1 src/h.py
  task annotated-tbd 'TBD: will file' P1 src/i.py
  task real-pending 'pending review' P1 src/j.py
  task real-unknown 'unknown project' P1 src/k.py
  task real-tbd-prefix 'TBD-123' P1 src/l.py
  TASK_F="$CASE_DIR/.rig/tasks/backlog/fallback.md" python3 -c 'import os,pathlib; p=pathlib.Path(os.environ["TASK_F"]); p.write_text(p.read_text().replace("**GitHub issue**: TBD", "**GitHub issue**: TBD\n**Issue**: #12"))'

  run "$CASE_DIR/bin/rig" sprint audit --all --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c '
import json, sys
r = json.load(sys.stdin)["result"]
refs = {task["slug"]: task["canonical_ref"] for task in r["tasks"]}
assert not r["duplicates"]
assert all(refs[slug] is None for slug in (
    "no-tracker-a", "no-tracker-b", "pending-a", "pending-b",
    "local-explanation", "annotated-tbd"))
assert {refs[slug] for slug in ("real-github", "real-custom", "fallback",
                                "real-pending", "real-unknown", "real-tbd-prefix")} == {
    "#10", "NONE-123", "#12", "pending review", "unknown project", "TBD-123"}
assert {item["canonical_ref"] for item in r["parity"]} == {
    "#10", "NONE-123", "#12", "pending review", "unknown project", "TBD-123"}
'

  run "$CASE_DIR/bin/rig" sprint plan --all --mode plan-only --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c 'import json,sys; p=json.load(sys.stdin)["result"]["plan"]; assert {s for wave in p["waves"] for s in wave}=={"no-tracker-a","no-tracker-b","pending-a","pending-b","local-explanation","real-github","real-custom","fallback","annotated-tbd","real-pending","real-unknown","real-tbd-prefix"}'
}

@test "plan deterministically separates prefix conflicts and non-execution lanes" {
  task feat-a '#10' P1 src
  task feat-b '#11' P2 src/b.py
  task decide-c '#12' P0 docs/x.md '' decision
  task huge-d '#13' P3 ''
  run "$CASE_DIR/bin/rig" sprint plan --all --mode plan-only --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c 'import json,sys; p=json.load(sys.stdin)["result"]["plan"]; assert p["waves"]==[["feat-a"],["feat-b"]]; assert p["lanes"]["decision"]==["decide-c"] and p["lanes"]["oversized"]==["huge-d"]; assert any(e["type"]=="prefix" for e in p["edges"]); assert p["approval_token"]'
}

@test "dependency included in the sprint is ordered before its dependent" {
  task prerequisite '#20' P3 src/base.py
  task dependent '#21' P0 src/feature.py '#20'
  run "$CASE_DIR/bin/rig" sprint plan --all --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c 'import json,sys; p=json.load(sys.stdin)["result"]["plan"]; assert p["waves"]==[["prerequisite"],["dependent"]]; assert any(e["type"]=="dependency" and e["from"]=="prerequisite" for e in p["edges"]); assert not p["lanes"]["blocked"]'
}

@test "malformed tracker evidence fails without writes" {
  task feat-a '#10' P1 src/a.py
  printf '{bad' > "$BATS_TEST_TMPDIR/evidence.json"
  run "$CASE_DIR/bin/rig" sprint audit --all --tracker-evidence "$BATS_TEST_TMPDIR/evidence.json" --json
  [ "$status" -eq 3 ]
  [[ "$output" == *malformed_tracker_evidence* ]] || return 1
  [ ! -d "$CASE_DIR/.rig/memory/sprints" ]
}

@test "durable approval requires exact session and supports superseding resume revisions" {
  task feat-a '#10' P1 src/a.py
  local token sid bind_result file
  run "$CASE_DIR/bin/rig" sprint plan --all --write --approval-token bogus --json
  [ "$status" -eq 3 ]; [[ "$output" == *exact_root_session_required* ]] || return 1
  bind_result=$("$CASE_DIR/bin/rig" session bind --agent codex --native-session-id sprint-native --source startup)
  file=$(printf '%s' "$bind_result" | python3 -c 'import json,sys; print(json.load(sys.stdin)["session_file"])')
  run env RIG_SESSION_FILE="$file" "$CASE_DIR/bin/rig" sprint plan --all --json
  [ "$status" -eq 0 ]
  token=$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["plan"]["approval_token"])')
  sid=$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["sprint_id"])')
  run env RIG_SESSION_FILE="$file" "$CASE_DIR/bin/rig" sprint plan --all --sprint "$sid" --write --approval-token "$token" --json
  [ "$status" -eq 0 ]; [[ "$output" == *'"document_revision": 1'* ]] || return 1
  run env RIG_SESSION_FILE="$file" "$CASE_DIR/bin/rig" sprint plan --sprint "$sid" --write --approval-token "$token" --json
  [ "$status" -eq 0 ]; [[ "$output" == *'"document_revision": 2'* ]] || return 1
  run "$CASE_DIR/bin/rig" sprint status --sprint "$sid" --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["document_revision"]==2 and d["result"]["supersedes_revision"]==1 and d["result"]["status"]=="ready"'
}

@test "approval token is bound to the exact root and another root cannot launch it" {
  task feat-a '#10' P1 src/a.py
  local first second file_one file_two token sid
  first=$("$CASE_DIR/bin/rig" session bind --agent codex --native-session-id root-one --source startup)
  second=$("$CASE_DIR/bin/rig" session bind --agent codex --native-session-id root-two --source startup)
  file_one=$(printf '%s' "$first" | python3 -c 'import json,sys; print(json.load(sys.stdin)["session_file"])')
  file_two=$(printf '%s' "$second" | python3 -c 'import json,sys; print(json.load(sys.stdin)["session_file"])')
  run env RIG_SESSION_FILE="$file_one" "$CASE_DIR/bin/rig" sprint plan --all --json
  token=$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["plan"]["approval_token"])')
  sid=$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["sprint_id"])')
  run env RIG_SESSION_FILE="$file_two" "$CASE_DIR/bin/rig" sprint plan --all --sprint "$sid" --write --approval-token "$token" --json
  [ "$status" -eq 3 ]; [[ "$output" == *approval_required* ]] || return 1
  [ ! -d "$CASE_DIR/.rig/memory/sprints/$sid" ]
}

@test "status refresh reports durable source drift without mutating revision" {
  task feat-a '#10' P1 src/a.py
  local bound file token sid before
  bound=$("$CASE_DIR/bin/rig" session bind --agent claude --native-session-id drift-root --source startup)
  file=$(printf '%s' "$bound" | python3 -c 'import json,sys; print(json.load(sys.stdin)["session_file"])')
  run env RIG_SESSION_FILE="$file" "$CASE_DIR/bin/rig" sprint plan --all --json
  token=$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["plan"]["approval_token"])'); sid=$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["sprint_id"])')
  env RIG_SESSION_FILE="$file" "$CASE_DIR/bin/rig" sprint plan --all --sprint "$sid" --write --approval-token "$token" --json >/dev/null
  before=$(cksum "$CASE_DIR/.rig/memory/sprints/$sid/revision-1.json")
  printf '\n## Context\nchanged\n' >> "$CASE_DIR/.rig/tasks/backlog/feat-a.md"
  run "$CASE_DIR/bin/rig" sprint status --sprint "$sid" --refresh --json
  [ "$status" -eq 0 ]; [[ "$output" == *'"detected": true'* ]] || return 1
  [ "$before" = "$(cksum "$CASE_DIR/.rig/memory/sprints/$sid/revision-1.json")" ]
}

@test "adversarial task text remains data and never executes" {
  task '$(touch rig-378-injected)' '#99' P1 'src/$(touch nope).py'
  run "$CASE_DIR/bin/rig" sprint audit --all --json
  [ "$status" -eq 0 ]
  [ ! -e "$CASE_DIR/rig-378-injected" ]; [ ! -e "$CASE_DIR/nope" ]
  [[ "$output" == *'$(touch rig-378-injected)'* ]] || return 1
}
