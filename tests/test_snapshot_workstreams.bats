#!/usr/bin/env bats

setup() {
  CASE_DIR="$BATS_TEST_TMPDIR/project"
  mkdir -p "$CASE_DIR/bin" "$CASE_DIR/.rig/memory/sessions/done"
  cp "$BATS_TEST_DIRNAME/../templates/project/bin/rig" "$CASE_DIR/bin/rig"
  cp "$BATS_TEST_DIRNAME/../templates/project/bin/rig-session-resolve.py" "$CASE_DIR/bin/rig-session-resolve.py"
  cp "$BATS_TEST_DIRNAME/../templates/project/bin/rig-snapshot.py" "$CASE_DIR/bin/rig-snapshot.py"
  git -C "$CASE_DIR" init -q
  unset RIG_SESSION_FILE RIG_SESSION_ANCHOR RIG_SESSION_PID CODEX_THREAD_ID CLAUDE_CODE_SESSION_ID
  rig="$CASE_DIR/bin/rig"
  a=$("$rig" session bind --agent claude --native-session-id thread-a --source startup)
  b=$("$rig" session bind --agent codex --native-session-id thread-b --source startup)
  file_a=$(printf '%s' "$a" | python3 -c 'import json,sys; print(json.load(sys.stdin)["session_file"])')
  file_b=$(printf '%s' "$b" | python3 -c 'import json,sys; print(json.load(sys.stdin)["session_file"])')
}

candidate() {
  local path="$1" branch="$2" task="$3"
  printf '# Context Snapshot\n\n**Branch:** %s\n\n## Resuming from: %s\n\n**Next action:** Continue %s.\n' \
    "$branch" "$task" "$task" > "$path"
}

legacy_launcher_session() {
  legacy_anchor="legacy-a"
  legacy_file="$CASE_DIR/.rig/memory/sessions/session-778899-${legacy_anchor}.json"
  LEGACY_FILE="$legacy_file" LEGACY_ANCHOR="$legacy_anchor" python3 - <<'PY'
import json, os
with open(os.environ["LEGACY_FILE"], "w") as handle:
    json.dump({"anchor": os.environ["LEGACY_ANCHOR"], "pid": 778899,
               "started_at": "2026-09-03T10:00:00", "branch": "main",
               "tentative_name": None, "final_name": None, "status": "active"}, handle)
PY
}

snapshot_command_block() {
  python3 - "$BATS_TEST_DIRNAME/../templates/project/.claude/commands/$1.md" <<'PY'
import pathlib, sys
content = pathlib.Path(sys.argv[1]).read_text()
start = content.index('```bash\nSNAP_DRAFT="$RIG_DIR/memory/.snapshot-draft-${SNAP_LOCK_TOKEN}.md"') + len('```bash\n')
end = content.index('\n```', start)
print(content[start:end])
PY
}

workflow_release_block() {
  python3 - "$BATS_TEST_DIRNAME/../templates/project/.claude/commands/$1.md" <<'PY'
import pathlib, sys
content = pathlib.Path(sys.argv[1]).read_text()
start = content.index('```bash\n"$REPO/bin/rig" memory workflow-lock release --token "$SNAP_LOCK_TOKEN" --json || exit 1') + len('```bash\n')
end = content.index('\n```', start)
assert end < content.index('> **Suggested session name:**'), "lock release must precede user confirmation"
print(content[start:end])
PY
}

@test "wrap acquires only after the dirty-file gate and report, then releases before prompts" {
  run python3 - "$BATS_TEST_DIRNAME/../templates/project/.claude/commands/wrap.md" <<'PY'
import pathlib, sys
s = pathlib.Path(sys.argv[1]).read_text()
git = s.index('## Git state check')
dirty = s.index('Wait for the answer before continuing.')
report = s.index('## Wrap report step')
acquire = s.index('## Concurrent session guard')
first_write = s.index('## Trim step — PROGRESS.md')
release = s.index('"$REPO/bin/rig" memory workflow-lock release --token "$SNAP_LOCK_TOKEN" --json || exit 1')
pr_prompt = s.index('Update PR description? [yes / no]')
name_prompt = s.index('### Step 4 — Present and confirm')
assert git < dirty < report < acquire < first_write < release < pr_prompt < name_prompt
assert 'After printing the Wrap report' in s[acquire:first_write]
PY
  [ "$status" -eq 0 ]
}

@test "post-merge skips before acquiring and releases before name confirmation" {
  run python3 - "$BATS_TEST_DIRNAME/../templates/project/.claude/commands/post-merge.md" <<'PY'
import pathlib, sys
s = pathlib.Path(sys.argv[1]).read_text()
git = s.index('## Git state check')
dirty = s.index('ask\nthe user whether to stash')
report = s.index('## Post-merge report step')
skip = s.index('stop before acquiring the workflow lock')
acquire = s.index('## Concurrent session guard')
snapshot = s.index('For the snapshot step, write')
release = s.index('"$REPO/bin/rig" memory workflow-lock release --token "$SNAP_LOCK_TOKEN" --json || exit 1')
name_prompt = s.index('### Step 4 — Present and confirm')
assert git < dirty < report < skip < acquire < snapshot < release < name_prompt
assert 'before the first\nPOST_MERGE_WORKFLOW step' in s[report:acquire]
PY
  [ "$status" -eq 0 ]
}

@test "wrap releases the memory lock before waiting for session name confirmation" {
  run "$rig" memory workflow-lock acquire --owner-anchor wrap --provider-pid "$$" --json
  [ "$status" -eq 0 ]
  token=$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')
  workflow_release_block wrap > "$BATS_TEST_TMPDIR/release.sh"
  run env REPO="$CASE_DIR" SNAP_LOCK_TOKEN="$token" bash "$BATS_TEST_TMPDIR/release.sh"
  [ "$status" -eq 0 ]
  run "$rig" memory workflow-lock acquire --owner-anchor next --json
  [ "$status" -eq 0 ]
}

