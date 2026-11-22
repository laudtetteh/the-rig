#!/usr/bin/env bats

setup() {
  export CASE_DIR="$BATS_TEST_TMPDIR/project"
  mkdir -p "$CASE_DIR/bin" "$CASE_DIR/.rig/memory/sessions/done"
  cp "$BATS_TEST_DIRNAME/../templates/project/bin/rig" "$CASE_DIR/bin/rig"
  cp "$BATS_TEST_DIRNAME/../templates/project/bin/rig-session-resolve.py" "$CASE_DIR/bin/rig-session-resolve.py"
  cp "$BATS_TEST_DIRNAME/../templates/project/bin/rig-session-index.py" "$CASE_DIR/bin/rig-session-index.py"
  cp "$BATS_TEST_DIRNAME/../templates/project/bin/rig-session-archive.py" "$CASE_DIR/bin/rig-session-archive.py"
  cp "$BATS_TEST_DIRNAME/../templates/project/bin/rig_project_roots.py" "$CASE_DIR/bin/rig_project_roots.py"
  chmod +x "$CASE_DIR/bin/rig"
  git -C "$CASE_DIR" init -q
  git -C "$CASE_DIR" checkout -q -b feat/fixture
  unset RIG_SESSION_FILE RIG_SESSION_ANCHOR RIG_SESSION_PID CODEX_THREAD_ID CLAUDE_CODE_SESSION_ID
}

