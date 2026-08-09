#!/usr/bin/env bats

setup() {
  export CASE_DIR="$BATS_TEST_TMPDIR/project"
  mkdir -p "$CASE_DIR/bin" "$CASE_DIR/.rig/memory/sessions/done"
  cp "$BATS_TEST_DIRNAME/../templates/project/bin/rig" "$CASE_DIR/bin/rig"
  chmod +x "$CASE_DIR/bin/rig"
  git -C "$CASE_DIR" init -q
  git -C "$CASE_DIR" checkout -q -b feat/obligations
  unset RIG_SESSION_FILE RIG_SESSION_ANCHOR RIG_SESSION_PID
}

bind() {
  "$CASE_DIR/bin/rig" session bind --agent claude --native-session-id "$1" --source startup
}

field() {
  printf '%s' "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$2"
}

@test "wrap obligations are SID-scoped and one session cannot clear another" {
  local one two file_one file_two anchor_one anchor_two
  one=$(bind native-one); two=$(bind native-two)
  file_one=$(field "$one" session_file); file_two=$(field "$two" session_file)
  anchor_one=$(field "$one" anchor); anchor_two=$(field "$two" anchor)
  run env RIG_SESSION_FILE="$file_one" "$CASE_DIR/bin/rig" session obligation mark --kind wrap --json
  [ "$status" -eq 0 ]
  run env RIG_SESSION_FILE="$file_two" "$CASE_DIR/bin/rig" session obligation mark --kind wrap --json
  [ "$status" -eq 0 ]
  grep -Fxq "anchor=$anchor_one" "$CASE_DIR/.rig/memory/.wrap-needed"
  grep -Fxq "anchor=$anchor_two" "$CASE_DIR/.rig/memory/.wrap-needed"

  run env RIG_SESSION_FILE="$file_one" "$CASE_DIR/bin/rig" session obligation clear --kind wrap --json
  [ "$status" -eq 0 ]
  if grep -Fq "anchor=$anchor_one" "$CASE_DIR/.rig/memory/.wrap-needed"; then return 1; fi
  grep -Fxq "anchor=$anchor_two" "$CASE_DIR/.rig/memory/.wrap-needed"
  SESSION_F="$file_one" python3 -c 'import json,os; d=json.load(open(os.environ["SESSION_F"])); assert d["flags"]["wrap_needed"] is False and d["obligations"]["wrap"]["cleared_at"]'
  SESSION_F="$file_two" python3 -c 'import json,os; assert json.load(open(os.environ["SESSION_F"]))["flags"]["wrap_needed"] is True'
}

@test "legacy wrap marker requires explicit adoption and mismatch is no-write" {
  local result file before
  result=$(bind legacy-wrap); file=$(field "$result" session_file)
  : > "$CASE_DIR/.rig/memory/.wrap-needed"
  before=$(cksum "$file")
  run env RIG_SESSION_FILE="$file" "$CASE_DIR/bin/rig" session obligation clear --kind wrap --json
  [ "$status" -eq 3 ]; [[ "$output" == *legacy_adoption_required* ]] || return 1
  [ -f "$CASE_DIR/.rig/memory/.wrap-needed" ]
  [ "$before" = "$(cksum "$file")" ]
  run env RIG_SESSION_FILE="$file" "$CASE_DIR/bin/rig" session obligation clear --kind wrap --adopt-legacy --json
  [ "$status" -eq 0 ]; [ ! -e "$CASE_DIR/.rig/memory/.wrap-needed" ]
}

@test "post-merge clear requires the exact pending SHA and records acknowledgement" {
  local result file before
  result=$(bind merge-session); file=$(field "$result" session_file)
  printf 'merge_sha=abc123\nmerged_at=2026-07-31T10:00:00-07:00\n' > "$CASE_DIR/.rig/memory/.post-merge-pending"
  before=$(cksum "$file")
  run env RIG_SESSION_FILE="$file" "$CASE_DIR/bin/rig" session obligation clear --kind post-merge --merge-sha wrong --json
  [ "$status" -eq 3 ]; [[ "$output" == *merge_mismatch* ]] || return 1
  [ -f "$CASE_DIR/.rig/memory/.post-merge-pending" ]; [ "$before" = "$(cksum "$file")" ]
  run env RIG_SESSION_FILE="$file" "$CASE_DIR/bin/rig" session obligation clear --kind post-merge --merge-sha abc123 --json
  [ "$status" -eq 0 ]; [ ! -e "$CASE_DIR/.rig/memory/.post-merge-pending" ]
  SESSION_F="$file" python3 -c 'import json,os; d=json.load(open(os.environ["SESSION_F"])); o=d["obligations"]["post_merge"]; assert o["merge_sha"]=="abc123" and o["acknowledged_at"] and d["flags"]["post_merge_pending"] is False'
}