@test "post-merge releases the memory lock before waiting for session name confirmation" {
  run "$rig" memory workflow-lock acquire --owner-anchor merge --provider-pid "$$" --json
  [ "$status" -eq 0 ]
  token=$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')
  workflow_release_block post-merge > "$BATS_TEST_TMPDIR/release.sh"
  run env REPO="$CASE_DIR" SNAP_LOCK_TOKEN="$token" bash "$BATS_TEST_TMPDIR/release.sh"
  [ "$status" -eq 0 ]
  run "$rig" memory workflow-lock acquire --owner-anchor next --json
  [ "$status" -eq 0 ]
}

@test "sequential session snapshots preserve both owned task handoffs" {
  candidate "$BATS_TEST_TMPDIR/a.md" feat/a task-a
  candidate "$BATS_TEST_TMPDIR/b.md" feat/b task-b
  run env RIG_SESSION_FILE="$file_a" "$rig" memory write-snapshot --file "$BATS_TEST_TMPDIR/a.md" --owned-task task-a --json
  [ "$status" -eq 0 ]
  run env RIG_SESSION_FILE="$file_b" "$rig" memory write-snapshot --file "$BATS_TEST_TMPDIR/b.md" --owned-task task-b --json
  [ "$status" -eq 0 ]
  snapshot="$CASE_DIR/.rig/memory/CONTEXT_SNAPSHOT.md"
  grep -Fq '## Resuming from: task-a' "$snapshot"
  grep -Fq '## Resuming from: task-b' "$snapshot"
  [ "$(grep -c '^## Resuming from:' "$snapshot")" -eq 2 ]
}

@test "another session cannot overwrite an owned task handoff" {
  candidate "$BATS_TEST_TMPDIR/a.md" feat/a task-a
  run env RIG_SESSION_FILE="$file_a" "$rig" memory write-snapshot --file "$BATS_TEST_TMPDIR/a.md" --owned-task task-a --json
  [ "$status" -eq 0 ]
  snapshot="$CASE_DIR/.rig/memory/CONTEXT_SNAPSHOT.md"
  before=$(cksum "$snapshot")
  candidate "$BATS_TEST_TMPDIR/attack.md" feat/b task-a
  run env RIG_SESSION_FILE="$file_b" "$rig" memory write-snapshot --file "$BATS_TEST_TMPDIR/attack.md" --owned-task task-a --json
  [ "$status" -ne 0 ]
  [[ "$output" == *owner_conflict* ]] || return 1
  [ "$before" = "$(cksum "$snapshot")" ]
}

@test "a prior-version launcher record writes an owned handoff alongside a native owner" {
  legacy_launcher_session
  candidate "$BATS_TEST_TMPDIR/a.md" feat/a task-a
  candidate "$BATS_TEST_TMPDIR/b.md" feat/b task-b
  run env RIG_SESSION_FILE="$legacy_file" RIG_SESSION_ANCHOR="$legacy_anchor" "$rig" session current --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"confidence": "exact"'* && "$output" == *'"reason": "launcher_file"'* ]] || return 1
  run env RIG_SESSION_FILE="$legacy_file" RIG_SESSION_ANCHOR="$legacy_anchor" "$rig" memory write-snapshot --file "$BATS_TEST_TMPDIR/a.md" --owned-task task-a --json
  [ "$status" -eq 0 ]
  run env RIG_SESSION_FILE="$file_b" "$rig" memory write-snapshot --file "$BATS_TEST_TMPDIR/b.md" --owned-task task-b --json
  [ "$status" -eq 0 ]
  snapshot="$CASE_DIR/.rig/memory/CONTEXT_SNAPSHOT.md"
  grep -Fq "task=task-a owner=$legacy_anchor" "$snapshot"
  grep -Fq '## Resuming from: task-b' "$snapshot"
}

@test "legacy owner requires exact launcher anchor and a unique active record" {
  legacy_launcher_session
  candidate "$BATS_TEST_TMPDIR/a.md" feat/a task-a
  snapshot="$CASE_DIR/.rig/memory/CONTEXT_SNAPSHOT.md"
  run env RIG_SESSION_FILE="$legacy_file" "$rig" memory write-snapshot --file "$BATS_TEST_TMPDIR/a.md" --owned-task task-a --json
  [ "$status" -eq 3 ]
  [[ "$output" == *unresolved_owner* ]] || return 1
  [ ! -e "$snapshot" ]
  run env RIG_SESSION_ANCHOR="$legacy_anchor" "$rig" memory write-snapshot --file "$BATS_TEST_TMPDIR/a.md" --owned-task task-a --json
  [ "$status" -ne 0 ]
  [ ! -e "$snapshot" ]
  cp "$legacy_file" "$CASE_DIR/.rig/memory/sessions/session-duplicate.json"
  run env RIG_SESSION_FILE="$legacy_file" RIG_SESSION_ANCHOR="$legacy_anchor" "$rig" memory write-snapshot --file "$BATS_TEST_TMPDIR/a.md" --owned-task task-a --json
  [ "$status" -eq 3 ]
  [[ "$output" == *unresolved_owner* ]] || return 1
  [ ! -e "$snapshot" ]
  rm "$CASE_DIR/.rig/memory/sessions/session-duplicate.json"
  nonlauncher="$CASE_DIR/.rig/memory/sessions/session-not-launcher.json"
  mv "$legacy_file" "$nonlauncher"
  run env RIG_SESSION_FILE="$nonlauncher" RIG_SESSION_ANCHOR="$legacy_anchor" "$rig" memory write-snapshot --file "$BATS_TEST_TMPDIR/a.md" --owned-task task-a --json
  [ "$status" -eq 3 ]
  [[ "$output" == *unresolved_owner* ]] || return 1
  [ ! -e "$snapshot" ]
}

