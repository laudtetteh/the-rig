#!/usr/bin/env bats
# Sprint audit honors declared done status and legacy issue links (#616).

setup() {
  CASE_DIR="$BATS_TEST_TMPDIR/project"
  mkdir -p "$CASE_DIR/bin" "$CASE_DIR/.rig/tasks/backlog" "$CASE_DIR/.rig/tasks/active" "$CASE_DIR/.rig/tasks/done"
  cp "$BATS_TEST_DIRNAME/../templates/project/bin/rig-sprint" "$CASE_DIR/bin/rig-sprint"
  git -C "$CASE_DIR" init -q
}

# write_card FOLDER SLUG STATUS ISSUE_FIELD ISSUE_REF
write_card() {
  printf '# Task: %s\n\n**Status**: %s\n**%s**: %s\n\n## Files likely affected\n\n- src/%s.sh\n' \
    "$2" "$3" "$4" "$5" "$2" > "$CASE_DIR/.rig/tasks/$1/$2.md"
}

audit() {
  run bash -c 'cd "$1" && python3 bin/rig-sprint audit --all --json' _ "$CASE_DIR"
  [ "$status" -eq 0 ]
}

# Print "slug ref" for each schedulable task in the last audit output.
scheduled() {
  printf '%s' "$output" | python3 -c 'import json,sys; [print(t["slug"], t["canonical_ref"]) for t in json.load(sys.stdin)["result"]["tasks"]]'
}

@test "a backlog card declaring Status done is not scheduled" {
  write_card backlog TASK_11_done done 'GitHub issue' '#11'
  write_card backlog TASK_13_open backlog 'GitHub issue' '#13'
  audit
  [ "$(scheduled)" = "TASK_13_open #13" ]
}

@test "terminal status spellings are all treated as finished" {
  local status
  for status in done Done complete completed closed cancelled canceled '`done`' 'done (merged in #9)'; do
    write_card backlog "TASK_x_$RANDOM" "$status" 'GitHub issue' '#20'
  done
  audit
  [ -z "$(scheduled)" ]
}

@test "the legacy GitHub field is recognized as the issue link" {
  write_card backlog TASK_12_legacy backlog GitHub '#12'
  audit
  [ "$(scheduled)" = "TASK_12_legacy #12" ]
}

@test "a done card linked by the legacy field satisfies a dependency" {
  write_card done TASK_30_old done GitHub '#30'
  printf '# Task: dependent\n\n**Status**: backlog\n**GitHub issue**: #31\n**Depends on**: #30\n\n## Files likely affected\n\n- src/dep.sh\n' \
    > "$CASE_DIR/.rig/tasks/backlog/TASK_31_dependent.md"
  audit
  lane=$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["tasks"][0]["lane"])')
  [ "$lane" = execution ]
}

@test "status and folder disagreement is reported and never scheduled" {
  write_card backlog TASK_40_marked_done done 'GitHub issue' '#40'
  write_card done TASK_41_still_active active 'GitHub issue' '#41'
  audit
  [ -z "$(scheduled)" ]
  printf '%s' "$output" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert "task_status_folder_mismatch:TASK_40_marked_done" in d["warnings"], d["warnings"]
assert "task_status_folder_mismatch:TASK_41_still_active" in d["warnings"], d["warnings"]
pairs = {(m["task"], m["folder"], m["status"]) for m in d["result"]["status_mismatches"]}
assert pairs == {("TASK_40_marked_done", "backlog", "done"), ("TASK_41_still_active", "done", "active")}, pairs
'
}

@test "agreeing status and folder produce no mismatch warning" {
  write_card done TASK_50_done done 'GitHub issue' '#50'
  write_card active TASK_51_active active 'GitHub issue' '#51'
  audit
  [ "$(scheduled)" = "TASK_51_active #51" ]
  printf '%s' "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["result"]["status_mismatches"] == [] and not any(w.startswith("task_status_folder_mismatch") for w in d["warnings"])'
}
