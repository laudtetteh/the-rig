#!/usr/bin/env bats

setup() {
  export CASE_DIR="$BATS_TEST_TMPDIR/project"
  mkdir -p "$CASE_DIR/bin" "$CASE_DIR/.rig/memory/sessions/done"
  cp "$BATS_TEST_DIRNAME/../templates/project/bin/rig" "$CASE_DIR/bin/rig"
  cp "$BATS_TEST_DIRNAME/../templates/project/bin/rig-session-resolve.py" "$CASE_DIR/bin/rig-session-resolve.py"
  chmod +x "$CASE_DIR/bin/rig"
  git -C "$CASE_DIR" init -q
  git -C "$CASE_DIR" checkout -q -b feat/obligations
  unset RIG_SESSION_FILE RIG_SESSION_ANCHOR RIG_SESSION_PID CODEX_THREAD_ID CLAUDE_CODE_SESSION_ID
}

bind() {
  "$CASE_DIR/bin/rig" session bind --agent claude --native-session-id "$1" --source startup
}

field() {
  printf '%s' "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$2"
}

marker_token() {
  python3 -c 'import hashlib,pathlib,sys; p=pathlib.Path(sys.argv[1]); s=p.stat() if p.exists() else None; print(hashlib.sha256(p.read_bytes()).hexdigest()+":"+str(s.st_mtime_ns)+":"+str(s.st_ino) if s else "missing")' "$1"
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

@test "guarded wrap clear preserves a newer unscoped reminder while clearing its own anchor" {
  local result file anchor marker observed
  result=$(bind guarded-wrap); file=$(field "$result" session_file); anchor=$(field "$result" anchor)
  run env RIG_SESSION_FILE="$file" "$CASE_DIR/bin/rig" session obligation mark --kind wrap --json
  [ "$status" -eq 0 ]
  marker="$CASE_DIR/.rig/memory/.wrap-needed"
  printf 'unscoped_progress=before\n' >> "$marker"
  observed=$(marker_token "$marker")
  python3 -c 'import pathlib,sys; p=pathlib.Path(sys.argv[1]); p.write_text(p.read_text().replace("unscoped_progress=before", "unscoped_progress=after"))' "$marker"
  run env RIG_SESSION_FILE="$file" "$CASE_DIR/bin/rig" session obligation clear --kind wrap --adopt-legacy-if-marker-token "$observed" --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"legacy_preserved": true'* ]] || return 1
  grep -Fxq 'unscoped_progress=after' "$marker"
  if grep -Fq "anchor=$anchor" "$marker"; then return 1; fi
  SESSION_F="$file" python3 -c 'import json,os; assert json.load(open(os.environ["SESSION_F"]))["flags"]["wrap_needed"] is False'
}

@test "guarded wrap clear adopts a reviewed reminder when it has not changed" {
  local result file marker observed
  result=$(bind reviewed-wrap); file=$(field "$result" session_file)
  marker="$CASE_DIR/.rig/memory/.wrap-needed"
  printf 'unscoped_progress=before\n' > "$marker"
  observed=$(marker_token "$marker")
  run env RIG_SESSION_FILE="$file" "$CASE_DIR/bin/rig" session obligation clear --kind wrap --adopt-legacy-if-marker-token "$observed" --json
  [ "$status" -eq 0 ]
  [ ! -e "$marker" ]
}

@test "guarded wrap clear keeps an unchanged reminder while its progress stub is unexpanded" {
  local result file marker observed
  result=$(bind pending-progress); file=$(field "$result" session_file)
  marker="$CASE_DIR/.rig/memory/.wrap-needed"
  printf 'unscoped_progress=before\n' > "$marker"
  printf '## 2026-11-10 — pending [abc123]\n_Auto-logged by post-commit hook. Expand this entry during wrap-up._\n' \
    > "$CASE_DIR/.rig/memory/PROGRESS.md"
  observed=$(marker_token "$marker")
  run env RIG_SESSION_FILE="$file" "$CASE_DIR/bin/rig" session obligation clear --kind wrap --adopt-legacy-if-marker-token "$observed" --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"legacy_preserved": true'* ]] || return 1
  grep -Fxq 'unscoped_progress=before' "$marker"
}

@test "guarded wrap clear preserves an empty legacy marker when a new stub appears" {
  local result file marker observed
  result=$(bind empty-legacy); file=$(field "$result" session_file)
  marker="$CASE_DIR/.rig/memory/.wrap-needed"
  : > "$marker"
  observed=$(marker_token "$marker")
  printf '## 2026-11-10 — pending [abc123]\n_Auto-logged by post-commit hook. Expand this entry during wrap-up._\n' \
    > "$CASE_DIR/.rig/memory/PROGRESS.md"
  run env RIG_SESSION_FILE="$file" "$CASE_DIR/bin/rig" session obligation clear --kind wrap --adopt-legacy-if-marker-token "$observed" --json
  [ "$status" -eq 0 ]
  [ -e "$marker" ]
}

@test "guarded wrap clear preserves a legacy marker created after a missing baseline" {
  local result file marker observed
  result=$(bind missing-legacy); file=$(field "$result" session_file)
  marker="$CASE_DIR/.rig/memory/.wrap-needed"
  observed=$(marker_token "$marker")
  : > "$marker"
  printf '## 2026-11-10 — pending [abc123]\n_Auto-logged by post-commit hook. Expand this entry during wrap-up._\n' \
    > "$CASE_DIR/.rig/memory/PROGRESS.md"
  run env RIG_SESSION_FILE="$file" "$CASE_DIR/bin/rig" session obligation clear --kind wrap --adopt-legacy-if-marker-token "$observed" --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"legacy_preserved": true'* ]] || return 1
  grep -Eq '^unscoped_progress=[0-9a-f]{32}$' "$marker"
}

@test "guarded wrap clear notices an old hook touching an existing scoped marker" {
  local result file marker observed
  result=$(bind touched-legacy); file=$(field "$result" session_file)
  run env RIG_SESSION_FILE="$file" "$CASE_DIR/bin/rig" session obligation mark --kind wrap --json
  [ "$status" -eq 0 ]
  marker="$CASE_DIR/.rig/memory/.wrap-needed"
  observed=$(marker_token "$marker")
  MARKER_F="$marker" python3 -c 'import os; p=os.environ["MARKER_F"]; s=os.stat(p); os.utime(p,ns=(s.st_atime_ns,s.st_mtime_ns+1000000000))'
  run env RIG_SESSION_FILE="$file" "$CASE_DIR/bin/rig" session obligation clear --kind wrap --adopt-legacy-if-marker-token "$observed" --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"legacy_preserved": true'* ]] || return 1
  grep -Eq '^unscoped_legacy=[0-9a-f]{32}$' "$marker"
}

@test "guarded wrap clear does not invent an unscoped reminder for another scoped session" {
  local one two file_one file_two anchor_two marker observed
  one=$(bind scoped-one); two=$(bind scoped-two)
  file_one=$(field "$one" session_file); file_two=$(field "$two" session_file)
  anchor_two=$(field "$two" anchor)
  run env RIG_SESSION_FILE="$file_one" "$CASE_DIR/bin/rig" session obligation mark --kind wrap --json
  [ "$status" -eq 0 ]
  marker="$CASE_DIR/.rig/memory/.wrap-needed"
  observed=$(marker_token "$marker")
  run env RIG_SESSION_FILE="$file_two" "$CASE_DIR/bin/rig" session obligation mark --kind wrap --json
  [ "$status" -eq 0 ]
  run env RIG_SESSION_FILE="$file_one" "$CASE_DIR/bin/rig" session obligation clear --kind wrap --adopt-legacy-if-marker-token "$observed" --json
  [ "$status" -eq 0 ]
  grep -Fxq "anchor=$anchor_two" "$marker"
  if grep -Eq '^unscoped_' "$marker"; then return 1; fi
}

@test "guarded wrap clear does not claim another session's tagged progress stub" {
  local one two file_one file_two anchor_two marker observed
  one=$(bind tagged-one); two=$(bind tagged-two)
  file_one=$(field "$one" session_file); file_two=$(field "$two" session_file)
  anchor_two=$(field "$two" anchor)
  run env RIG_SESSION_FILE="$file_one" "$CASE_DIR/bin/rig" session obligation mark --kind wrap --json
  [ "$status" -eq 0 ]
  marker="$CASE_DIR/.rig/memory/.wrap-needed"
  observed=$(marker_token "$marker")
  printf '## 2026-11-10 — tagged [abc123] <!-- sid:%s -->\n_Auto-logged by post-commit hook. Expand this entry during wrap-up._\n' \
    "$anchor_two" > "$CASE_DIR/.rig/memory/PROGRESS.md"
  run env RIG_SESSION_FILE="$file_two" "$CASE_DIR/bin/rig" session obligation mark --kind wrap --json
  [ "$status" -eq 0 ]
  run env RIG_SESSION_FILE="$file_one" "$CASE_DIR/bin/rig" session obligation clear --kind wrap --adopt-legacy-if-marker-token "$observed" --json
  [ "$status" -eq 0 ]
  grep -Fxq "anchor=$anchor_two" "$marker"
  if grep -Eq '^unscoped_' "$marker"; then return 1; fi
}

@test "guarded wrap clear refuses a new tagged stub owned by the current session" {
  local result file anchor marker observed before
  result=$(bind tagged-current); file=$(field "$result" session_file); anchor=$(field "$result" anchor)
  run env RIG_SESSION_FILE="$file" "$CASE_DIR/bin/rig" session obligation mark --kind wrap --json
  [ "$status" -eq 0 ]
  marker="$CASE_DIR/.rig/memory/.wrap-needed"
  observed=$(marker_token "$marker")
  before=$(cksum "$file")
  printf '## 2026-11-10 — new commit [abc123] <!-- sid:%s -->\n_Auto-logged by post-commit hook. Expand this entry during wrap-up._\n' \
    "$anchor" > "$CASE_DIR/.rig/memory/PROGRESS.md"
  run env RIG_SESSION_FILE="$file" "$CASE_DIR/bin/rig" session obligation clear --kind wrap --adopt-legacy-if-marker-token "$observed" --json
  [ "$status" -eq 3 ]
  [[ "$output" == *owned_progress_unexpanded* ]] || return 1
  grep -Fxq "anchor=$anchor" "$marker"
  [ "$before" = "$(cksum "$file")" ]
}

@test "a scoped mark retains an older empty legacy reminder" {
  local result file anchor marker
  result=$(bind scoped-after-legacy); file=$(field "$result" session_file); anchor=$(field "$result" anchor)
  marker="$CASE_DIR/.rig/memory/.wrap-needed"
  : > "$marker"
  run env RIG_SESSION_FILE="$file" "$CASE_DIR/bin/rig" session obligation mark --kind wrap --json
  [ "$status" -eq 0 ]
  grep -Fxq "anchor=$anchor" "$marker"
  grep -Eq '^unscoped_legacy=[0-9a-f]{32}$' "$marker"
}

@test "an older empty reminder survives a later scoped mark and guarded clear" {
  local one two file_one file_two anchor_two marker observed
  one=$(bind mixed-one); two=$(bind mixed-two)
  file_one=$(field "$one" session_file); file_two=$(field "$two" session_file)
  anchor_two=$(field "$two" anchor)
  marker="$CASE_DIR/.rig/memory/.wrap-needed"
  observed=$(marker_token "$marker")
  : > "$marker"
  run env RIG_SESSION_FILE="$file_two" "$CASE_DIR/bin/rig" session obligation mark --kind wrap --json
  [ "$status" -eq 0 ]
  run env RIG_SESSION_FILE="$file_one" "$CASE_DIR/bin/rig" session obligation clear --kind wrap --adopt-legacy-if-marker-token "$observed" --json
  [ "$status" -eq 0 ]
  grep -Fxq "anchor=$anchor_two" "$marker"
  grep -Eq '^unscoped_legacy=[0-9a-f]{32}$' "$marker"
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

@test "post-merge acknowledgement refuses a marker owned by another session" {
  local one two file_one file_two anchor_one before
  one=$(bind merge-owner-one); two=$(bind merge-owner-two)
  file_one=$(field "$one" session_file); file_two=$(field "$two" session_file)
  anchor_one=$(field "$one" anchor)
  printf 'merge_sha=abc123\nmerged_at=2026-11-15T10:00:00-08:00\n' > "$CASE_DIR/.rig/memory/.post-merge-pending"
  run env RIG_SESSION_FILE="$file_one" "$CASE_DIR/bin/rig" session obligation mark --kind post-merge --merge-sha abc123 --json
  [ "$status" -eq 0 ]
  before=$(cksum "$file_two")
  run env RIG_SESSION_FILE="$file_two" "$CASE_DIR/bin/rig" session obligation clear --kind post-merge --merge-sha abc123 --json
  [ "$status" -eq 3 ]
  [[ "$output" == *marker_owner_mismatch* ]] || return 1
  grep -Fxq "anchor=$anchor_one" "$CASE_DIR/.rig/memory/.post-merge-pending"
  [ "$before" = "$(cksum "$file_two")" ]
  run env RIG_SESSION_FILE="$file_one" "$CASE_DIR/bin/rig" session obligation clear --kind post-merge --merge-sha abc123 --json
  [ "$status" -eq 0 ]
  [ ! -e "$CASE_DIR/.rig/memory/.post-merge-pending" ]
}

@test "failed exact hook mark leaves an unscoped reminder that a later exact session can acknowledge" {
  local one two file_one file_two anchor_one merge_sha marker
  one=$(bind ended-owner)
  file_one=$(field "$one" session_file); anchor_one=$(field "$one" anchor)
  SESSION_F="$file_one" python3 -c 'import json,os; p=os.environ["SESSION_F"]; d=json.load(open(p)); d["lifecycle"]["state"]="complete"; json.dump(d,open(p,"w"))'
  git -C "$CASE_DIR" config user.name Fixture
  git -C "$CASE_DIR" config user.email fixture@example.com
  git -C "$CASE_DIR" commit -q --allow-empty -m 'merge after ended owner'
  merge_sha=$(git -C "$CASE_DIR" rev-parse HEAD)
  marker="$CASE_DIR/.rig/memory/.post-merge-pending"
  run env RIG_SESSION_FILE="$file_one" RIG_SESSION_ANCHOR="$anchor_one" \
    bash -c 'cd "$1" && bash "$2" 0' _ "$CASE_DIR" "$BATS_TEST_DIRNAME/../templates/project/.husky/post-merge"
  [ "$status" -eq 0 ]
  grep -Fxq "merge_sha=$merge_sha" "$marker"
  grep -Fxq 'anchor=' "$marker"
  two=$(bind later-owner); file_two=$(field "$two" session_file)
  run env RIG_SESSION_FILE="$file_two" "$CASE_DIR/bin/rig" session obligation clear --kind post-merge --merge-sha "$merge_sha" --json
  [ "$status" -eq 0 ]
  [ ! -e "$marker" ]
  SESSION_F="$file_one" python3 -c 'import json,os; d=json.load(open(os.environ["SESSION_F"])); assert d["lifecycle"]["state"]=="complete" and d.get("obligations",{}).get("post_merge",{}).get("pending") is not True'
}

@test "post-merge hook cannot lose a newer unscoped marker while an older clear holds the obligation lock" {
  local result file anchor marker paused released attempted clear_pid hook_pid sha_b saw_attempt old_marker_intact
  result=$(bind race-owner); file=$(field "$result" session_file); anchor=$(field "$result" anchor)
  marker="$CASE_DIR/.rig/memory/.post-merge-pending"
  printf 'merge_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nanchor=%s\n' "$anchor" > "$marker"
  mkdir -p "$BATS_TEST_TMPDIR/race-python"
  cat > "$BATS_TEST_TMPDIR/race-python/sitecustomize.py" <<'PY'
import os
import pathlib
import time
import fcntl
original = os.replace
original_flock = fcntl.flock
def flock(fd, operation):
    attempt = os.environ.get("RIG_RACE_HOOK_LOCK_ATTEMPT")
    if attempt:
        pathlib.Path(attempt).write_text("attempted")
    return original_flock(fd, operation)
fcntl.flock = flock
def replace(src, dst):
    if str(dst) == os.environ.get("RIG_RACE_SESSION_FILE"):
        pathlib.Path(os.environ["RIG_RACE_PAUSED"]).write_text("paused")
        for _ in range(500):
            if pathlib.Path(os.environ["RIG_RACE_RELEASE"]).exists():
                break
            time.sleep(0.01)
    return original(src, dst)
os.replace = replace
PY
  paused="$BATS_TEST_TMPDIR/clear-paused"
  released="$BATS_TEST_TMPDIR/clear-release"
  attempted="$BATS_TEST_TMPDIR/hook-lock-attempted"
  (
    cd "$CASE_DIR"
    env PYTHONPATH="$BATS_TEST_TMPDIR/race-python" RIG_RACE_SESSION_FILE="$file" \
      RIG_RACE_PAUSED="$paused" RIG_RACE_RELEASE="$released" RIG_SESSION_FILE="$file" \
      bash bin/rig session obligation clear --kind post-merge \
        --merge-sha aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --json \
      > "$BATS_TEST_TMPDIR/clear.out" 2>&1
  ) &
  clear_pid=$!
  for _ in $(seq 1 500); do
    [ -f "$paused" ] && break
    sleep 0.01
  done
  [ -f "$paused" ]
  git -C "$CASE_DIR" config user.name Fixture
  git -C "$CASE_DIR" config user.email fixture@example.com
  git -C "$CASE_DIR" commit -q --allow-empty -m 'merge B'
  sha_b=$(git -C "$CASE_DIR" rev-parse HEAD)
  (
    cd "$CASE_DIR"
    env -u RIG_SESSION_FILE -u RIG_SESSION_ANCHOR -u RIG_COMMIT_POLICY \
      PYTHONPATH="$BATS_TEST_TMPDIR/race-python" RIG_RACE_HOOK_LOCK_ATTEMPT="$attempted" \
      bash "$BATS_TEST_DIRNAME/../templates/project/.husky/post-merge" 0 \
      > "$BATS_TEST_TMPDIR/hook.out" 2>&1
  ) &
  hook_pid=$!
  for _ in $(seq 1 500); do
    [ -f "$attempted" ] && break
    sleep 0.01
  done
  saw_attempt=false
  [ -f "$attempted" ] && saw_attempt=true
  old_marker_intact=false
  if grep -Fxq 'merge_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$marker"; then
    old_marker_intact=true
  fi
  touch "$released"
  wait "$clear_pid"
  wait "$hook_pid"
  [ "$saw_attempt" = true ]
  [ "$old_marker_intact" = true ]
  grep -Fxq "merge_sha=$sha_b" "$marker"
  SESSION_F="$file" python3 -c 'import json,os; d=json.load(open(os.environ["SESSION_F"])); o=d["obligations"]["post_merge"]; assert o["pending"] is False and o["merge_sha"]=="a"*40'
}

@test "post-merge hook marks and writes atomically so delayed mark cannot recreate an acknowledged reminder" {
  local result file anchor marker paused released hook_pid sha_b
  result=$(bind delayed-mark); file=$(field "$result" session_file); anchor=$(field "$result" anchor)
  marker="$CASE_DIR/.rig/memory/.post-merge-pending"
  git -C "$CASE_DIR" config user.name Fixture
  git -C "$CASE_DIR" config user.email fixture@example.com
  git -C "$CASE_DIR" commit -q --allow-empty -m 'merge B'
  sha_b=$(git -C "$CASE_DIR" rev-parse HEAD)
  mv "$CASE_DIR/bin/rig" "$CASE_DIR/bin/rig-real"
  cat > "$CASE_DIR/bin/rig" <<'SH'
#!/usr/bin/env bash
if [[ "$1" == session && "$2" == obligation && "$3" == mark ]]; then
  touch "$RIG_HOOK_PAUSED"
  for _ in $(seq 1 500); do
    [[ -f "$RIG_HOOK_RELEASE" ]] && break
    sleep 0.01
  done
fi
exec "$(dirname "$0")/rig-real" "$@"
SH
  chmod +x "$CASE_DIR/bin/rig"
  paused="$BATS_TEST_TMPDIR/mark-paused"
  released="$BATS_TEST_TMPDIR/mark-release"
  (
    cd "$CASE_DIR"
    env RIG_SESSION_FILE="$file" RIG_SESSION_ANCHOR="$anchor" \
      RIG_HOOK_PAUSED="$paused" RIG_HOOK_RELEASE="$released" \
      bash "$BATS_TEST_DIRNAME/../templates/project/.husky/post-merge" 0 \
      > "$BATS_TEST_TMPDIR/hook.out" 2>&1
  ) &
  hook_pid=$!
  for _ in $(seq 1 500); do
    [ -f "$paused" ] && break
    sleep 0.01
  done
  [ -f "$paused" ]
  run env RIG_SESSION_FILE="$file" "$CASE_DIR/bin/rig-real" session obligation clear --kind post-merge --merge-sha "$sha_b" --json
  [ "$status" -eq 3 ]
  [[ "$output" == *merge_mismatch* ]] || return 1
  touch "$released"
  wait "$hook_pid"
  grep -Fxq "merge_sha=$sha_b" "$marker"
  SESSION_F="$file" SHA_B="$sha_b" python3 -c 'import json,os; d=json.load(open(os.environ["SESSION_F"])); o=d["obligations"]["post_merge"]; assert o["pending"] is True and o["merge_sha"]==os.environ["SHA_B"]'
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