@test "legacy owner refuses foreign project metadata and ended records" {
  legacy_launcher_session
  candidate "$BATS_TEST_TMPDIR/a.md" feat/a task-a
  snapshot="$CASE_DIR/.rig/memory/CONTEXT_SNAPSHOT.md"
  LEGACY_FILE="$legacy_file" python3 -c 'import json,os; p=os.environ["LEGACY_FILE"]; d=json.load(open(p)); d["project"]={"identity":"foreign"}; json.dump(d,open(p,"w"))'
  run env RIG_SESSION_FILE="$legacy_file" RIG_SESSION_ANCHOR="$legacy_anchor" "$rig" memory write-snapshot --file "$BATS_TEST_TMPDIR/a.md" --owned-task task-a --json
  [ "$status" -eq 3 ]
  [[ "$output" == *unresolved_owner* ]] || return 1
  [ ! -e "$snapshot" ]
  LEGACY_FILE="$legacy_file" python3 -c 'import json,os; p=os.environ["LEGACY_FILE"]; d=json.load(open(p)); d.pop("project"); d["status"]="ended-no-wrap"; json.dump(d,open(p,"w"))'
  run env RIG_SESSION_FILE="$legacy_file" RIG_SESSION_ANCHOR="$legacy_anchor" "$rig" memory write-snapshot --file "$BATS_TEST_TMPDIR/a.md" --owned-task task-a --json
  [ "$status" -ne 0 ]
  [ ! -e "$snapshot" ]
}

@test "a native owner transfers a legacy handoff only after its exact owner completes" {
  legacy_launcher_session
  candidate "$BATS_TEST_TMPDIR/a.md" feat/a task-a
  candidate "$BATS_TEST_TMPDIR/b.md" feat/b task-a
  run env RIG_SESSION_FILE="$legacy_file" RIG_SESSION_ANCHOR="$legacy_anchor" "$rig" memory write-snapshot --file "$BATS_TEST_TMPDIR/a.md" --owned-task task-a --json
  [ "$status" -eq 0 ]
  snapshot="$CASE_DIR/.rig/memory/CONTEXT_SNAPSHOT.md"
  before=$(cksum "$snapshot")
  run env RIG_SESSION_FILE="$file_b" "$rig" memory write-snapshot --file "$BATS_TEST_TMPDIR/b.md" --owned-task task-a --json
  [ "$status" -eq 3 ]
  [[ "$output" == *owner_conflict* ]] || return 1
  [ "$before" = "$(cksum "$snapshot")" ]
  run env RIG_SESSION_FILE="$legacy_file" RIG_SESSION_ANCHOR="$legacy_anchor" "$rig" session-name set --final --complete --json 'legacy complete'
  [ "$status" -eq 0 ]
  run env RIG_SESSION_FILE="$legacy_file" RIG_SESSION_ANCHOR="$legacy_anchor" "$rig" memory write-snapshot --file "$BATS_TEST_TMPDIR/a.md" --owned-task task-a --json
  [ "$status" -ne 0 ]
  [ "$before" = "$(cksum "$snapshot")" ]
  run env RIG_SESSION_FILE="$file_b" "$rig" memory write-snapshot --file "$BATS_TEST_TMPDIR/b.md" --owned-task task-a --json
  [ "$status" -eq 0 ]
  anchor_b=$(printf '%s' "$b" | python3 -c 'import json,sys; print(json.load(sys.stdin)["anchor"])')
  grep -Fq "task=task-a owner=$anchor_b" "$snapshot"
  backup=$(find "$CASE_DIR/.rig/memory/snapshot-backups" -type f -name 'transferred-*.md' | head -1)
  [ -n "$backup" ]
  grep -Fq "task=task-a owner=$legacy_anchor" "$backup"
}

@test "a new session can update a handoff after its exact owner completes" {
  candidate "$BATS_TEST_TMPDIR/a.md" feat/a task-a
  run env RIG_SESSION_FILE="$file_a" "$rig" memory write-snapshot --file "$BATS_TEST_TMPDIR/a.md" --owned-task task-a --json
  [ "$status" -eq 0 ]
  snapshot="$CASE_DIR/.rig/memory/CONTEXT_SNAPSHOT.md"
  before=$(cksum "$snapshot")
  FILE_A="$file_a" python3 -c 'import json,os; p=os.environ["FILE_A"]; d=json.load(open(p)); d["lifecycle"]["state"]="complete"; open(p,"w").write(json.dumps(d))'
  mv "$file_a" "$CASE_DIR/.rig/memory/sessions/done/$(basename "$file_a")"
  candidate "$BATS_TEST_TMPDIR/b.md" feat/b task-a
  run env RIG_SESSION_FILE="$file_b" "$rig" memory write-snapshot --file "$BATS_TEST_TMPDIR/b.md" --owned-task task-a --json
  [ "$status" -eq 0 ]
  [ "$before" != "$(cksum "$snapshot")" ]
  grep -Fq '**Next action:** Continue task-a.' "$snapshot"
  anchor_b=$(printf '%s' "$b" | python3 -c 'import json,sys; print(json.load(sys.stdin)["anchor"])')
  grep -Fq "owner=$anchor_b" "$snapshot"
  backup=$(find "$CASE_DIR/.rig/memory/snapshot-backups" -type f -name 'transferred-*.md' | head -1)
  [ -n "$backup" ]
  grep -Fq '## Resuming from: task-a' "$backup"
}

@test "a shared-header refresh preserves an unowned legacy handoff and backs it up" {
  snapshot="$CASE_DIR/.rig/memory/CONTEXT_SNAPSHOT.md"
  printf '# Old context\n\n## Resuming from: legacy-task\n\n**Next action:** Preserve me.\n' > "$snapshot"
  printf '# New context\n\n**Branch:** main\n' > "$BATS_TEST_TMPDIR/shared.md"
  run "$rig" memory write-snapshot --file "$BATS_TEST_TMPDIR/shared.md" --shared-only --json
  [ "$status" -eq 0 ]
  grep -Fq '# New context' "$snapshot"
  grep -Fq '## Resuming from: legacy-task' "$snapshot"
  backup=$(find "$CASE_DIR/.rig/memory/snapshot-backups" -type f -name '*.md' | head -1)
  [ -n "$backup" ]
  grep -Fq '## Resuming from: legacy-task' "$backup"
}

