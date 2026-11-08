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
  run "$rig" memory workflow-lock acquire --owner-anchor other --json
  [ "$status" -eq 3 ]
  OUTPUT="$output" python3 -c 'import json,os; d=json.loads(os.environ["OUTPUT"]); assert d["reason"]=="workflow_busy" and d["owner_anchor"]=="live"'
  run "$rig" memory workflow-lock release --token "$token" --json
  [ "$status" -eq 0 ]
}

@test "workflow lock uses age fallback when provider PID is unavailable" {
  run "$rig" memory workflow-lock acquire --owner-anchor old-tool --json
  [ "$status" -eq 0 ]
  lock="$CASE_DIR/.rig/memory/.memory-workflow-in-progress"
  LOCK_F="$lock" python3 -c 'import json,os,time; p=os.environ["LOCK_F"]; d=json.load(open(p)); d["started_epoch"]=time.time()-4000; open(p,"w").write(json.dumps(d))'
  run "$rig" memory workflow-lock acquire --owner-anchor new-tool --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"recovered_stale":true'* ]] || return 1
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