@test "post-merge mark attaches the merge obligation to the exact session" {
  local result file anchor
  result=$(bind merge-mark); file=$(field "$result" session_file); anchor=$(field "$result" anchor)
  printf 'merge_sha=def456\nmerged_at=2026-07-31T11:00:00-07:00\n' > "$CASE_DIR/.rig/memory/.post-merge-pending"
  run env RIG_SESSION_FILE="$file" "$CASE_DIR/bin/rig" session obligation mark --kind post-merge --merge-sha def456 --json
  [ "$status" -eq 0 ]
  grep -Fxq "anchor=$anchor" "$CASE_DIR/.rig/memory/.post-merge-pending"
  grep -Fxq 'merged_at=2026-07-31T11:00:00-07:00' "$CASE_DIR/.rig/memory/.post-merge-pending"
  SESSION_F="$file" python3 -c 'import json,os; d=json.load(open(os.environ["SESSION_F"])); o=d["obligations"]["post_merge"]; assert d["flags"]["post_merge_pending"] is True and o["pending"] is True and o["merge_sha"]=="def456"'
}

@test "concurrent wrap marks preserve both anchors" {
  local one two file_one file_two anchor_one anchor_two
  one=$(bind concurrent-one); two=$(bind concurrent-two)
  file_one=$(field "$one" session_file); file_two=$(field "$two" session_file)
  anchor_one=$(field "$one" anchor); anchor_two=$(field "$two" anchor)
  run env RIG="$CASE_DIR/bin/rig" FILE_ONE="$file_one" FILE_TWO="$file_two" bash -c '
    RIG_SESSION_FILE="$FILE_ONE" "$RIG" session obligation mark --kind wrap --json >/dev/null & a=$!
    RIG_SESSION_FILE="$FILE_TWO" "$RIG" session obligation mark --kind wrap --json >/dev/null & b=$!
    wait "$a"; wait "$b"
  '
  [ "$status" -eq 0 ]
  grep -Fxq "anchor=$anchor_one" "$CASE_DIR/.rig/memory/.wrap-needed"
  grep -Fxq "anchor=$anchor_two" "$CASE_DIR/.rig/memory/.wrap-needed"
}

@test "obligation inputs reject missing identity and unsafe merge ambiguity" {
  run "$CASE_DIR/bin/rig" session obligation clear --kind post-merge --json
  [ "$status" -eq 64 ]
  run env RIG_SESSION_PID=999999 "$CASE_DIR/bin/rig" session obligation mark --kind wrap --json
  [ "$status" -eq 1 ]
  [ ! -e "$CASE_DIR/.rig/memory/.wrap-needed" ]
}

@test "exact resume reopens recoverable states but never terminal superseded state" {
  local result file before
  result=$(bind lifecycle-id); file=$(field "$result" session_file)
  SESSION_F="$file" python3 -c 'import json,os; p=os.environ["SESSION_F"]; d=json.load(open(p)); d["lifecycle"]["state"]="orphaned"; json.dump(d,open(p,"w"),indent=2)'
  run "$CASE_DIR/bin/rig" session bind --agent claude --native-session-id lifecycle-id --source resume
  [ "$status" -eq 0 ]
  SESSION_F="$file" python3 -c 'import json,os; assert json.load(open(os.environ["SESSION_F"]))["lifecycle"]["state"]=="active"'
  SESSION_F="$file" python3 -c 'import json,os; p=os.environ["SESSION_F"]; d=json.load(open(p)); d["lifecycle"]["state"]="superseded"; json.dump(d,open(p,"w"),indent=2)'
  before=$(cksum "$file")
  run "$CASE_DIR/bin/rig" session bind --agent claude --native-session-id lifecycle-id --source resume
  [ "$status" -eq 3 ]; [[ "$output" == *invalid_lifecycle_transition* ]] || return 1
  [ "$before" = "$(cksum "$file")" ]
}