@test "shared refresh preserves an annotated legacy handoff through repeated writes" {
  snapshot="$CASE_DIR/.rig/memory/CONTEXT_SNAPSHOT.md"
  heading='## Resuming from: website-sprint-3-form-deploy (issue #5, active, blocked)'
  printf '# Old context\n\n%s\n\n**Next action:** Preserve the form deploy.\n' "$heading" > "$snapshot"
  printf '# New context\n' > "$BATS_TEST_TMPDIR/shared.md"
  run "$rig" memory write-snapshot --file "$BATS_TEST_TMPDIR/shared.md" --shared-only --json
  [ "$status" -eq 0 ]
  grep -Fq "$heading" "$snapshot"
  grep -Fq 'task=website-sprint-3-form-deploy owner=legacy' "$snapshot"
  printf '# Newer context\n' > "$BATS_TEST_TMPDIR/shared.md"
  run "$rig" memory write-snapshot --file "$BATS_TEST_TMPDIR/shared.md" --shared-only --json
  [ "$status" -eq 0 ]
  grep -Fq '# Newer context' "$snapshot"
  grep -Fq "$heading" "$snapshot"
  backup=$(find "$CASE_DIR/.rig/memory/snapshot-backups" -type f -name 'legacy-*.md' | head -1)
  [ -n "$backup" ]
  grep -Fq "$heading" "$backup"
}

@test "annotated legacy headings retain canonical ownership and reject duplicate or malformed slugs" {
  snapshot="$CASE_DIR/.rig/memory/CONTEXT_SNAPSHOT.md"
  candidate "$BATS_TEST_TMPDIR/owned.md" feat/a task-a
  printf '# Old context\n\n## Resuming from: task-a (issue #5, blocked)\n\nKeep me.\n' > "$snapshot"
  before=$(cksum "$snapshot")
  run env RIG_SESSION_FILE="$file_a" "$rig" memory write-snapshot --file "$BATS_TEST_TMPDIR/owned.md" --owned-task task-a --json
  [ "$status" -eq 3 ]
  [[ "$output" == *legacy_adoption_required* ]] || return 1
  [ "$before" = "$(cksum "$snapshot")" ]
  printf '\n## Resuming from: task-a\n\nDuplicate.\n' >> "$snapshot"
  before=$(cksum "$snapshot")
  run env RIG_SESSION_FILE="$file_a" "$rig" memory write-snapshot --file "$BATS_TEST_TMPDIR/owned.md" --owned-task task-a --adopt-legacy --json
  [ "$status" -eq 3 ]
  [[ "$output" == *invalid_task_sections* ]] || return 1
  [ "$before" = "$(cksum "$snapshot")" ]
  printf '# Old context\n\n## Resuming from: task-a (issue #5, blocked\n\nMalformed.\n' > "$snapshot"
  before=$(cksum "$snapshot")
  run env RIG_SESSION_FILE="$file_a" "$rig" memory write-snapshot --file "$BATS_TEST_TMPDIR/owned.md" --owned-task task-a --adopt-legacy --json
  [ "$status" -eq 3 ]
  [[ "$output" == *invalid_task_sections* ]] || return 1
  [ "$before" = "$(cksum "$snapshot")" ]
}

@test "marked annotated headings keep their owner and reject mismatched or duplicate markers" {
  snapshot="$CASE_DIR/.rig/memory/CONTEXT_SNAPSHOT.md"
  anchor_a=$(printf '%s' "$a" | python3 -c 'import json,sys; print(json.load(sys.stdin)["anchor"])')
  printf '<!-- rig:handoff-start task=task-a owner=%s -->\n## Resuming from: task-a (issue #5, active)\n\nKeep me.\n<!-- rig:handoff-end -->\n' "$anchor_a" > "$snapshot"
  printf '# New shared context\n' > "$BATS_TEST_TMPDIR/shared.md"
  run "$rig" memory write-snapshot --file "$BATS_TEST_TMPDIR/shared.md" --shared-only --json
  [ "$status" -eq 0 ]
  grep -Fq "task=task-a owner=$anchor_a" "$snapshot"
  grep -Fq '## Resuming from: task-a (issue #5, active)' "$snapshot"
  candidate "$BATS_TEST_TMPDIR/owned.md" feat/b task-a
  before=$(cksum "$snapshot")
  run env RIG_SESSION_FILE="$file_b" "$rig" memory write-snapshot --file "$BATS_TEST_TMPDIR/owned.md" --owned-task task-a --json
  [ "$status" -eq 3 ]
  [[ "$output" == *owner_conflict* ]] || return 1
  [ "$before" = "$(cksum "$snapshot")" ]
  sed 's/## Resuming from: task-a (issue #5, active)/## Resuming from: task-b (issue #5, active)/' "$snapshot" > "$BATS_TEST_TMPDIR/mismatch.md"
  cp "$BATS_TEST_TMPDIR/mismatch.md" "$snapshot"
  before=$(cksum "$snapshot")
  run "$rig" memory write-snapshot --file "$BATS_TEST_TMPDIR/shared.md" --shared-only --json
  [ "$status" -eq 3 ]
  [[ "$output" == *malformed_handoff_markers* ]] || return 1
  [ "$before" = "$(cksum "$snapshot")" ]
  sed 's/## Resuming from: task-b (issue #5, active)/## Resuming from: task-a (issue #5, active)/' "$snapshot" > "$BATS_TEST_TMPDIR/restored.md"
  cp "$BATS_TEST_TMPDIR/restored.md" "$snapshot"
  printf '<!-- rig:handoff-start task=task-a owner=%s -->\n## Resuming from: task-a\n<!-- rig:handoff-end -->\n' "$anchor_a" >> "$snapshot"
  before=$(cksum "$snapshot")
  run "$rig" memory write-snapshot --file "$BATS_TEST_TMPDIR/shared.md" --shared-only --json
  [ "$status" -eq 3 ]
  [[ "$output" == *invalid_task_sections* ]] || return 1
  [ "$before" = "$(cksum "$snapshot")" ]
}

