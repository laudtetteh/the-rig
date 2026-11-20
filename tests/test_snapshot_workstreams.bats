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

post_merge_block() {
  local heading="$1"
  python3 - "$BATS_TEST_DIRNAME/../templates/project/.claude/commands/post-merge.md" "$heading" <<'PY'
import pathlib, sys
content = pathlib.Path(sys.argv[1]).read_text()
section = content.index(sys.argv[2])
start = content.index('```bash\n[[ -n "${POST_MERGE_ACK_SHA:-}" ]]', section) + len('```bash\n')
end = content.index('\n```', start)
print(content[start:end].replace('[BASE_BRANCH]', 'main'))
PY
}

post_merge_completion_block() {
  python3 - "$BATS_TEST_DIRNAME/../templates/project/.claude/commands/post-merge.md" <<'PY'
import pathlib, sys
content = pathlib.Path(sys.argv[1]).read_text()
section = content.index('### Step 5 — After confirmation: write to session file')
start = content.index('```bash\n', section) + len('```bash\n')
end = content.index('\n```', start)
print(content[start:end])
PY
}

post_merge_verify_block() {
  python3 - "$BATS_TEST_DIRNAME/../templates/project/.rig/processes/POST_MERGE_WORKFLOW.md" <<'PY'
import pathlib, sys
content = pathlib.Path(sys.argv[1]).read_text()
section = content.index('Read-only merge verification')
start = content.index('```bash\n', section) + len('```bash\n')
end = content.index('\n```', start)
print(content[start:end].replace('[BASE_BRANCH]', 'main'))
PY
}

post_merge_gate_block() {
  python3 - "$BATS_TEST_DIRNAME/../templates/project/.rig/processes/POST_MERGE_WORKFLOW.md" <<'PY'
import pathlib, sys
content = pathlib.Path(sys.argv[1]).read_text()
section = content.index('Before the first memory write')
start = content.index('```bash\nCURRENT_BRANCH=$(git branch --show-current)', section) + len('```bash\n')
end = content.index('\n```', start)
print(content[start:end].replace('[BASE_BRANCH]', 'main'))
PY
}

post_merge_feature_diff_block() {
  python3 - "$BATS_TEST_DIRNAME/../templates/project/.claude/commands/post-merge.md" <<'PY'
import pathlib, sys
content = pathlib.Path(sys.argv[1]).read_text()
section = content.index('## Feature doc freshness step')
start = content.index('```bash\n', section) + len('```bash\n')
end = content.index('\n   ```', start)
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
baseline = s.index('WRAP_MARKER_TOKEN=$(python3')
first_write = s.index('## Trim step — PROGRESS.md')
release = s.index('"$REPO/bin/rig" memory workflow-lock release --token "$SNAP_LOCK_TOKEN" --json || exit 1')
guarded_clear = s.index('--adopt-legacy-if-marker-token "${WRAP_MARKER_TOKEN:-}"')
pr_prompt = s.index('Update PR description? [yes / no]')
name_prompt = s.index('### Step 4 — Present and confirm')
assert git < dirty < report < acquire < baseline < first_write < release < pr_prompt < name_prompt < guarded_clear
assert 'After printing the Wrap report' in s[acquire:first_write]
PY
  [ "$status" -eq 0 ]
}