bind_old() {
  local result file
  result=$("$CASE_DIR/bin/rig" session bind --agent "$1" --native-session-id "$2" --source startup --json)
  file=$(printf '%s' "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin)["session_file"])')
  RECORD_FILE="$file" python3 - <<'PY'
import json,os
path=os.environ['RECORD_FILE']
with open(path) as stream: data=json.load(stream)
data['created_at']='2026-01-01T00:00:00Z'
data['updated_at']='2026-01-01T00:00:00Z'
data['lifecycle']['last_event_at']='2026-01-01T00:00:00Z'
data['runtime']['pid']=99999999
with open(path,'w') as stream: json.dump(data,stream)
PY
  printf '%s\n' "$result"
}

field() { printf '%s' "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$2"; }

@test "both providers report stale evidence and archive and restore exact bytes" {
  for provider in claude codex; do
    result=$(bind_old "$provider" "native-$provider")
    anchor=$(field "$result" anchor)
    file=$(field "$result" session_file)
    before=$(shasum -a 256 "$file" | awk '{print $1}')
    run env HOME="$BATS_TEST_TMPDIR/empty-home" "$CASE_DIR/bin/rig" session index --project current --stale --json
    [ "$status" -eq 0 ]
    printf '%s' "$output" | python3 -c 'import json,sys; rows=json.load(sys.stdin)["sessions"]; assert any(r.get("stale_evidence",{}).get("archive_eligible") for r in rows)'
    preview=$("$CASE_DIR/bin/rig" session archive --anchor "$anchor" --acknowledge-active --json)
    token=$(field "$preview" confirmation_token)
    run "$CASE_DIR/bin/rig" session archive --anchor "$anchor" --acknowledge-active --confirm "$token" --json
    [ "$status" -eq 0 ]; [[ "$output" == *'"doctor_ok": true'* ]] || return 1
    [ ! -e "$file" ]
    restore=$("$CASE_DIR/bin/rig" session archive --restore "$token" --json)
    restore_token=$(field "$restore" confirmation_token)
    run "$CASE_DIR/bin/rig" session archive --restore "$token" --confirm "$restore_token" --json
    [ "$status" -eq 0 ]; [[ "$output" == *'"doctor_ok": true'* ]] || return 1
    [ "$(shasum -a 256 "$file" | awk '{print $1}')" = "$before" ]
  done
}

@test "changed record and active acknowledgement refuse without moving bytes" {
  result=$(bind_old codex race-native)
  anchor=$(field "$result" anchor); file=$(field "$result" session_file)
  preview=$("$CASE_DIR/bin/rig" session archive --anchor "$anchor" --json)
  [[ "$preview" == *active_record_acknowledgment_required* ]] || return 1
  preview=$("$CASE_DIR/bin/rig" session archive --anchor "$anchor" --acknowledge-active --json) || { printf '%s\n' "$preview"; return 1; }
  token=$(field "$preview" confirmation_token)
  printf '\n' >> "$file"
  run "$CASE_DIR/bin/rig" session archive --anchor "$anchor" --acknowledge-active --confirm "$token" --json
  [ "$status" -eq 3 ]; [[ "$output" == *record_changed* ]] || return 1
  [ -f "$file" ]
}

@test "pending obligation and checkpoint handoff refuse archival" {
  result=$(bind_old claude pending-native)
  anchor=$(field "$result" anchor); file=$(field "$result" session_file)
  printf 'anchor=%s\n' "$anchor" > "$CASE_DIR/.rig/memory/.wrap-needed"
  preview=$("$CASE_DIR/bin/rig" session archive --anchor "$anchor" --acknowledge-active --json)
  token=$(field "$preview" confirmation_token)
  run "$CASE_DIR/bin/rig" session archive --anchor "$anchor" --acknowledge-active --confirm "$token" --json
  [ "$status" -eq 3 ]; [[ "$output" == *pending_or_ambiguous_obligation* ]] || return 1
  rm "$CASE_DIR/.rig/memory/.wrap-needed"
  printf '<!-- rig:handoff-start task=x owner=%s -->\n' "$anchor" > "$CASE_DIR/.rig/memory/CONTEXT_SNAPSHOT.md"
  preview=$("$CASE_DIR/bin/rig" session archive --anchor "$anchor" --acknowledge-active --json)
  token=$(field "$preview" confirmation_token)
  run "$CASE_DIR/bin/rig" session archive --anchor "$anchor" --acknowledge-active --confirm "$token" --json
  [ "$status" -eq 3 ]; [[ "$output" == *handoff_owner* ]] || return 1
  [ -f "$file" ]
}

@test "symlinked record refuses without reading target" {
  result=$(bind_old codex symlink-native)
  file=$(field "$result" session_file); anchor=$(field "$result" anchor)
  mv "$file" "$BATS_TEST_TMPDIR/original"
  ln -s "$BATS_TEST_TMPDIR/original" "$file"
  run "$CASE_DIR/bin/rig" session archive --anchor "$anchor" --acknowledge-active --json
  [ "$status" -eq 3 ]; [[ "$output" == *unsafe_record_path* ]] || return 1
  [ -f "$BATS_TEST_TMPDIR/original" ]
}

@test "stealth storage archives in pointed Rig directory" {
  external="$BATS_TEST_TMPDIR/external-rig"
  mkdir -p "$external/memory/sessions"
  external=$(cd "$external" && pwd -P)
  mv "$CASE_DIR/.rig" "$BATS_TEST_TMPDIR/inrepo-rig"
  printf '%s\n' "$external" > "$CASE_DIR/.rigpath"
  result=$(bind_old codex stealth-native)
  anchor=$(field "$result" anchor); file=$(field "$result" session_file)
  [[ "$file" == "$external"/* ]] || return 1
  preview=$("$CASE_DIR/bin/rig" session archive --anchor "$anchor" --acknowledge-active --json)
  token=$(field "$preview" confirmation_token)
  run "$CASE_DIR/bin/rig" session archive --anchor "$anchor" --acknowledge-active --confirm "$token" --json
  [ "$status" -eq 0 ]; [ -f "$external/memory/sessions/archive/$token/manifest.json" ]
}

@test "live PID and young age are independent refusal reasons" {
  result=$(bind_old codex live-native)
  anchor=$(field "$result" anchor); file=$(field "$result" session_file)
  RECORD_FILE="$file" LIVE_PID="$$" python3 - <<'PY'
import json,os
p=os.environ['RECORD_FILE']; d=json.load(open(p)); d['runtime']['pid']=int(os.environ['LIVE_PID']); json.dump(d,open(p,'w'))
PY
  run "$CASE_DIR/bin/rig" session archive --anchor "$anchor" --acknowledge-active --json
  [ "$status" -eq 0 ]; [[ "$output" == *live_pid* ]] || return 1
  RECORD_FILE="$file" python3 - <<'PY'
import json,os
import datetime
p=os.environ['RECORD_FILE']; d=json.load(open(p)); d['runtime']['pid']=99999999; d['updated_at']=datetime.datetime.now(datetime.timezone.utc).isoformat(); json.dump(d,open(p,'w'))
PY
  run "$CASE_DIR/bin/rig" session archive --anchor "$anchor" --acknowledge-active --json
  [ "$status" -eq 0 ]; [[ "$output" == *too_recent* ]] || return 1
}

@test "marker and snapshot mutations invalidate preview tokens" {
  result=$(bind_old codex marker-race)
  anchor=$(field "$result" anchor)
  preview=$("$CASE_DIR/bin/rig" session archive --anchor "$anchor" --acknowledge-active --json)
  token=$(field "$preview" confirmation_token)
  printf 'anchor=other-session\n' > "$CASE_DIR/.rig/memory/.wrap-needed"
  run "$CASE_DIR/bin/rig" session archive --anchor "$anchor" --acknowledge-active --confirm "$token" --json
  [ "$status" -eq 3 ]; [[ "$output" == *record_changed* ]] || return 1
  preview=$("$CASE_DIR/bin/rig" session archive --anchor "$anchor" --acknowledge-active --json)
  token=$(field "$preview" confirmation_token)
  printf 'Unrelated shared text\n' > "$CASE_DIR/.rig/memory/CONTEXT_SNAPSHOT.md"
  run "$CASE_DIR/bin/rig" session archive --anchor "$anchor" --acknowledge-active --confirm "$token" --json
  [ "$status" -eq 3 ]; [[ "$output" == *record_changed* ]] || return 1
}

@test "restore refuses native rebound and a tampered backup" {
  result=$(bind_old codex rebound-native)
  anchor=$(field "$result" anchor)
  preview=$("$CASE_DIR/bin/rig" session archive --anchor "$anchor" --acknowledge-active --json)
  token=$(field "$preview" confirmation_token)
  "$CASE_DIR/bin/rig" session archive --anchor "$anchor" --acknowledge-active --confirm "$token" --json >/dev/null
  backup="$CASE_DIR/.rig/memory/sessions/archive/$token/records/session-$anchor.json"
  printf 'x' >> "$backup"
  run "$CASE_DIR/bin/rig" session archive --restore "$token" --json
  [ "$status" -eq 3 ]; [[ "$output" == *backup_mismatch* ]] || return 1
  truncate -s -1 "$backup"
  "$CASE_DIR/bin/rig" session bind --agent codex --native-session-id rebound-native --source resume --json >/dev/null
  run "$CASE_DIR/bin/rig" session archive --restore "$token" --json
  [ "$status" -eq 3 ]; [[ "$output" == *native_rebound* ]] || return 1
}

@test "lineage component requires all anchors and index suggests the complete set" {
  result=$(bind_old claude lineage-native)
  parent=$(field "$result" anchor); parent_file=$(field "$result" session_file)
  child=$(PARENT_FILE="$parent_file" python3 - <<'PY'
import json,os,uuid
p=os.environ['PARENT_FILE']; d=json.load(open(p)); d['lifecycle']['state']='inactive'; json.dump(d,open(p,'w'))
child=dict(d); child['anchor']=str(uuid.uuid4()); child['lifecycle']=dict(d['lifecycle']); child['lifecycle']['state']='active'
child['lineage']={'kind':'continuation','parent_anchor':d['anchor'],'parent_native_session_id':d['native']['session_id']}
with open(os.path.join(os.path.dirname(p),'session-'+child['anchor']+'.json'),'w') as stream: json.dump(child,stream)
print(child['anchor'])
PY
  )
  run "$CASE_DIR/bin/rig" session archive --anchor "$parent" --json
  [ "$status" -eq 3 ]; [[ "$output" == *lineage_component_incomplete* ]] || return 1
  run env HOME="$BATS_TEST_TMPDIR/empty-home" "$CASE_DIR/bin/rig" session index --project current --stale --json
  [ "$status" -eq 0 ]; [[ "$output" == *"--anchor $parent --anchor $child"* || "$output" == *"--anchor $child --anchor $parent"* ]] || { printf '%s\n' "$output"; return 1; }
  preview=$("$CASE_DIR/bin/rig" session archive --anchor "$parent" --anchor "$child" --acknowledge-active --json)
  token=$(field "$preview" confirmation_token)
  run "$CASE_DIR/bin/rig" session archive --anchor "$parent" --anchor "$child" --acknowledge-active --confirm "$token" --json
  [ "$status" -eq 0 ]; [[ "$output" == *'"doctor_ok": true'* ]] || return 1
}

@test "ended record restores and resolver reports ended_record" {
  result=$(bind_old claude ended-native)
  anchor=$(field "$result" anchor); file=$(field "$result" session_file)
  RECORD_FILE="$file" python3 - <<'PY'
import json,os
p=os.environ['RECORD_FILE']; d=json.load(open(p)); d['lifecycle']['state']='inactive'; d['lifecycle']['last_event']='session_end'; json.dump(d,open(p,'w'))
PY
  preview=$("$CASE_DIR/bin/rig" session archive --anchor "$anchor" --json)
  [[ "$preview" == *'"end_observed": "session_end"'* ]] || return 1
  token=$(field "$preview" confirmation_token)
  run "$CASE_DIR/bin/rig" session archive --anchor "$anchor" --confirm "$token" --json
  [ "$status" -eq 0 ]
  restore=$("$CASE_DIR/bin/rig" session archive --restore "$token" --json)
  restore_token=$(field "$restore" confirmation_token)
  run "$CASE_DIR/bin/rig" session archive --restore "$token" --confirm "$restore_token" --json
  [ "$status" -eq 0 ]; [[ "$output" == *'"observed": "ended_record"'* && "$output" == *'"ok": true'* ]] || { printf '%s\n' "$output"; return 1; }
}

@test "unscoped marker and embedded obligation refuse archive" {
  result=$(bind_old codex uncertain-native)
  anchor=$(field "$result" anchor); file=$(field "$result" session_file)
  printf 'anchor=\n' > "$CASE_DIR/.rig/memory/.wrap-needed"
  run "$CASE_DIR/bin/rig" session archive --anchor "$anchor" --acknowledge-active --json
  [ "$status" -eq 0 ]; [[ "$output" == *pending_or_ambiguous_obligation* ]] || return 1
  rm "$CASE_DIR/.rig/memory/.wrap-needed"
  printf 'merge_sha=abc123\n' > "$CASE_DIR/.rig/memory/.post-merge-pending"
  run "$CASE_DIR/bin/rig" session archive --anchor "$anchor" --acknowledge-active --json
  [ "$status" -eq 0 ]; [[ "$output" == *pending_or_ambiguous_obligation* ]] || return 1
  rm "$CASE_DIR/.rig/memory/.post-merge-pending"
  RECORD_FILE="$file" python3 - <<'PY'
import json,os
p=os.environ['RECORD_FILE']; d=json.load(open(p)); d['flags']['wrap_needed']=False; d.setdefault('obligations',{})['wrap']={'pending':True}; json.dump(d,open(p,'w'))
PY
  run "$CASE_DIR/bin/rig" session archive --anchor "$anchor" --acknowledge-active --json
  [ "$status" -eq 0 ]; [[ "$output" == *pending_or_ambiguous_obligation* ]] || return 1
}

@test "pending archive recovery rolls back moved record and detects native rebound" {
  result=$(bind_old codex recovery-native)
  anchor=$(field "$result" anchor); file=$(field "$result" session_file)
  preview=$("$CASE_DIR/bin/rig" session archive --anchor "$anchor" --acknowledge-active --json)
  token=$(field "$preview" confirmation_token)
  "$CASE_DIR/bin/rig" session archive --anchor "$anchor" --acknowledge-active --confirm "$token" --json >/dev/null
  archive="$CASE_DIR/.rig/memory/sessions/archive"
  mv "$archive/$token" "$archive/.pending-$token"
  recovery=$("$CASE_DIR/bin/rig" session archive --recover "$token" --json)
  recovery_token=$(field "$recovery" confirmation_token)
  run "$CASE_DIR/bin/rig" session archive --recover "$token" --confirm "$recovery_token" --json
  [ "$status" -eq 0 ]; [ -f "$file" ]; [ ! -e "$archive/.pending-$token" ] || { printf '%s\n' "$output"; return 1; }
  preview=$("$CASE_DIR/bin/rig" session archive --anchor "$anchor" --acknowledge-active --json)
  token=$(field "$preview" confirmation_token)
  "$CASE_DIR/bin/rig" session archive --anchor "$anchor" --acknowledge-active --confirm "$token" --json >/dev/null
  mv "$archive/$token" "$archive/.pending-$token"
  "$CASE_DIR/bin/rig" session bind --agent codex --native-session-id recovery-native --source resume --json >/dev/null
  recovery=$("$CASE_DIR/bin/rig" session archive --recover "$token" --json)
  recovery_token=$(field "$recovery" confirmation_token)
  run "$CASE_DIR/bin/rig" session archive --recover "$token" --confirm "$recovery_token" --json
  [ "$status" -eq 3 ]; [[ "$output" == *native_rebound* ]] || return 1
}

@test "pending restore recovery removes only unchanged partial destinations" {
  result=$(bind_old codex restore-recovery)
  anchor=$(field "$result" anchor); file=$(field "$result" session_file)
  preview=$("$CASE_DIR/bin/rig" session archive --anchor "$anchor" --acknowledge-active --json)
  token=$(field "$preview" confirmation_token)
  "$CASE_DIR/bin/rig" session archive --anchor "$anchor" --acknowledge-active --confirm "$token" --json >/dev/null
  archive="$CASE_DIR/.rig/memory/sessions/archive"
  mkdir -m 700 "$archive/.pending-restore-$token"
  printf '{"archive_id":"%s"}\n' "$token" > "$archive/.pending-restore-$token/intent.json"
  cp "$archive/$token/records/session-$anchor.json" "$file"
  recovery=$("$CASE_DIR/bin/rig" session archive --recover "$token" --json)
  recovery_token=$(field "$recovery" confirmation_token)
  run "$CASE_DIR/bin/rig" session archive --recover "$token" --confirm "$recovery_token" --json
  [ "$status" -eq 0 ]; [ ! -e "$file" ]; [ ! -e "$archive/.pending-restore-$token" ] || { printf '%s\n' "$output"; return 1; }
}

@test "stale index routes historical flat record to legacy preview" {
  record="$CASE_DIR/.rig/memory/sessions/session-old-flat.json"
  PROJECT="$CASE_DIR" RECORD="$record" python3 - <<'PY'
import json,os
with open(os.environ['RECORD'],'w') as stream:
    json.dump({'schema_version':1,'anchor':'old-flat','agent':'claude','status':'inactive',
               'binding':'historical hint','project_root':os.environ['PROJECT'],'started_at':'2020-01-01T00:00:00Z'},stream)
PY
  run env HOME="$BATS_TEST_TMPDIR/empty-home" "$CASE_DIR/bin/rig" session index --project current --stale --json
  [ "$status" -eq 2 ]; [[ "$output" == *'session legacy --file session-old-flat.json --json'* ]] || return 1
}

@test "pending hard-link move recovers exact original without deleting it" {
  result=$(bind_old codex hardlink-native)
  anchor=$(field "$result" anchor); file=$(field "$result" session_file)
  preview=$("$CASE_DIR/bin/rig" session archive --anchor "$anchor" --acknowledge-active --json)
  token=$(field "$preview" confirmation_token)
  "$CASE_DIR/bin/rig" session archive --anchor "$anchor" --acknowledge-active --confirm "$token" --json >/dev/null
  archive="$CASE_DIR/.rig/memory/sessions/archive"
  mv "$archive/$token" "$archive/.pending-$token"
  ln "$archive/.pending-$token/moved/session-$anchor.json" "$file"
  recovery=$("$CASE_DIR/bin/rig" session archive --recover "$token" --json)
  recovery_token=$(field "$recovery" confirmation_token)
  run "$CASE_DIR/bin/rig" session archive --recover "$token" --confirm "$recovery_token" --json
  [ "$status" -eq 0 ]; [ -f "$file" ]; [ ! -e "$archive/.pending-$token" ]
}

@test "finished restore journal finalizes without removing live records" {
  result=$(bind_old codex finalized-native)
  anchor=$(field "$result" anchor); file=$(field "$result" session_file)
  preview=$("$CASE_DIR/bin/rig" session archive --anchor "$anchor" --acknowledge-active --json)
  token=$(field "$preview" confirmation_token)
  "$CASE_DIR/bin/rig" session archive --anchor "$anchor" --acknowledge-active --confirm "$token" --json >/dev/null
  restore=$("$CASE_DIR/bin/rig" session archive --restore "$token" --json)
  restore_token=$(field "$restore" confirmation_token)
  "$CASE_DIR/bin/rig" session archive --restore "$token" --confirm "$restore_token" --json >/dev/null
  archive="$CASE_DIR/.rig/memory/sessions/archive"
  mkdir -m 700 "$archive/.pending-restore-$token"
  printf '{"archive_id":"%s"}\n' "$token" > "$archive/.pending-restore-$token/intent.json"
  recovery=$("$CASE_DIR/bin/rig" session archive --recover "$token" --json)
  [[ "$recovery" == *finalize_restore* ]] || return 1
  recovery_token=$(field "$recovery" confirmation_token)
  run "$CASE_DIR/bin/rig" session archive --recover "$token" --confirm "$recovery_token" --json
  [ "$status" -eq 0 ]; [[ "$output" == *recovery_finalized* ]] || return 1
  [ -f "$file" ]
}

@test "staging directory without manifest recovers before any record move" {
  result=$(bind_old codex prestage-native)
  file=$(field "$result" session_file)
  archive="$CASE_DIR/.rig/memory/sessions/archive"
  mkdir -p "$archive"
  chmod 700 "$archive"
  mkdir -m 700 "$archive/.pending-0123456789abcdefabcd"
  recovery=$("$CASE_DIR/bin/rig" session archive --recover 0123456789abcdefabcd --json)
  recovery_token=$(field "$recovery" confirmation_token)
  run "$CASE_DIR/bin/rig" session archive --recover 0123456789abcdefabcd --confirm "$recovery_token" --json
  [ "$status" -eq 0 ]; [ -f "$file" ]; [ ! -e "$archive/.pending-0123456789abcdefabcd" ]
}