@test "if-missing never replaces a snapshot created before the writer acquires its lock" {
  candidate "$BATS_TEST_TMPDIR/a.md" feat/a task-a
  run env RIG_SESSION_FILE="$file_a" "$rig" memory write-snapshot --file "$BATS_TEST_TMPDIR/a.md" --owned-task task-a --json
  [ "$status" -eq 0 ]
  snapshot="$CASE_DIR/.rig/memory/CONTEXT_SNAPSHOT.md"
  before=$(cksum "$snapshot")
  printf '# Session-end checkpoint\n' > "$BATS_TEST_TMPDIR/checkpoint.md"
  run "$rig" memory write-snapshot --file "$BATS_TEST_TMPDIR/checkpoint.md" --shared-only --if-missing --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"no_write":true'* ]] || return 1
  [ "$before" = "$(cksum "$snapshot")" ]
}

@test "retiring a done handoff preserves other work and backs up the old view" {
  candidate "$BATS_TEST_TMPDIR/a.md" feat/a task-a
  candidate "$BATS_TEST_TMPDIR/b.md" feat/b task-b
  run env RIG_SESSION_FILE="$file_a" "$rig" memory write-snapshot --file "$BATS_TEST_TMPDIR/a.md" --owned-task task-a --json
  [ "$status" -eq 0 ]
  run env RIG_SESSION_FILE="$file_b" "$rig" memory write-snapshot --file "$BATS_TEST_TMPDIR/b.md" --owned-task task-b --json
  [ "$status" -eq 0 ]
  snapshot="$CASE_DIR/.rig/memory/CONTEXT_SNAPSHOT.md"
  before=$(cksum "$snapshot")
  mkdir -p "$CASE_DIR/.rig/tasks/active" "$CASE_DIR/.rig/tasks/done"
  printf '# Task A\n' > "$CASE_DIR/.rig/tasks/active/TASK_task-a.md"
  printf '# Shared state\n' > "$BATS_TEST_TMPDIR/shared.md"
  run "$rig" memory write-snapshot --file "$BATS_TEST_TMPDIR/shared.md" --shared-only \
    --retire-task task-a --done-task-file "$CASE_DIR/.rig/tasks/done/TASK_task-a.md" --json
  [ "$status" -eq 3 ]
  [ "$before" = "$(cksum "$snapshot")" ]
  mv "$CASE_DIR/.rig/tasks/active/TASK_task-a.md" "$CASE_DIR/.rig/tasks/done/TASK_task-a.md"
  run "$rig" memory write-snapshot --file "$BATS_TEST_TMPDIR/shared.md" --shared-only \
    --retire-task task-b --done-task-file "$CASE_DIR/.rig/tasks/done/TASK_task-a.md" --json
  [ "$status" -eq 3 ]
  [[ "$output" == *done_task_mismatch* ]] || return 1
  [ "$before" = "$(cksum "$snapshot")" ]
  run "$rig" memory write-snapshot --file "$BATS_TEST_TMPDIR/shared.md" --shared-only \
    --retire-task task-a --done-task-file "$CASE_DIR/.rig/tasks/done/TASK_task-a.md" --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"retired_tasks":["task-a"]'* ]] || return 1
  if grep -Fq '## Resuming from: task-a' "$snapshot"; then return 1; fi
  grep -Fq '## Resuming from: task-b' "$snapshot"
  backup=$(find "$CASE_DIR/.rig/memory/snapshot-backups" -type f -name 'retired-*.md' | head -1)
  [ -n "$backup" ]
  grep -Fq '## Resuming from: task-a' "$backup"
}

@test "legacy task ownership requires explicit adoption and keeps the original backup" {
  snapshot="$CASE_DIR/.rig/memory/CONTEXT_SNAPSHOT.md"
  printf '# Old context\n\n## Resuming from: task-a\n\n**Next action:** Old work.\n' > "$snapshot"
  before=$(cksum "$snapshot")
  candidate "$BATS_TEST_TMPDIR/a.md" feat/a task-a
  run env RIG_SESSION_FILE="$file_a" "$rig" memory write-snapshot --file "$BATS_TEST_TMPDIR/a.md" --owned-task task-a --json
  [ "$status" -eq 3 ]
  [[ "$output" == *legacy_adoption_required* ]] || return 1
  [ "$before" = "$(cksum "$snapshot")" ]
  run env RIG_SESSION_FILE="$file_a" "$rig" memory write-snapshot --file "$BATS_TEST_TMPDIR/a.md" --owned-task task-a --adopt-legacy --json
  [ "$status" -eq 0 ]
  grep -Fq 'owner=' "$snapshot"
  backup=$(find "$CASE_DIR/.rig/memory/snapshot-backups" -type f -name '*.md' | head -1)
  [ -n "$backup" ]
  grep -Fq '**Next action:** Old work.' "$backup"
}

@test "two concurrent session writes preserve both sections" {
  candidate "$BATS_TEST_TMPDIR/a.md" feat/a task-a
  candidate "$BATS_TEST_TMPDIR/b.md" feat/b task-b
  run bash -c '
    RIG_SESSION_FILE="$1" "$3" memory write-snapshot --file "$4" --owned-task task-a --json >/dev/null & p1=$!
    RIG_SESSION_FILE="$2" "$3" memory write-snapshot --file "$5" --owned-task task-b --json >/dev/null & p2=$!
    wait "$p1" && wait "$p2"
  ' _ "$file_a" "$file_b" "$rig" "$BATS_TEST_TMPDIR/a.md" "$BATS_TEST_TMPDIR/b.md"
  [ "$status" -eq 0 ]
  snapshot="$CASE_DIR/.rig/memory/CONTEXT_SNAPSHOT.md"
  [ "$(grep -c '^## Resuming from:' "$snapshot")" -eq 2 ]
}