@test "post-merge skips before acquiring and releases before name confirmation" {
  run python3 - "$BATS_TEST_DIRNAME/../templates/project/.claude/commands/post-merge.md" <<'PY'
import pathlib, sys
s = pathlib.Path(sys.argv[1]).read_text()
git = s.index('## Git state check')
gate = s.index("Before acquiring the memory workflow lock, use Step 1's stageability gate")
report = s.index('## Post-merge report step')
skip = s.index('stop before acquiring the workflow lock')
acquire = s.index('## Concurrent session guard')
snapshot = s.index('For the snapshot step, write')
release = s.index('"$REPO/bin/rig" memory workflow-lock release --token "$SNAP_LOCK_TOKEN" --json || exit 1')
ack = s.index('"$REPO/bin/rig" session obligation clear --kind post-merge')
name_prompt = s.index('### Step 4 — Present and confirm')
assert git < gate < report < skip < acquire < snapshot < release < ack < name_prompt
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

@test "post-merge verifies a merged SHA from a dirty shared checkout without changing its branch or files" {
  local project="$BATS_TEST_TMPDIR/merge-project" remote="$BATS_TEST_TMPDIR/remote.git" linked="$BATS_TEST_TMPDIR/linked"
  mkdir -p "$project"
  git init -q --bare "$remote"
  git -C "$project" init -q -b main
  git -C "$project" config user.name Fixture
  git -C "$project" config user.email fixture@example.com
  git -C "$project" remote add origin "$remote"
  printf 'seed\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" commit -qm seed
  git -C "$project" checkout -q -b feat/one
  printf 'one\n' > "$project/one.txt"
  git -C "$project" add one.txt
  git -C "$project" commit -qm one
  git -C "$project" checkout -q main
  git -C "$project" merge -q --no-ff feat/one -m 'Merge one'
  local merge_sha
  merge_sha="$(git -C "$project" rev-parse HEAD)"
  git -C "$project" checkout -q -b feat/two
  printf 'two\n' > "$project/two.txt"
  git -C "$project" add two.txt
  git -C "$project" commit -qm two
  git -C "$project" checkout -q main
  git -C "$project" merge -q --no-ff feat/two -m 'Merge two'
  local merge_sha_two
  merge_sha_two="$(git -C "$project" rev-parse HEAD)"
  printf 'later\n' > "$project/later.txt"
  git -C "$project" add later.txt
  git -C "$project" commit -qm later
  git -C "$project" push -q origin main
  git -C "$project" worktree add -q -b feat/shared "$linked" main
  printf 'unrelated\n' > "$linked/local.txt"
  local before
  before="$(git -C "$linked" status --porcelain)"
  post_merge_verify_block > "$BATS_TEST_TMPDIR/verify.sh"
  run bash -c 'cd "$1" && POST_MERGE_EXPECTED_SHAS=("$2" "$3") && source "$4"' _ "$linked" "$merge_sha" "$merge_sha_two" "$BATS_TEST_TMPDIR/verify.sh"
  [ "$status" -eq 0 ]
  [ "$(git -C "$linked" branch --show-current)" = feat/shared ]
  [ "$(git -C "$linked" status --porcelain)" = "$before" ]

  post_merge_feature_diff_block > "$BATS_TEST_TMPDIR/feature-diff.sh"
  run bash -c 'cd "$1" && POST_MERGE_EXPECTED_SHAS=("$2" "$3") && source "$4"' _ "$linked" "$merge_sha" "$merge_sha_two" "$BATS_TEST_TMPDIR/feature-diff.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *one.txt* && "$output" == *two.txt* ]] || return 1
  [[ "$output" != *later.txt* ]] || return 1
  run bash -c 'cd "$1" && POST_MERGE_EXPECTED_SHAS=("deadbeef") && source "$2"' _ "$linked" "$BATS_TEST_TMPDIR/verify.sh"
  [ "$status" -ne 0 ]
  [ "$(git -C "$linked" status --porcelain)" = "$before" ]

  post_merge_gate_block > "$BATS_TEST_TMPDIR/gate.sh"
  local external="$BATS_TEST_TMPDIR/external-rig"
  mkdir -p "$external/memory"
  run env REPO="$linked" RIG_DIR="$external" bash -c 'cd "$1" && POST_MERGE_EXPECTED_SHAS=("$2") && source "$3"' _ "$linked" "$merge_sha" "$BATS_TEST_TMPDIR/gate.sh"
  [ "$status" -eq 0 ]
  [ "$(git -C "$linked" status --porcelain)" = "$before" ]
  run env REPO="$linked" RIG_DIR="$linked/.rig" bash -c 'cd "$1" && POST_MERGE_EXPECTED_SHAS=("$2") && source "$3"' _ "$linked" "$merge_sha" "$BATS_TEST_TMPDIR/gate.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"clean main checkout"* ]] || return 1
  [ "$(git -C "$linked" status --porcelain)" = "$before" ]
}

@test "post-merge acknowledges its verified SHA before naming but preserves a newer merge" {
  local marker="$CASE_DIR/.rig/memory/.post-merge-pending" anchor sha_a sha_b
  anchor="$(SESSION_F="$file_a" python3 -c 'import json,os; print(json.load(open(os.environ["SESSION_F"]))["anchor"])')"
  sha_a=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  sha_b=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  post_merge_block '## Exact merge acknowledgement' > "$BATS_TEST_TMPDIR/ack.sh"
  printf 'merge_sha=%s\nmerged_at=2026-11-15T10:00:00-08:00\n' "$sha_a" > "$marker"
  run env RIG_SESSION_FILE="$file_a" "$rig" session obligation mark --kind post-merge --merge-sha "$sha_a" --json
  [ "$status" -eq 0 ]
  run env REPO="$CASE_DIR" RIG_DIR="$CASE_DIR/.rig" RIG_SESSION_FILE="$file_a" POST_MERGE_SESSION_ANCHOR="$anchor" POST_MERGE_ACK_SHA="$sha_a" bash "$BATS_TEST_TMPDIR/ack.sh"
  [ "$status" -eq 0 ]
  [ ! -e "$marker" ]
  SESSION_F="$file_a" python3 -c 'import json,os; d=json.load(open(os.environ["SESSION_F"])); assert d["obligations"]["post_merge"]["merge_sha"]=="a"*40 and d["obligations"]["post_merge"]["acknowledged_at"]'

  printf 'merge_sha=%s\nmerged_at=2026-11-15T11:00:00-08:00\n' "$sha_a" > "$marker"
  run env RIG_SESSION_FILE="$file_a" "$rig" session obligation mark --kind post-merge --merge-sha "$sha_a" --json
  [ "$status" -eq 0 ]
  printf 'merge_sha=%s\nmerged_at=2026-11-15T12:00:00-08:00\n' "$sha_b" > "$marker"
  run env RIG_SESSION_FILE="$file_a" "$rig" session obligation mark --kind post-merge --merge-sha "$sha_b" --json
  [ "$status" -eq 0 ]
  run env REPO="$CASE_DIR" RIG_DIR="$CASE_DIR/.rig" RIG_SESSION_FILE="$file_a" POST_MERGE_SESSION_ANCHOR="$anchor" POST_MERGE_ACK_SHA="$sha_a" bash "$BATS_TEST_TMPDIR/ack.sh"
  [ "$status" -ne 0 ]
  grep -Fxq "merge_sha=$sha_b" "$marker"
  SESSION_F="$file_a" python3 -c 'import json,os; d=json.load(open(os.environ["SESSION_F"])); assert d["obligations"]["post_merge"]["merge_sha"]=="b"*40 and d["obligations"]["post_merge"]["pending"] is True'
  run env REPO="$CASE_DIR" RIG_DIR="$CASE_DIR/.rig" RIG_SESSION_FILE="$file_a" POST_MERGE_SESSION_ANCHOR="$anchor" POST_MERGE_ACK_SHA="$sha_b" bash "$BATS_TEST_TMPDIR/ack.sh"
  [ "$status" -eq 0 ]
  [ ! -e "$marker" ]
}

@test "hookless post-merge can finish only when its exact session has no pending obligation" {
  local marker="$CASE_DIR/.rig/memory/.post-merge-pending" anchor
  anchor="$(SESSION_F="$file_a" python3 -c 'import json,os; print(json.load(open(os.environ["SESSION_F"]))["anchor"])')"
  post_merge_block '## Exact merge acknowledgement' > "$BATS_TEST_TMPDIR/ack.sh"
  run env REPO="$CASE_DIR" RIG_DIR="$CASE_DIR/.rig" RIG_SESSION_FILE="$file_a" POST_MERGE_SESSION_ANCHOR="$anchor" POST_MERGE_ACK_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa bash "$BATS_TEST_TMPDIR/ack.sh"
  [ "$status" -eq 0 ]
  [ ! -e "$marker" ]
  SESSION_F="$file_a" python3 -c 'import json,os; d=json.load(open(os.environ["SESSION_F"])); assert d.get("obligations",{}).get("post_merge",{}).get("pending") is not True'

  printf 'merge_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' > "$marker"
  run env RIG_SESSION_FILE="$file_a" "$rig" session obligation mark --kind post-merge --merge-sha aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --json
  [ "$status" -eq 0 ]
  rm "$marker"
  run env REPO="$CASE_DIR" RIG_DIR="$CASE_DIR/.rig" RIG_SESSION_FILE="$file_a" POST_MERGE_SESSION_ANCHOR="$anchor" POST_MERGE_ACK_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa bash "$BATS_TEST_TMPDIR/ack.sh"
  [ "$status" -ne 0 ]
  SESSION_F="$file_a" python3 -c 'import json,os; d=json.load(open(os.environ["SESSION_F"])); assert d["obligations"]["post_merge"]["pending"] is True'
}

@test "hookless post-merge final naming succeeds after verified housekeeping without a marker" {
  local anchor
  anchor="$(SESSION_F="$file_a" python3 -c 'import json,os; print(json.load(open(os.environ["SESSION_F"]))["anchor"])')"
  post_merge_block '## Exact merge acknowledgement' > "$BATS_TEST_TMPDIR/ack.sh"
  post_merge_completion_block > "$BATS_TEST_TMPDIR/complete.sh"
  run env REPO="$CASE_DIR" RIG_DIR="$CASE_DIR/.rig" RIG_SESSION_FILE="$file_a" POST_MERGE_SESSION_ANCHOR="$anchor" POST_MERGE_ACK_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa bash "$BATS_TEST_TMPDIR/ack.sh"
  [ "$status" -eq 0 ]
  run env REPO="$CASE_DIR" RIG_DIR="$CASE_DIR/.rig" RIG_SESSION_FILE="$file_a" SESSION_FILE="$file_a" SESSION_UUID="$anchor" POST_MERGE_ACK_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa CONFIRMED_NAME='fix hookless merge #607' bash "$BATS_TEST_TMPDIR/complete.sh"
  [ "$status" -eq 0 ]
  [ ! -e "$CASE_DIR/.rig/memory/.post-merge-pending" ]
}

@test "post-merge final naming refuses a newer marker after the processed merge was acknowledged" {
  local anchor marker="$CASE_DIR/.rig/memory/.post-merge-pending" sha_a sha_b
  anchor="$(SESSION_F="$file_a" python3 -c 'import json,os; print(json.load(open(os.environ["SESSION_F"]))["anchor"])')"
  sha_a=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  sha_b=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  post_merge_block '## Exact merge acknowledgement' > "$BATS_TEST_TMPDIR/ack.sh"
  post_merge_completion_block > "$BATS_TEST_TMPDIR/complete.sh"
  printf 'merge_sha=%s\nmerged_at=2026-11-15T10:00:00-08:00\n' "$sha_a" > "$marker"
  run env RIG_SESSION_FILE="$file_a" "$rig" session obligation mark --kind post-merge --merge-sha "$sha_a" --json
  [ "$status" -eq 0 ]
  run env REPO="$CASE_DIR" RIG_DIR="$CASE_DIR/.rig" RIG_SESSION_FILE="$file_a" POST_MERGE_SESSION_ANCHOR="$anchor" POST_MERGE_ACK_SHA="$sha_a" bash "$BATS_TEST_TMPDIR/ack.sh"
  [ "$status" -eq 0 ]
  [ ! -e "$marker" ]
  printf 'merge_sha=%s\nmerged_at=2026-11-15T11:00:00-08:00\nanchor=\n' "$sha_b" > "$marker"
  run env REPO="$CASE_DIR" RIG_DIR="$CASE_DIR/.rig" RIG_SESSION_FILE="$file_a" SESSION_FILE="$file_a" SESSION_UUID="$anchor" POST_MERGE_ACK_SHA="$sha_a" CONFIRMED_NAME='merge A only' bash "$BATS_TEST_TMPDIR/complete.sh"
  [ "$status" -ne 0 ]
  grep -Fxq "merge_sha=$sha_b" "$marker"
  SESSION_F="$file_a" python3 -c 'import json,os; d=json.load(open(os.environ["SESSION_F"])); assert d["lifecycle"]["state"]=="active"'
  run env RIG_SESSION_FILE="$file_a" "$rig" session-name set --final --complete --post-merge-ack-sha="$sha_a" --json 'merge A only'
  [ "$status" -eq 3 ]
  [[ "$output" == *post_merge_reminder_pending* ]] || return 1
  [ -e "$marker" ]
  rm "$marker"
  run env RIG_SESSION_FILE="$file_a" "$rig" session obligation mark --kind post-merge --merge-sha "$sha_b" --json
  [ "$status" -eq 0 ]
  run env RIG_SESSION_FILE="$file_a" "$rig" session obligation clear --kind post-merge --merge-sha "$sha_b" --json
  [ "$status" -eq 0 ]
  [ ! -e "$marker" ]
  run env RIG_SESSION_FILE="$file_a" "$rig" session-name set --final --complete --post-merge-ack-sha="$sha_a" --json 'merge A only'
  [ "$status" -eq 3 ]
  [[ "$output" == *post_merge_not_acknowledged* ]] || return 1
  run env RIG_SESSION_FILE="$file_a" "$rig" session-name set --final --complete --post-merge-ack-sha="$sha_b" --json 'merge A and B'
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

@test "owned handoff updates retain the current shared snapshot after a shared-only write" {
  snapshot="$CASE_DIR/.rig/memory/CONTEXT_SNAPSHOT.md"
  printf '# Context Snapshot\n\n## Current state\n\n- Shared state version one.\n' > "$BATS_TEST_TMPDIR/shared.md"
  run "$rig" memory write-snapshot --file "$BATS_TEST_TMPDIR/shared.md" --shared-only --json
  [ "$status" -eq 0 ]
  printf '## Resuming from: task-a\n\n**Next action:** Continue task-a.\n' > "$BATS_TEST_TMPDIR/owned.md"
  run env RIG_SESSION_FILE="$file_a" "$rig" memory write-snapshot --file "$BATS_TEST_TMPDIR/owned.md" --owned-task task-a --json
  [ "$status" -eq 0 ]
  grep -Fq '## Current state' "$snapshot"
  grep -Fq 'Shared state version one.' "$snapshot"
  grep -Fq '## Resuming from: task-a' "$snapshot"

  printf '# Context Snapshot\n\n## Current state\n\n- Shared state version two.\n' > "$BATS_TEST_TMPDIR/shared.md"
  run "$rig" memory write-snapshot --file "$BATS_TEST_TMPDIR/shared.md" --shared-only --json
  [ "$status" -eq 0 ]
  candidate "$BATS_TEST_TMPDIR/stale-owned.md" feat/old task-a
  run env RIG_SESSION_FILE="$file_a" "$rig" memory write-snapshot --file "$BATS_TEST_TMPDIR/stale-owned.md" --owned-task task-a --json
  [ "$status" -eq 0 ]
  grep -Fq 'Shared state version two.' "$snapshot"
  if grep -Fq 'Shared state version one.' "$snapshot"; then return 1; fi
  if grep -Fq '**Branch:** feat/old' "$snapshot"; then return 1; fi
  grep -Fq '## Resuming from: task-a' "$snapshot"
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
  printf '# Old done copy\n' > "$CASE_DIR/.rig/tasks/done/task-a.md"
  run "$rig" memory write-snapshot --file "$BATS_TEST_TMPDIR/shared.md" --shared-only \
    --retire-task task-a --done-task-file "$CASE_DIR/.rig/tasks/done/task-a.md" --json
  [ "$status" -eq 3 ]
  [[ "$output" == *task_still_active* ]] || return 1
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

@test "restore-snapshot previews and restores only a missing handoff from a retired backup" {
  candidate "$BATS_TEST_TMPDIR/a.md" feat/a task-a
  candidate "$BATS_TEST_TMPDIR/b.md" feat/b task-b
  env RIG_SESSION_FILE="$file_a" "$rig" memory write-snapshot --file "$BATS_TEST_TMPDIR/a.md" --owned-task task-a --json >/dev/null
  env RIG_SESSION_FILE="$file_b" "$rig" memory write-snapshot --file "$BATS_TEST_TMPDIR/b.md" --owned-task task-b --json >/dev/null
  snapshot="$CASE_DIR/.rig/memory/CONTEXT_SNAPSHOT.md"
  mkdir -p "$CASE_DIR/.rig/tasks/done"
  printf '# Completed task A\n' > "$CASE_DIR/.rig/tasks/done/TASK_task-a.md"
  printf '# Current shared header\n' > "$BATS_TEST_TMPDIR/shared.md"
  run "$rig" memory write-snapshot --file "$BATS_TEST_TMPDIR/shared.md" --shared-only \
    --retire-task task-a --done-task-file "$CASE_DIR/.rig/tasks/done/TASK_task-a.md" --json
  [ "$status" -eq 0 ]
  backup=$(find "$CASE_DIR/.rig/memory/snapshot-backups" -type f -name 'retired-*.md' | head -1)
  [ -n "$backup" ]
  printf '# Current shared header\n\n## Resuming from: task-b\n\nCurrent B remains.\n' > "$BATS_TEST_TMPDIR/current-b.md"
  env RIG_SESSION_FILE="$file_b" "$rig" memory write-snapshot --file "$BATS_TEST_TMPDIR/current-b.md" \
    --owned-task task-b --json >/dev/null
  before=$(cksum "$snapshot")
  cp "$snapshot" "$BATS_TEST_TMPDIR/pre-restore.md"
  run "$rig" memory restore-snapshot --list --json
  [ "$status" -eq 0 ]
  [[ "$output" == *"$(basename "$backup")"* && "$output" == *'"valid":true'* ]] || return 1
  run "$rig" memory restore-snapshot --from "$backup" --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"restore_sections":["task-a"]'* && "$output" == *'"present_sections":["task-b"]'* ]] || return 1
  run "$rig" memory restore-snapshot --from "$backup" --section task-a --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"status":"preview"'* && "$output" == *'"restore_sections":["task-a"]'* ]] || return 1
  run "$rig" memory restore-snapshot --from "$backup" --section missing-task --confirm --json
  [ "$status" -eq 3 ]
  [[ "$output" == *section_missing* ]] || return 1
  [ "$before" = "$(cksum "$snapshot")" ]

  touch "$CASE_DIR/.rig/memory/.snapshot-write-in-progress"
  run "$rig" memory restore-snapshot --from "$backup" --confirm --json
  [ "$status" -eq 3 ]
  [[ "$output" == *legacy_lock_active* ]] || return 1
  [ "$before" = "$(cksum "$snapshot")" ]
  rm "$CASE_DIR/.rig/memory/.snapshot-write-in-progress"

  mkdir -p "$BATS_TEST_TMPDIR/restore-fault"
  cat > "$BATS_TEST_TMPDIR/restore-fault/sitecustomize.py" <<'PY'
import os
if os.environ.get("RIG_FAIL_RESTORE_SNAPSHOT") == "1":
    original = os.replace
    def fail_snapshot(src, dst, *args, **kwargs):
        if str(dst).endswith("/CONTEXT_SNAPSHOT.md"):
            raise OSError("injected snapshot replacement failure")
        return original(src, dst, *args, **kwargs)
    os.replace = fail_snapshot
PY
  run env PYTHONPATH="$BATS_TEST_TMPDIR/restore-fault" RIG_FAIL_RESTORE_SNAPSHOT=1 \
    "$rig" memory restore-snapshot --from "$backup" --confirm --json
  [ "$status" -eq 3 ]
  OUTPUT="$output" python3 -c 'import json,os; d=json.loads(os.environ["OUTPUT"]); assert d["reason"]=="snapshot_write_failed" and d["no_write"] is True'
  [ "$before" = "$(cksum "$snapshot")" ]
  [ ! -e "$CASE_DIR/.rig/memory/.snapshot-write-in-progress" ]
  prior=$(find "$CASE_DIR/.rig/memory/snapshot-backups" -type f -name 'restore-*.md' | head -1)
  [ -n "$prior" ]

  run "$rig" memory restore-snapshot --from "$backup" --confirm --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"status":"restored"'* && "$output" == *'"restore_sections":["task-a"]'* ]] || return 1
  grep -Fq '# Current shared header' "$snapshot"
  grep -Fq '## Resuming from: task-a' "$snapshot"
  grep -Fq '## Resuming from: task-b' "$snapshot"
  grep -Fq 'Current B remains.' "$snapshot"
  [ "$(grep -c '^## Resuming from:' "$snapshot")" -eq 2 ]
  CURRENT="$snapshot" PRIOR="$BATS_TEST_TMPDIR/pre-restore.md" python3 -c 'import os,pathlib; assert pathlib.Path(os.environ["CURRENT"]).read_bytes().startswith(pathlib.Path(os.environ["PRIOR"]).read_bytes())'
  [ ! -e "$CASE_DIR/.rig/memory/.snapshot-write-in-progress" ]
  prior=$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["pre_restore_backup"])')
  [ -f "$prior" ]
  if grep -Fq '## Resuming from: task-a' "$prior"; then return 1; fi
  grep -Fq '## Resuming from: task-b' "$prior"
  before=$(cksum "$snapshot")
  run "$rig" memory restore-snapshot --from "$backup" --confirm --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"status":"already_present"'* && "$output" == *'"no_write":true'* ]] || return 1
  [ "$before" = "$(cksum "$snapshot")" ]
}

@test "restore-snapshot preserves a later shared header when recovering an old legacy section" {
  snapshot="$CASE_DIR/.rig/memory/CONTEXT_SNAPSHOT.md"
  printf '# Original header\n\n## Resuming from: legacy-task (issue #5, blocked)\n\nKeep this handoff.\n' > "$snapshot"
  printf '# Updated header\n' > "$BATS_TEST_TMPDIR/shared.md"
  "$rig" memory write-snapshot --file "$BATS_TEST_TMPDIR/shared.md" --shared-only --json >/dev/null
  backup=$(find "$CASE_DIR/.rig/memory/snapshot-backups" -type f -name 'legacy-*.md' | head -1)
  mkdir -p "$CASE_DIR/.rig/tasks/done"
  printf '# Done\n' > "$CASE_DIR/.rig/tasks/done/TASK_legacy-task.md"
  printf '# Latest header\n' > "$BATS_TEST_TMPDIR/latest.md"
  "$rig" memory write-snapshot --file "$BATS_TEST_TMPDIR/latest.md" --shared-only \
    --retire-task legacy-task --done-task-file "$CASE_DIR/.rig/tasks/done/TASK_legacy-task.md" --json >/dev/null
  printf 'Extra header detail  \n\n## Resuming from: current-task\n\nKeep B with Markdown break.  \n\n\n' >> "$snapshot"
  cp "$snapshot" "$BATS_TEST_TMPDIR/legacy-pre-restore.md"
  run "$rig" memory restore-snapshot --from "$backup" --confirm --json
  [ "$status" -eq 0 ]
  CURRENT="$snapshot" PRIOR="$BATS_TEST_TMPDIR/legacy-pre-restore.md" python3 -c 'import os,pathlib; current=pathlib.Path(os.environ["CURRENT"]).read_bytes(); prior=pathlib.Path(os.environ["PRIOR"]).read_bytes(); shared, existing=prior.split(b"## Resuming from: current-task",1); assert current.startswith(shared); assert b"## Resuming from: current-task"+existing in current'
  grep -Fq '# Latest header' "$snapshot"
  grep -Fq '## Resuming from: legacy-task (issue #5, blocked)' "$snapshot"
  grep -Fq '## Resuming from: current-task' "$snapshot"
  grep -Fq 'Keep this handoff.' "$snapshot"
}

@test "restore-snapshot refuses a tampered or symlinked backup without changing the view" {
  candidate "$BATS_TEST_TMPDIR/a.md" feat/a task-a
  env RIG_SESSION_FILE="$file_a" "$rig" memory write-snapshot --file "$BATS_TEST_TMPDIR/a.md" --owned-task task-a --json >/dev/null
  snapshot="$CASE_DIR/.rig/memory/CONTEXT_SNAPSHOT.md"
  mkdir -p "$CASE_DIR/.rig/tasks/done"
  printf '# Done\n' > "$CASE_DIR/.rig/tasks/done/TASK_task-a.md"
  printf '# Current\n' > "$BATS_TEST_TMPDIR/shared.md"
  "$rig" memory write-snapshot --file "$BATS_TEST_TMPDIR/shared.md" --shared-only \
    --retire-task task-a --done-task-file "$CASE_DIR/.rig/tasks/done/TASK_task-a.md" --json >/dev/null
  backup=$(find "$CASE_DIR/.rig/memory/snapshot-backups" -type f -name 'retired-*.md' | head -1)
  before=$(cksum "$snapshot")
  printf 'tampered\n' >> "$backup"
  run "$rig" memory restore-snapshot --list --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"valid":false,"reason":"hash_mismatch"'* ]] || return 1
  run "$rig" memory restore-snapshot --from "$backup" --confirm --json
  [ "$status" -eq 3 ]
  [[ "$output" == *backup_hash_mismatch* ]] || return 1
  [ "$before" = "$(cksum "$snapshot")" ]
  mv "$backup" "$BATS_TEST_TMPDIR/tampered-backup.md"
  ln -s "$BATS_TEST_TMPDIR/tampered-backup.md" "$backup"
  run "$rig" memory restore-snapshot --from "$backup" --confirm --json
  [ "$status" -eq 3 ]
  [[ "$output" == *invalid_snapshot_path* ]] || return 1
  [ "$before" = "$(cksum "$snapshot")" ]
  mv "$CASE_DIR/.rig/memory/snapshot-backups" "$BATS_TEST_TMPDIR/outside-backups"
  ln -s "$BATS_TEST_TMPDIR/outside-backups" "$CASE_DIR/.rig/memory/snapshot-backups"
  run "$rig" memory restore-snapshot --list --json
  [ "$status" -eq 3 ]
  [[ "$output" == *invalid_backup_path* ]] || return 1
  [ "$before" = "$(cksum "$snapshot")" ]
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
  mkdir -p "$external/tasks/done"
  printf '# Done\n' > "$external/tasks/done/TASK_task-a.md"
  printf '# Stealth header\n' > "$BATS_TEST_TMPDIR/shared.md"
  run "$rig" memory write-snapshot --file "$BATS_TEST_TMPDIR/shared.md" --shared-only \
    --retire-task task-a --done-task-file "$external/tasks/done/TASK_task-a.md" --json
  [ "$status" -eq 0 ]
  backup=$(find "$external/memory/snapshot-backups" -type f -name 'retired-*.md' | head -1)
  run "$rig" memory restore-snapshot --from "$(basename "$backup")" --confirm --json
  [ "$status" -eq 0 ]
  [ "$(grep -c '^## Resuming from:' "$external/memory/CONTEXT_SNAPSHOT.md")" -eq 2 ]
  grep -Fq '# Stealth header' "$external/memory/CONTEXT_SNAPSHOT.md"
  [ -f "$CASE_DIR/dirty.txt" ]
  [ ! -e "$CASE_DIR/.rig" ]
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
  run env WRAP_SNAPSHOT_MODE=final REPO="$CASE_DIR" RIG_DIR="$CASE_DIR/.rig" SNAP_LOCK_TOKEN="$token" bash "$BATS_TEST_TMPDIR/wrap-snapshot.sh"
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
  run env WRAP_SNAPSHOT_MODE=final RIG_SESSION_FILE="$file_a" RIG_SESSION_ANCHOR="$original_anchor" \
    REPO="$CASE_DIR" RIG_DIR="$CASE_DIR/.rig" SNAP_LOCK_TOKEN="$token" \
    bash "$BATS_TEST_TMPDIR/wrap-continuation.sh"
  [ "$status" -eq 0 ]
  snapshot="$CASE_DIR/.rig/memory/CONTEXT_SNAPSHOT.md"
  grep -Fq "task=task-a owner=$continuation_anchor" "$snapshot"
  [ ! -e "$draft" ]
}

@test "checkpoint snapshot preserves exact record and obligations across repeated owned handoffs" {
  local anchor_a anchor_b token draft snapshot before_record before_marker
  local before_record_b before_post_merge marker_sha resume
  anchor_a=$(printf '%s' "$a" | python3 -c 'import json,sys; print(json.load(sys.stdin)["anchor"])')
  anchor_b=$(printf '%s' "$b" | python3 -c 'import json,sys; print(json.load(sys.stdin)["anchor"])')
  run env RIG_SESSION_FILE="$file_a" RIG_SESSION_ANCHOR="$anchor_a" \
    "$rig" session obligation mark --kind wrap --json
  [ "$status" -eq 0 ]
  run env RIG_SESSION_FILE="$file_b" RIG_SESSION_ANCHOR="$anchor_b" \
    "$rig" session obligation mark --kind wrap --json
  [ "$status" -eq 0 ]
  marker_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  printf 'merge_sha=%s\nmerged_at=2026-11-16T10:00:00-08:00\n' "$marker_sha" > \
    "$CASE_DIR/.rig/memory/.post-merge-pending"
  run env RIG_SESSION_FILE="$file_b" RIG_SESSION_ANCHOR="$anchor_b" \
    "$rig" session obligation mark --kind post-merge --merge-sha "$marker_sha" --json
  [ "$status" -eq 0 ]
  before_record=$(shasum -a 256 "$file_a")
  before_record_b=$(shasum -a 256 "$file_b")
  before_marker=$(shasum -a 256 "$CASE_DIR/.rig/memory/.wrap-needed")
  before_post_merge=$(shasum -a 256 "$CASE_DIR/.rig/memory/.post-merge-pending")
  snapshot="$CASE_DIR/.rig/memory/CONTEXT_SNAPSHOT.md"
  snapshot_command_block wrap > "$BATS_TEST_TMPDIR/checkpoint-snapshot.sh"

  token=$($rig memory workflow-lock acquire --owner-anchor "$anchor_b" --json | \
    python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')
  draft="$CASE_DIR/.rig/memory/.snapshot-draft-${token}.md"
  candidate "$draft" feat/other task-b
  run env WRAP_SNAPSHOT_MODE=checkpoint CHECKPOINT_FILE="$file_b" CHECKPOINT_ANCHOR="$anchor_b" \
    RIG_SESSION_FILE="$file_b" RIG_SESSION_ANCHOR="$anchor_b" \
    REPO="$CASE_DIR" RIG_DIR="$CASE_DIR/.rig" SNAP_LOCK_TOKEN="$token" \
    bash "$BATS_TEST_TMPDIR/checkpoint-snapshot.sh"
  [ "$status" -eq 0 ]
  run "$rig" memory workflow-lock release --token "$token" --json
  [ "$status" -eq 0 ]
  [ "$(shasum -a 256 "$file_b")" = "$before_record_b" ]
  [ "$(shasum -a 256 "$CASE_DIR/.rig/memory/.wrap-needed")" = "$before_marker" ]
  [ "$(shasum -a 256 "$CASE_DIR/.rig/memory/.post-merge-pending")" = "$before_post_merge" ]

  for branch in feat/checkpoint-one feat/checkpoint-two; do
    token=$($rig memory workflow-lock acquire --owner-anchor "$anchor_a" --json | \
      python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')
    draft="$CASE_DIR/.rig/memory/.snapshot-draft-${token}.md"
    candidate "$draft" "$branch" task-a
    run env WRAP_SNAPSHOT_MODE=checkpoint CHECKPOINT_FILE="$file_a" CHECKPOINT_ANCHOR="$anchor_a" \
      RIG_SESSION_FILE="$file_a" RIG_SESSION_ANCHOR="$anchor_a" \
      REPO="$CASE_DIR" RIG_DIR="$CASE_DIR/.rig" SNAP_LOCK_TOKEN="$token" \
      bash "$BATS_TEST_TMPDIR/checkpoint-snapshot.sh"
    [ "$status" -eq 0 ]
    run "$rig" memory workflow-lock release --token "$token" --json
    [ "$status" -eq 0 ]
    grep -Fq "task=task-b owner=$anchor_b" "$snapshot"
    grep -Fq "task=task-a owner=$anchor_a" "$snapshot"
    [ "$(shasum -a 256 "$file_a")" = "$before_record" ]
    [ "$(shasum -a 256 "$CASE_DIR/.rig/memory/.wrap-needed")" = "$before_marker" ]
    [ "$(shasum -a 256 "$CASE_DIR/.rig/memory/.post-merge-pending")" = "$before_post_merge" ]
  done
  grep -Fq 'feat/checkpoint-two' "$snapshot"

  token=$($rig memory workflow-lock acquire --owner-anchor "$anchor_a" --json | \
    python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')
  draft="$CASE_DIR/.rig/memory/.snapshot-draft-${token}.md"
  printf '# Shared-only candidate\n' > "$draft"
  run env WRAP_SNAPSHOT_MODE=checkpoint CHECKPOINT_ANCHOR="$anchor_a" CHECKPOINT_FILE="$file_b" \
    RIG_SESSION_FILE="$file_b" RIG_SESSION_ANCHOR="$anchor_b" \
    REPO="$CASE_DIR" RIG_DIR="$CASE_DIR/.rig" SNAP_LOCK_TOKEN="$token" \
    bash "$BATS_TEST_TMPDIR/checkpoint-snapshot.sh"
  [ "$status" -ne 0 ]
  [ -f "$draft" ]
  [ ! -e "$CASE_DIR/.rig/memory/.memory-workflow-in-progress" ]
  grep -Fq 'feat/checkpoint-two' "$snapshot"

  token=$($rig memory workflow-lock acquire --owner-anchor "$anchor_a" --json | \
    python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')
  draft="$CASE_DIR/.rig/memory/.snapshot-draft-${token}.md"
  candidate "$draft" feat/missing-mode task-a
  run env -u WRAP_SNAPSHOT_MODE CHECKPOINT_ANCHOR="$anchor_a" CHECKPOINT_FILE="$file_a" \
    RIG_SESSION_FILE="$file_a" RIG_SESSION_ANCHOR="$anchor_a" \
    REPO="$CASE_DIR" RIG_DIR="$CASE_DIR/.rig" SNAP_LOCK_TOKEN="$token" \
    bash "$BATS_TEST_TMPDIR/checkpoint-snapshot.sh"
  [ "$status" -ne 0 ]
  [ -f "$draft" ]
  [ ! -e "$CASE_DIR/.rig/memory/.memory-workflow-in-progress" ]
  grep -Fq 'feat/checkpoint-two' "$snapshot"

  token=$($rig memory workflow-lock acquire --owner-anchor "$anchor_a" --json | \
    python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')
  draft="$CASE_DIR/.rig/memory/.snapshot-draft-${token}.md"
  candidate "$draft" feat/invalid-owner task-a
  run env WRAP_SNAPSHOT_MODE=checkpoint CHECKPOINT_ANCHOR="$anchor_a" CHECKPOINT_FILE="$file_b" \
    RIG_SESSION_FILE="$file_b" RIG_SESSION_ANCHOR="$anchor_b" \
    REPO="$CASE_DIR" RIG_DIR="$CASE_DIR/.rig" SNAP_LOCK_TOKEN="$token" \
    bash "$BATS_TEST_TMPDIR/checkpoint-snapshot.sh"
  [ "$status" -ne 0 ]
  [ -f "$draft" ]
  [ ! -e "$CASE_DIR/.rig/memory/.memory-workflow-in-progress" ]
  grep -Fq 'feat/checkpoint-two' "$snapshot"

  token=$($rig memory workflow-lock acquire --owner-anchor "$anchor_a" --json | \
    python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')
  draft="$CASE_DIR/.rig/memory/.snapshot-draft-${token}.md"
  printf '# Missing identity candidate\n' > "$draft"
  run env WRAP_SNAPSHOT_MODE=checkpoint RIG_SESSION_FILE="$file_a" RIG_SESSION_ANCHOR="$anchor_a" \
    REPO="$CASE_DIR" RIG_DIR="$CASE_DIR/.rig" SNAP_LOCK_TOKEN="$token" \
    bash "$BATS_TEST_TMPDIR/checkpoint-snapshot.sh"
  [ "$status" -ne 0 ]
  [ -f "$draft" ]
  [ ! -e "$CASE_DIR/.rig/memory/.memory-workflow-in-progress" ]
  grep -Fq 'feat/checkpoint-two' "$snapshot"

  token=$($rig memory workflow-lock acquire --owner-anchor "$anchor_a" --json | \
    python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')
  draft="$CASE_DIR/.rig/memory/.snapshot-draft-${token}.md"
  candidate "$draft" feat/checkpoint-two task-a
  run env WRAP_SNAPSHOT_MODE=final CHECKPOINT_ANCHOR=ambient-wrong CHECKPOINT_FILE=/ambient/wrong \
    RIG_SESSION_FILE="$file_a" RIG_SESSION_ANCHOR="$anchor_a" \
    REPO="$CASE_DIR" RIG_DIR="$CASE_DIR/.rig" SNAP_LOCK_TOKEN="$token" \
    bash "$BATS_TEST_TMPDIR/checkpoint-snapshot.sh"
  [ "$status" -eq 0 ]
  run "$rig" memory workflow-lock release --token "$token" --json
  [ "$status" -eq 0 ]

  resume=$(env RIG_SESSION_FILE="$file_b" RIG_SESSION_ANCHOR="$anchor_b" \
    "$rig" session bind --agent codex --native-session-id thread-b --source resume)
  [ "$(printf '%s' "$resume" | python3 -c 'import json,sys; print(json.load(sys.stdin)["anchor"])')" = "$anchor_b" ]

  run env RIG_SESSION_FILE="$file_a" RIG_SESSION_ANCHOR="$anchor_a" \
    "$rig" session obligation clear --kind wrap --json
  [ "$status" -eq 0 ]
  run env RIG_SESSION_FILE="$file_a" RIG_SESSION_ANCHOR="$anchor_a" \
    "$rig" session-name set --final --complete 'Checkpointed work'
  [ "$status" -eq 0 ]
  local done_records=("$CASE_DIR/.rig/memory/sessions/done/"*"$anchor_a"*.json)
  [ -f "${done_records[0]}" ]
  grep -Fxq "anchor=$anchor_b" "$CASE_DIR/.rig/memory/.wrap-needed"
  grep -Fxq "anchor=$anchor_b" "$CASE_DIR/.rig/memory/.post-merge-pending"
  run env RIG_SESSION_FILE="$file_b" RIG_SESSION_ANCHOR="$anchor_b" \
    "$rig" session obligation clear --kind wrap --json
  [ "$status" -eq 0 ]
  run env RIG_SESSION_FILE="$file_b" RIG_SESSION_ANCHOR="$anchor_b" \
    "$rig" session obligation clear --kind post-merge --merge-sha "$marker_sha" --json
  [ "$status" -eq 0 ]
  run env RIG_SESSION_FILE="$file_b" RIG_SESSION_ANCHOR="$anchor_b" \
    "$rig" session-name set --final --complete --post-merge-ack-sha="$marker_sha" 'Codex checkpointed work'
  [ "$status" -eq 0 ]
  local done_codex=("$CASE_DIR/.rig/memory/sessions/done/"*"$anchor_b"*.json)
  [ -f "${done_codex[0]}" ]
  grep -Fq "task=task-b owner=$anchor_b" "$snapshot"
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
  : > "$CASE_DIR/.rig/memory/.wrap-needed"
  mkdir -p "$CASE_DIR/.claude/hooks"
  cp "$BATS_TEST_DIRNAME/../templates/project/.claude/hooks/stop.sh" "$CASE_DIR/.claude/hooks/stop.sh"
  run bash -c 'cd "$1" && printf "%s" "{\"source\":\"logout\"}" | RIG_SESSION_LOG="$2" bash .claude/hooks/stop.sh' \
    _ "$CASE_DIR" "$BATS_TEST_TMPDIR/session.log"
  [ "$status" -eq 0 ]
  [ "$before" = "$(cksum "$snapshot")" ]
  grep -Fq '## Resuming from: task-a' "$snapshot"
  grep -Fq '## Resuming from: task-b' "$snapshot"
  grep -Eq '^unscoped_legacy=[0-9a-f]{32}$' "$CASE_DIR/.rig/memory/.wrap-needed"
}

@test "native SessionEnd attributes an unexpanded stub only to its exact session" {
  local anchor_a anchor_b marker
  anchor_a=$(printf '%s' "$a" | python3 -c 'import json,sys; print(json.load(sys.stdin)["anchor"])')
  anchor_b=$(printf '%s' "$b" | python3 -c 'import json,sys; print(json.load(sys.stdin)["anchor"])')
  printf '# Current snapshot\n' > "$CASE_DIR/.rig/memory/CONTEXT_SNAPSHOT.md"
  printf '# Progress\n\n---\n\n## 2026-11-10 — fix: A [abc123] <!-- sid:%s -->\n_Auto-logged by post-commit hook. Expand this entry during wrap-up._\n\n---\n' \
    "$anchor_a" > "$CASE_DIR/.rig/memory/PROGRESS.md"
  mkdir -p "$CASE_DIR/.claude/hooks"
  cp "$BATS_TEST_DIRNAME/../templates/project/.claude/hooks/stop.sh" "$CASE_DIR/.claude/hooks/stop.sh"
  run env RIG_AGENT=codex RIG_SESSION_FILE="$file_b" RIG_SESSION_LOG="$BATS_TEST_TMPDIR/b.log" \
    bash -c 'cd "$1" && printf "%s" "$2" | bash .claude/hooks/stop.sh' _ "$CASE_DIR" \
    '{"source":"logout","session_id":"thread-b"}'
  [ "$status" -eq 0 ]
  [ ! -e "$CASE_DIR/.rig/memory/.wrap-needed" ]
  SESSION_F="$file_b" python3 -c 'import json,os; d=json.load(open(os.environ["SESSION_F"])); assert d["flags"]["wrap_needed"] is False and d["lifecycle"]["state"]=="inactive"'

  run env RIG_AGENT=claude RIG_SESSION_FILE="$file_a" RIG_SESSION_LOG="$BATS_TEST_TMPDIR/a.log" \
    bash -c 'cd "$1" && printf "%s" "$2" | bash .claude/hooks/stop.sh' _ "$CASE_DIR" \
    '{"source":"logout","session_id":"thread-a"}'
  [ "$status" -eq 0 ]
  marker="$CASE_DIR/.rig/memory/.wrap-needed"
  grep -Fq "anchor=$anchor_a" "$marker"
  if grep -Fq "anchor=$anchor_b" "$marker"; then return 1; fi
  SESSION_F="$file_a" python3 -c 'import json,os; d=json.load(open(os.environ["SESSION_F"])); assert d["flags"]["wrap_needed"] is True and d["lifecycle"]["state"]=="ended_no_wrap"'
}

@test "native SessionEnd keeps an untagged commit as a project reminder without claiming it" {
  local anchor_a anchor_b marker observed first_generation third file_third
  anchor_a=$(printf '%s' "$a" | python3 -c 'import json,sys; print(json.load(sys.stdin)["anchor"])')
  anchor_b=$(printf '%s' "$b" | python3 -c 'import json,sys; print(json.load(sys.stdin)["anchor"])')
  printf '# Current snapshot\n' > "$CASE_DIR/.rig/memory/CONTEXT_SNAPSHOT.md"
  printf '# Progress\n\n---\n\n## 2026-11-10 — fix: untagged [abc123]\n_Auto-logged by post-commit hook. Expand this entry during wrap-up._\n\n---\n' \
    > "$CASE_DIR/.rig/memory/PROGRESS.md"
  marker="$CASE_DIR/.rig/memory/.wrap-needed"
  printf 'anchor=%s\n' "$anchor_a" > "$marker"
  observed=$(python3 -c 'import hashlib,pathlib,sys; p=pathlib.Path(sys.argv[1]); s=p.stat() if p.exists() else None; print(hashlib.sha256(p.read_bytes()).hexdigest()+":"+str(s.st_mtime_ns)+":"+str(s.st_ino) if s else "missing")' "$marker")
  mkdir -p "$CASE_DIR/.claude/hooks"
  cp "$BATS_TEST_DIRNAME/../templates/project/.claude/hooks/stop.sh" "$CASE_DIR/.claude/hooks/stop.sh"
  run env RIG_AGENT=codex RIG_SESSION_FILE="$file_b" RIG_SESSION_LOG="$BATS_TEST_TMPDIR/b.log" \
    bash -c 'cd "$1" && printf "%s" "$2" | bash .claude/hooks/stop.sh' _ "$CASE_DIR" \
    '{"source":"logout","session_id":"thread-b"}'
  [ "$status" -eq 0 ]
  grep -Eq '^unscoped_progress=[0-9a-f]{32}$' "$marker"
  grep -Fq "anchor=$anchor_a" "$marker"
  if grep -Fq "anchor=$anchor_b" "$marker"; then return 1; fi
  SESSION_F="$file_b" python3 -c 'import json,os; d=json.load(open(os.environ["SESSION_F"])); assert d["flags"]["wrap_needed"] is False and d["lifecycle"]["state"]=="inactive"'
  first_generation=$(grep '^unscoped_progress=' "$marker")
  third=$("$rig" session bind --agent codex --native-session-id thread-c --source startup)
  file_third=$(printf '%s' "$third" | python3 -c 'import json,sys; print(json.load(sys.stdin)["session_file"])')
  run env RIG_AGENT=codex RIG_SESSION_FILE="$file_third" RIG_SESSION_LOG="$BATS_TEST_TMPDIR/c.log" \
    bash -c 'cd "$1" && printf "%s" "$2" | bash .claude/hooks/stop.sh' _ "$CASE_DIR" \
    '{"source":"logout","session_id":"thread-c"}'
  [ "$status" -eq 0 ]
  [ "$first_generation" != "$(grep '^unscoped_progress=' "$marker")" ]
  run env RIG_SESSION_FILE="$file_a" "$rig" session obligation clear --kind wrap \
    --adopt-legacy-if-marker-token "$observed" --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"legacy_preserved": true'* ]] || return 1
  grep -Eq '^unscoped_progress=[0-9a-f]{32}$' "$marker"
  if grep -Fq "anchor=$anchor_a" "$marker"; then return 1; fi
}

@test "native SessionEnd reads a tagged UTF-8 stub under a C locale" {
  local anchor_b marker
  anchor_b=$(printf '%s' "$b" | python3 -c 'import json,sys; print(json.load(sys.stdin)["anchor"])')
  printf '# Current snapshot\n' > "$CASE_DIR/.rig/memory/CONTEXT_SNAPSHOT.md"
  printf '# Progress — café\n\n---\n\n## 2026-11-10 — fix: C locale [abc123] <!-- sid:%s -->\n_Auto-logged by post-commit hook. Expand this entry during wrap-up._\n\n---\n' \
    "$anchor_b" > "$CASE_DIR/.rig/memory/PROGRESS.md"
  mkdir -p "$CASE_DIR/.claude/hooks"
  cp "$BATS_TEST_DIRNAME/../templates/project/.claude/hooks/stop.sh" "$CASE_DIR/.claude/hooks/stop.sh"
  run env LC_ALL=C PYTHONUTF8=0 RIG_AGENT=codex RIG_SESSION_FILE="$file_b" RIG_SESSION_LOG="$BATS_TEST_TMPDIR/b.log" \
    bash -c 'cd "$1" && printf "%s" "$2" | bash .claude/hooks/stop.sh' _ "$CASE_DIR" \
    '{"source":"logout","session_id":"thread-b"}'
  [ "$status" -eq 0 ]
  marker="$CASE_DIR/.rig/memory/.wrap-needed"
  grep -Fq "anchor=$anchor_b" "$marker"
  SESSION_F="$file_b" python3 -c 'import json,os; d=json.load(open(os.environ["SESSION_F"])); assert d["flags"]["wrap_needed"] is True and d["lifecycle"]["state"]=="ended_no_wrap"'
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