@test "external stealth storage preserves Claude and Codex handoffs in a dirty checkout" {
  external="$(cd "$BATS_TEST_TMPDIR" && pwd -P)/external rig"
  old_rig="$(cd "$CASE_DIR" && pwd -P)/.rig"
  mv "$CASE_DIR/.rig" "$external"
  printf '%s\n' "$external" > "$CASE_DIR/.rigpath"
  printf 'uncommitted work\n' > "$CASE_DIR/dirty.txt"
  file_a="$external${file_a#"$old_rig"}"
  file_b="$external${file_b#"$old_rig"}"
  candidate "$BATS_TEST_TMPDIR/a.md" feat/a task-a
  candidate "$BATS_TEST_TMPDIR/b.md" feat/b task-b
  run env RIG_SESSION_FILE="$file_a" "$rig" memory write-snapshot --file "$BATS_TEST_TMPDIR/a.md" --owned-task task-a --json
  [ "$status" -eq 0 ]
  run env RIG_SESSION_FILE="$file_b" "$rig" memory write-snapshot --file "$BATS_TEST_TMPDIR/b.md" --owned-task task-b --json
  [ "$status" -eq 0 ]
  [ ! -e "$CASE_DIR/.rig" ]
  [ -f "$CASE_DIR/dirty.txt" ]
  [ "$(grep -c '^## Resuming from:' "$external/memory/CONTEXT_SNAPSHOT.md")" -eq 2 ]
}

@test "stealth installer ships and manifests the snapshot helper" {
  installed="$BATS_TEST_TMPDIR/installed"
  external="$BATS_TEST_TMPDIR/installed rig"
  mkdir -p "$installed"
  git -C "$installed" init -q
  run bash "$BATS_TEST_DIRNAME/../install.sh" --project-only --target "$installed" \
    --project-name Test --tracking stealth --rig-dir "$external" --strategy upgrade
  [ "$status" -eq 0 ]
  [ -f "$installed/bin/rig-snapshot.py" ]
  grep -Fq 'bin/rig-snapshot.py' "$external/memory/.rig-manifest"
  printf '# Installed snapshot\n' > "$BATS_TEST_TMPDIR/installed.md"
  run "$installed/bin/rig" memory write-snapshot --file "$BATS_TEST_TMPDIR/installed.md" --shared-only --json
  [ "$status" -eq 0 ]
  grep -Fq '# Installed snapshot' "$external/memory/CONTEXT_SNAPSHOT.md"
  # A pre-helper install has no helper on disk; upgrade must add it.
  rm "$installed/bin/rig-snapshot.py"
  run bash "$BATS_TEST_DIRNAME/../install.sh" --project-only --target "$installed" \
    --project-name Test --tracking stealth --rig-dir "$external" --strategy upgrade
  [ "$status" -eq 0 ]
  [ -f "$installed/bin/rig-snapshot.py" ]
}

@test "in-repo snapshot runtime files leave a clean checkout" {
  cp "$BATS_TEST_DIRNAME/../templates/project/.rig/memory/.gitignore" "$CASE_DIR/.rig/memory/.gitignore"
  git -C "$CASE_DIR" add -A
  git -C "$CASE_DIR" -c user.name=Test -c user.email=test@example.com commit -q -m baseline
  snapshot="$CASE_DIR/.rig/memory/CONTEXT_SNAPSHOT.md"
  printf '# Old view\n\n## Resuming from: legacy-task\n\nKeep me.\n' > "$snapshot"
  draft="$CASE_DIR/.rig/memory/.snapshot-draft-test.md"
  printf '# New view\n' > "$draft"
  run "$rig" memory write-snapshot --file "$draft" --shared-only --json
  [ "$status" -eq 0 ]
  run "$rig" memory workflow-lock acquire --owner-anchor test --json
  [ "$status" -eq 0 ]
  for runtime in .snapshot-write.lock .memory-workflow-gate.lock .memory-workflow-in-progress .snapshot-draft-test.md snapshot-backups/old.md workflow-lock-archive/old.json; do
    git -C "$CASE_DIR" check-ignore -q ".rig/memory/$runtime" || return 1
  done
  [ -z "$(git -C "$CASE_DIR" status --porcelain)" ]
}

@test "workflow lock records its owner and refuses another live owner" {
  anchor=$(printf '%s' "$a" | python3 -c 'import json,sys; print(json.load(sys.stdin)["anchor"])')
  run "$rig" memory workflow-lock acquire --owner-anchor "$anchor" --provider-pid "$$" --json
  [ "$status" -eq 0 ]
  token=$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')
  lock="$CASE_DIR/.rig/memory/.memory-workflow-in-progress"
  LOCK_F="$lock" ANCHOR="$anchor" python3 -c 'import json,os; d=json.load(open(os.environ["LOCK_F"])); assert d["owner_anchor"]==os.environ["ANCHOR"] and d["pid_source"]=="provider" and d["started_at"]'
  run "$rig" memory workflow-lock acquire --owner-anchor another --json
  [ "$status" -eq 3 ]
  [[ "$output" == *workflow_busy* && "$output" == *"$anchor"* ]] || return 1
  run "$rig" memory workflow-lock release --token wrong --json
  [ "$status" -eq 3 ]
  [ -f "$lock" ]
  run "$rig" memory workflow-lock release --token "$token" --json
  [ "$status" -eq 0 ]
  [ ! -e "$lock" ]
}

@test "workflow lock archives and recovers a dead provider owner" {
  run "$rig" memory workflow-lock acquire --owner-anchor prior --provider-pid 999999 --json
  [ "$status" -eq 0 ]
  run "$rig" memory workflow-lock acquire --owner-anchor next --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"recovered_stale":true'* ]] || return 1
  [ "$(find "$CASE_DIR/.rig/memory/workflow-lock-archive" -type f -name '*.json' | wc -l | tr -d ' ')" -eq 1 ]
}

@test "workflow lock keeps a live provider owner beyond the age fallback" {
  run "$rig" memory workflow-lock acquire --owner-anchor live --provider-pid "$$" --json
  [ "$status" -eq 0 ]
  token=$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')
  lock="$CASE_DIR/.rig/memory/.memory-workflow-in-progress"
  LOCK_F="$lock" python3 -c 'import json,os,time; p=os.environ["LOCK_F"]; d=json.load(open(p)); d["started_epoch"]=time.time()-4000; open(p,"w").write(json.dumps(d))'
  run "$rig" memory workflow-lock acquire --owner-anchor other --recover-stale --json
  [ "$status" -eq 3 ]
  OUTPUT="$output" python3 -c 'import json,os; d=json.loads(os.environ["OUTPUT"]); assert d["reason"]=="workflow_busy" and d["owner_anchor"]=="live"'
  run "$rig" memory workflow-lock release --token "$token" --json
  [ "$status" -eq 0 ]
}

@test "an aged tool-sourced lock requires explicit recovery" {
  run "$rig" memory workflow-lock acquire --owner-anchor old-tool --json
  [ "$status" -eq 0 ]
  run "$rig" memory workflow-lock acquire --owner-anchor new-tool --recover-stale --json
  [ "$status" -eq 3 ]
  [[ "$output" == *workflow_busy* ]] || return 1
  lock="$CASE_DIR/.rig/memory/.memory-workflow-in-progress"
  LOCK_F="$lock" python3 -c 'import json,os,time; p=os.environ["LOCK_F"]; d=json.load(open(p)); d["started_epoch"]=time.time()-4000; open(p,"w").write(json.dumps(d))'
  run "$rig" memory workflow-lock acquire --owner-anchor new-tool --json
  [ "$status" -eq 3 ]
  [[ "$output" == *workflow_busy* ]] || return 1
  run "$rig" memory workflow-lock acquire --owner-anchor new-tool --recover-stale --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"recovered_stale":true'* ]] || return 1
}

@test "wrap releases its workflow lock when a malformed snapshot blocks the write" {
  run "$rig" memory workflow-lock acquire --owner-anchor wrap --provider-pid "$$" --json
  [ "$status" -eq 0 ]
  token=$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')
  draft="$CASE_DIR/.rig/memory/.snapshot-draft-${token}.md"
  printf '# New shared context\n' > "$draft"
  printf '<!-- rig:handoff-start broken -->\n' > "$CASE_DIR/.rig/memory/CONTEXT_SNAPSHOT.md"
  snapshot_command_block wrap > "$BATS_TEST_TMPDIR/wrap-snapshot.sh"
  run env REPO="$CASE_DIR" RIG_DIR="$CASE_DIR/.rig" SNAP_LOCK_TOKEN="$token" bash "$BATS_TEST_TMPDIR/wrap-snapshot.sh"
  [ "$status" -ne 0 ]
  [ -f "$draft" ]
  [ ! -e "$CASE_DIR/.rig/memory/.memory-workflow-in-progress" ]
  run "$rig" memory workflow-lock acquire --owner-anchor retry --json
  [ "$status" -eq 0 ]
}

@test "wrap writes a continuation handoff despite its inherited launcher anchor" {
  local original_anchor continuation continuation_anchor token draft snapshot
  original_anchor=$(printf '%s' "$a" | python3 -c 'import json,sys; print(json.load(sys.stdin)["anchor"])')
  run env RIG_SESSION_FILE="$file_a" RIG_SESSION_ANCHOR="$original_anchor" \
    "$rig" session-name set --final --complete 'First segment'
  [ "$status" -eq 0 ]
  continuation=$(env RIG_SESSION_FILE="$file_a" RIG_SESSION_ANCHOR="$original_anchor" \
    "$rig" session bind --agent claude --native-session-id thread-a --source resume --allow-continuation)
  continuation_anchor=$(printf '%s' "$continuation" | python3 -c 'import json,sys; print(json.load(sys.stdin)["anchor"])')
  run env RIG_SESSION_FILE="$file_a" RIG_SESSION_ANCHOR="$original_anchor" "$rig" session current --json
  [ "$status" -eq 0 ]
  [[ "$output" == *"$continuation_anchor"* ]] || return 1

  token=$($rig memory workflow-lock acquire --owner-anchor "$continuation_anchor" --json | \
    python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')
  draft="$CASE_DIR/.rig/memory/.snapshot-draft-${token}.md"
  candidate "$draft" feat/continuation task-a
  snapshot_command_block wrap > "$BATS_TEST_TMPDIR/wrap-continuation.sh"
  run env RIG_SESSION_FILE="$file_a" RIG_SESSION_ANCHOR="$original_anchor" \
    REPO="$CASE_DIR" RIG_DIR="$CASE_DIR/.rig" SNAP_LOCK_TOKEN="$token" \
    bash "$BATS_TEST_TMPDIR/wrap-continuation.sh"
  [ "$status" -eq 0 ]
  snapshot="$CASE_DIR/.rig/memory/CONTEXT_SNAPSHOT.md"
  grep -Fq "task=task-a owner=$continuation_anchor" "$snapshot"
  [ ! -e "$draft" ]
}

@test "post-merge releases its workflow lock when a malformed snapshot blocks the write" {
  run "$rig" memory workflow-lock acquire --owner-anchor merge --provider-pid "$$" --json
  [ "$status" -eq 0 ]
  token=$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')
  draft="$CASE_DIR/.rig/memory/.snapshot-draft-${token}.md"
  printf '# New shared context\n' > "$draft"
  printf '<!-- rig:handoff-start broken -->\n' > "$CASE_DIR/.rig/memory/CONTEXT_SNAPSHOT.md"
  snapshot_command_block post-merge > "$BATS_TEST_TMPDIR/post-merge-snapshot.sh"
  run env REPO="$CASE_DIR" RIG_DIR="$CASE_DIR/.rig" SNAP_LOCK_TOKEN="$token" bash "$BATS_TEST_TMPDIR/post-merge-snapshot.sh"
  [ "$status" -ne 0 ]
  [ -f "$draft" ]
  [ ! -e "$CASE_DIR/.rig/memory/.memory-workflow-in-progress" ]
  run "$rig" memory workflow-lock acquire --owner-anchor retry --json
  [ "$status" -eq 0 ]
}

@test "a tool-sourced lock remains owned when its age exceeds thirty minutes" {
  run "$rig" memory workflow-lock acquire --owner-anchor active-tool --json
  [ "$status" -eq 0 ]
  token=$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')
  lock="$CASE_DIR/.rig/memory/.memory-workflow-in-progress"
  LOCK_F="$lock" python3 -c 'import json,os,time; p=os.environ["LOCK_F"]; d=json.load(open(p)); d["started_epoch"]=time.time()-4000; open(p,"w").write(json.dumps(d))'
  run "$rig" memory workflow-lock acquire --owner-anchor intruder --json
  [ "$status" -eq 3 ]
  [[ "$output" == *workflow_busy* ]] || return 1
  run "$rig" memory workflow-lock release --token "$token" --json
  [ "$status" -eq 0 ]
}

@test "a crashed short snapshot marker is recovered without losing the old view" {
  snapshot="$CASE_DIR/.rig/memory/CONTEXT_SNAPSHOT.md"
  printf '# Old context\n' > "$snapshot"
  printf '{"token":"11111111-1111-4111-8111-111111111111","anchor":"old","pid":999999,"started_at":"2026-01-01T00:00:00Z"}\n' \
    > "$CASE_DIR/.rig/memory/.snapshot-write-in-progress"
  printf '# New context\n' > "$BATS_TEST_TMPDIR/shared.md"
  run "$rig" memory write-snapshot --file "$BATS_TEST_TMPDIR/shared.md" --shared-only --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"recovered_lock":true'* ]] || return 1
  grep -Fq '# New context' "$snapshot"
  [ ! -e "$CASE_DIR/.rig/memory/.snapshot-write-in-progress" ]
  backup=$(find "$CASE_DIR/.rig/memory/snapshot-backups" -type f -name '*.md' | head -1)
  grep -Fq '# Old context' "$backup"
}

@test "Stop leaves a materialized task snapshot unchanged" {
  candidate "$BATS_TEST_TMPDIR/a.md" feat/a task-a
  run env RIG_SESSION_FILE="$file_a" "$rig" memory write-snapshot --file "$BATS_TEST_TMPDIR/a.md" --owned-task task-a --json
  [ "$status" -eq 0 ]
  snapshot="$CASE_DIR/.rig/memory/CONTEXT_SNAPSHOT.md"
  before=$(cksum "$snapshot")
  mkdir -p "$CASE_DIR/.claude/hooks"
  cp "$BATS_TEST_DIRNAME/../templates/project/.claude/hooks/stop.sh" "$CASE_DIR/.claude/hooks/stop.sh"
  run bash -c 'cd "$1" && printf "%s" "{\"hook_event_name\":\"Stop\"}" | RIG_SESSION_LOG="$2" bash .claude/hooks/stop.sh' \
    _ "$CASE_DIR" "$BATS_TEST_TMPDIR/session.log"
  [ "$status" -eq 0 ]
  [ "$before" = "$(cksum "$snapshot")" ]
}

@test "SessionEnd preserves another task handoff after a progress stub" {
  candidate "$BATS_TEST_TMPDIR/a.md" feat/a task-a
  candidate "$BATS_TEST_TMPDIR/b.md" feat/b task-b
  run env RIG_SESSION_FILE="$file_a" "$rig" memory write-snapshot --file "$BATS_TEST_TMPDIR/a.md" --owned-task task-a --json
  [ "$status" -eq 0 ]
  run env RIG_SESSION_FILE="$file_b" "$rig" memory write-snapshot --file "$BATS_TEST_TMPDIR/b.md" --owned-task task-b --json
  [ "$status" -eq 0 ]
  snapshot="$CASE_DIR/.rig/memory/CONTEXT_SNAPSHOT.md"
  before=$(cksum "$snapshot")
  printf 'Auto-logged by post-tool hook\n' > "$CASE_DIR/.rig/memory/PROGRESS.md"
  mkdir -p "$CASE_DIR/.claude/hooks"
  cp "$BATS_TEST_DIRNAME/../templates/project/.claude/hooks/stop.sh" "$CASE_DIR/.claude/hooks/stop.sh"
  run bash -c 'cd "$1" && printf "%s" "{\"source\":\"logout\"}" | RIG_SESSION_LOG="$2" bash .claude/hooks/stop.sh' \
    _ "$CASE_DIR" "$BATS_TEST_TMPDIR/session.log"
  [ "$status" -eq 0 ]
  [ "$before" = "$(cksum "$snapshot")" ]
  grep -Fq '## Resuming from: task-a' "$snapshot"
  grep -Fq '## Resuming from: task-b' "$snapshot"
  [ -e "$CASE_DIR/.rig/memory/.wrap-needed" ]
}

@test "SessionEnd creates a minimal snapshot only when none exists" {
  printf 'Auto-logged by post-tool hook\n' > "$CASE_DIR/.rig/memory/PROGRESS.md"
  mkdir -p "$CASE_DIR/.claude/hooks"
  cp "$BATS_TEST_DIRNAME/../templates/project/.claude/hooks/stop.sh" "$CASE_DIR/.claude/hooks/stop.sh"
  run bash -c 'cd "$1" && printf "%s" "{\"source\":\"logout\"}" | RIG_SESSION_LOG="$2" bash .claude/hooks/stop.sh' \
    _ "$CASE_DIR" "$BATS_TEST_TMPDIR/session.log"
  [ "$status" -eq 0 ]
  grep -Fq 'session-end checkpoint' "$CASE_DIR/.rig/memory/CONTEXT_SNAPSHOT.md"
}
