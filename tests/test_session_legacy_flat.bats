#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CASE_ROOT="$BATS_TEST_TMPDIR/cases"
  mkdir -p "$CASE_ROOT"
  unset RIG_SESSION_FILE RIG_SESSION_ANCHOR RIG_SESSION_PID CODEX_THREAD_ID CLAUDE_CODE_SESSION_ID
}

make_project() {
  local layout="$1"
  CASE_PROJECT="$CASE_ROOT/$layout/project"
  mkdir -p "$CASE_PROJECT/bin"
  git -C "$CASE_PROJECT" init -q
  cp "$REPO_ROOT/templates/project/bin/rig" "$CASE_PROJECT/bin/rig"
  cp "$REPO_ROOT/templates/project/bin/rig-session-resolve.py" "$CASE_PROJECT/bin/rig-session-resolve.py"
  chmod +x "$CASE_PROJECT/bin/rig"
  if [ "$layout" = external ]; then
    CASE_RIG="$CASE_ROOT/$layout/rig"
    printf '%s\n' "$CASE_RIG" > "$CASE_PROJECT/.rigpath"
  else
    CASE_RIG="$CASE_PROJECT/.rig"
  fi
  mkdir -p "$CASE_RIG/memory/sessions"
  (cd "$CASE_PROJECT" && bin/rig session bind --agent codex --native-session-id current-probe --source startup >/dev/null)
  CASE_LEGACY="$CASE_RIG/memory/sessions/session-old-flat.json"
  PROJECT_ROOT="$CASE_PROJECT" LEGACY_FILE="$CASE_LEGACY" python3 - <<'PY'
import json, os
with open(os.environ["LEGACY_FILE"], "w") as handle:
    json.dump({"schema_version":1,"anchor":"old-flat-anchor","agent":"codex",
               "project_root":os.environ["PROJECT_ROOT"],"status":"complete",
               "binding":"historical hint","native_session_id_sha256_prefix":"opaque"},handle)
    handle.write("\n")
PY
}

@test "historical flat record has a read-only diagnosis and reversible quarantine in both layouts" {
  local layout before token current_file current_before
  for layout in repo external; do
    make_project "$layout"
    before="$(cksum "$CASE_LEGACY")"
    current_file="$(find "$CASE_RIG/memory/sessions" -maxdepth 1 -name 'session-*.json' ! -name 'session-old-flat.json' -print -quit)"
    current_before="$(cksum "$current_file")"

    run bash -c 'cd "$1" && bin/rig session resolve --agent codex --native-session-id current-probe --json' _ "$CASE_PROJECT"
    [ "$status" -eq 4 ]
    printf '%s' "$output" | jq -e '.reason == "malformed_record"' >/dev/null

    run bash -c 'cd "$1" && bin/rig session doctor --json' _ "$CASE_PROJECT"
    [ "$status" -eq 2 ]
    printf '%s' "$output" | jq -e \
      'any(.errors[]; .file == "session-old-flat.json" and .reason == "historical_flat_record" and .next_step == "bin/rig session legacy --file session-old-flat.json --json")' >/dev/null

    run bash -c 'cd "$1" && bin/rig session legacy --file session-old-flat.json --json' _ "$CASE_PROJECT"
    [ "$status" -eq 0 ]
    token="$(printf '%s' "$output" | jq -r '.confirmation_token')"
    [ "$(cksum "$CASE_LEGACY")" = "$before" ]
    [ ! -e "$CASE_RIG/memory/sessions/legacy-backups" ]

    run bash -c 'cd "$1" && bin/rig session legacy --file session-old-flat.json --confirm "$2" --json' _ "$CASE_PROJECT" "$token"
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e '.reason == "legacy_quarantined"' >/dev/null
    [ ! -e "$CASE_LEGACY" ]
    [ -f "$CASE_RIG/memory/sessions/legacy-backups/$token.json" ]
    [ -f "$CASE_RIG/memory/sessions/legacy-quarantine/$token.json" ]
    BACKUP_FILE="$CASE_RIG/memory/sessions/legacy-backups/$token.json" python3 - <<'PY'
import os, stat
mode=stat.S_IMODE(os.stat(os.environ["BACKUP_FILE"]).st_mode)
assert mode == 0o600
PY
    [ "$(cksum "$current_file")" = "$current_before" ]

    run bash -c 'cd "$1" && bin/rig session resolve --agent codex --native-session-id current-probe --json' _ "$CASE_PROJECT"
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e '.ok == true and .confidence == "exact"' >/dev/null

    run bash -c 'cd "$1" && bin/rig session legacy --file session-old-flat.json --restore "$2" --json' _ "$CASE_PROJECT" "$token"
    [ "$status" -eq 0 ]
    [ "$(cksum "$CASE_LEGACY")" = "$before" ]
    [ "$(cksum "$current_file")" = "$current_before" ]
    run bash -c 'cd "$1" && bin/rig session resolve --agent codex --native-session-id current-probe --json' _ "$CASE_PROJECT"
    [ "$status" -eq 4 ]
  done
}

@test "legacy repair refuses a malformed current record and leaves it unchanged" {
  make_project repo
  LEGACY_FILE="$CASE_LEGACY" python3 - <<'PY'
import json, os
path=os.environ["LEGACY_FILE"]
with open(path) as handle: data=json.load(handle)
data["native"]="bad current object"
with open(path,"w") as handle: json.dump(data,handle)
PY
  before="$(cksum "$CASE_LEGACY")"
  run bash -c 'cd "$1" && bin/rig session legacy --file session-old-flat.json --json' _ "$CASE_PROJECT"
  [ "$status" -eq 4 ]
  printf '%s' "$output" | jq -e '.reason == "not_historical_flat" and .no_write == true' >/dev/null
  [ "$(cksum "$CASE_LEGACY")" = "$before" ]
  run bash -c 'cd "$1" && bin/rig session resolve --agent codex --native-session-id current-probe --json' _ "$CASE_PROJECT"
  [ "$status" -eq 4 ]
}

@test "legacy repair refuses a flat record marked active" {
  make_project repo
  LEGACY_FILE="$CASE_LEGACY" python3 - <<'PY'
import json, os
path=os.environ["LEGACY_FILE"]
with open(path) as handle: data=json.load(handle)
data["status"]="active"
with open(path,"w") as handle: json.dump(data,handle)
PY
  before="$(cksum "$CASE_LEGACY")"
  run bash -c 'cd "$1" && bin/rig session legacy --file session-old-flat.json --json' _ "$CASE_PROJECT"
  [ "$status" -eq 4 ]
  printf '%s' "$output" | jq -e '.reason == "not_historical_flat" and .no_write == true' >/dev/null
  [ "$(cksum "$CASE_LEGACY")" = "$before" ]
}

@test "archival active flat record requires explicit acknowledgment before quarantine" {
  make_project repo
  LEGACY_FILE="$CASE_LEGACY" python3 - <<'PY'
import json, os
path=os.environ["LEGACY_FILE"]
with open(path) as handle: data=json.load(handle)
data.update({"status":"active","native_session_id_sha256_prefix":"0123456789abcdef",
             "started_at":"2020-01-01T00:00:00+00:00","privacy_note":"historical redacted record"})
with open(path,"w") as handle: json.dump(data,handle)
PY
  before="$(cksum "$CASE_LEGACY")"
  run bash -c 'cd "$1" && bin/rig session doctor --json' _ "$CASE_PROJECT"
  [ "$status" -eq 2 ]
  printf '%s' "$output" | jq -e \
    'any(.errors[]; .file == "session-old-flat.json" and .reason == "historical_flat_record" and .requires_acknowledge_active == true)' >/dev/null
  run bash -c 'cd "$1" && bin/rig session legacy --file session-old-flat.json --json' _ "$CASE_PROJECT"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.requires_acknowledge_active == true and .record_state == "active"' >/dev/null
  token="$(printf '%s' "$output" | jq -r '.confirmation_token')"
  run bash -c 'cd "$1" && bin/rig session legacy --file session-old-flat.json --confirm "$2" --json' _ "$CASE_PROJECT" "$token"
  [ "$status" -eq 3 ]
  printf '%s' "$output" | jq -e '.reason == "active_record_acknowledgment_required" and .no_write == true' >/dev/null
  [ "$(cksum "$CASE_LEGACY")" = "$before" ]
  [ ! -e "$CASE_RIG/memory/sessions/legacy-backups" ]
  run bash -c 'cd "$1" && bin/rig session legacy --file session-old-flat.json --confirm "$2" --acknowledge-active --json' _ "$CASE_PROJECT" "$token"
  [ "$status" -eq 0 ]
  run bash -c 'cd "$1" && bin/rig session resolve --agent codex --native-session-id current-probe --json' _ "$CASE_PROJECT"
  [ "$status" -eq 0 ]
  run bash -c 'cd "$1" && bin/rig session legacy --file session-old-flat.json --restore "$2" --json' _ "$CASE_PROJECT" "$token"
  [ "$status" -eq 0 ]
  [ "$(cksum "$CASE_LEGACY")" = "$before" ]
}

@test "boolean schema version is malformed and cannot be quarantined" {
  make_project repo
  LEGACY_FILE="$CASE_LEGACY" python3 - <<'PY'
import json, os
path=os.environ["LEGACY_FILE"]
with open(path) as handle: data=json.load(handle)
data["schema_version"]=True
with open(path,"w") as handle: json.dump(data,handle)
PY
  before="$(cksum "$CASE_LEGACY")"
  run bash -c 'cd "$1" && bin/rig session doctor --json' _ "$CASE_PROJECT"
  [ "$status" -eq 2 ]
  printf '%s' "$output" | jq -e 'any(.errors[]; .file == "session-old-flat.json" and .reason == "malformed_record")' >/dev/null
  run bash -c 'cd "$1" && bin/rig session legacy --file session-old-flat.json --json' _ "$CASE_PROJECT"
  [ "$status" -eq 4 ]
  printf '%s' "$output" | jq -e '.reason == "not_historical_flat" and .no_write == true' >/dev/null
  [ "$(cksum "$CASE_LEGACY")" = "$before" ]
  run bash -c 'cd "$1" && bin/rig session resolve --agent codex --native-session-id current-probe --json' _ "$CASE_PROJECT"
  [ "$status" -eq 4 ]
}

@test "symlinked memory ancestor cannot redirect quarantine outside Rig storage" {
  make_project repo
  outside="$CASE_ROOT/outside-memory"
  mv "$CASE_PROJECT/.rig/memory" "$outside"
  ln -s "$outside" "$CASE_PROJECT/.rig/memory"
  before="$(cksum "$outside/sessions/session-old-flat.json")"
  run bash -c 'cd "$1" && bin/rig session legacy --file session-old-flat.json --json' _ "$CASE_PROJECT"
  [ "$status" -eq 4 ]
  printf '%s' "$output" | jq -e '.reason == "invalid_session_path" and .no_write == true' >/dev/null
  run bash -c 'cd "$1" && bin/rig session legacy --file session-old-flat.json --confirm 00000000000000000000 --json' _ "$CASE_PROJECT"
  [ "$status" -eq 4 ]
  [ "$(cksum "$outside/sessions/session-old-flat.json")" = "$before" ]
  [ ! -e "$outside/sessions/legacy-backups" ]
}

@test "symlinked Rig root cannot redirect quarantine" {
  make_project repo
  outside="$CASE_ROOT/outside-rig"
  mv "$CASE_PROJECT/.rig" "$outside"
  ln -s "$outside" "$CASE_PROJECT/.rig"
  before="$(cksum "$outside/memory/sessions/session-old-flat.json")"
  run bash -c 'cd "$1" && bin/rig session legacy --file session-old-flat.json --json' _ "$CASE_PROJECT"
  [ "$status" -eq 4 ]
  printf '%s' "$output" | jq -e '.reason == "invalid_session_path" and .no_write == true' >/dev/null
  [ "$(cksum "$outside/memory/sessions/session-old-flat.json")" = "$before" ]
  [ ! -e "$outside/memory/sessions/legacy-backups" ]
}

@test "legacy restore refuses a changed backup without changing the quarantine" {
  make_project repo
  run bash -c 'cd "$1" && bin/rig session legacy --file session-old-flat.json --json' _ "$CASE_PROJECT"
  [ "$status" -eq 0 ]
  token="$(printf '%s' "$output" | jq -r '.confirmation_token')"
  run bash -c 'cd "$1" && bin/rig session legacy --file session-old-flat.json --confirm "$2" --json' _ "$CASE_PROJECT" "$token"
  [ "$status" -eq 0 ]
  printf 'tampered\n' > "$CASE_RIG/memory/sessions/legacy-backups/$token.json"
  before="$(cksum "$CASE_RIG/memory/sessions/legacy-quarantine/$token.json")"
  run bash -c 'cd "$1" && bin/rig session legacy --file session-old-flat.json --restore "$2" --json' _ "$CASE_PROJECT" "$token"
  [ "$status" -eq 4 ]
  printf '%s' "$output" | jq -e '.reason == "backup_mismatch" and .no_write == true' >/dev/null
  [ "$(cksum "$CASE_RIG/memory/sessions/legacy-quarantine/$token.json")" = "$before" ]
  [ ! -e "$CASE_LEGACY" ]
}

@test "quarantining a historical record does not hide another malformed current record" {
  make_project repo
  printf '{"schema_version":1,"native":"bad current object"}\n' > "$CASE_RIG/memory/sessions/session-current-bad.json"
  run bash -c 'cd "$1" && bin/rig session legacy --file session-old-flat.json --json' _ "$CASE_PROJECT"
  [ "$status" -eq 0 ]
  token="$(printf '%s' "$output" | jq -r '.confirmation_token')"
  run bash -c 'cd "$1" && bin/rig session legacy --file session-old-flat.json --confirm "$2" --json' _ "$CASE_PROJECT" "$token"
  [ "$status" -eq 0 ]
  run bash -c 'cd "$1" && bin/rig session resolve --agent codex --native-session-id current-probe --json' _ "$CASE_PROJECT"
  [ "$status" -eq 4 ]
  printf '%s' "$output" | jq -e '.reason == "malformed_record"' >/dev/null
}

@test "legacy command can quarantine and restore an old record in done" {
  make_project repo
  mkdir -p "$CASE_RIG/memory/sessions/done"
  mv "$CASE_LEGACY" "$CASE_RIG/memory/sessions/done/session-old-flat.json"
  run bash -c 'cd "$1" && bin/rig session doctor --json' _ "$CASE_PROJECT"
  [ "$status" -eq 2 ]
  printf '%s' "$output" | jq -e \
    'any(.errors[]; .file == "done/session-old-flat.json" and .reason == "historical_flat_record")' >/dev/null
  run bash -c 'cd "$1" && bin/rig session legacy --file done/session-old-flat.json --json' _ "$CASE_PROJECT"
  [ "$status" -eq 0 ]
  token="$(printf '%s' "$output" | jq -r '.confirmation_token')"
  run bash -c 'cd "$1" && bin/rig session legacy --file done/session-old-flat.json --confirm "$2" --json' _ "$CASE_PROJECT" "$token"
  [ "$status" -eq 0 ]
  run bash -c 'cd "$1" && bin/rig session legacy --file done/session-old-flat.json --restore "$2" --json' _ "$CASE_PROJECT" "$token"
  [ "$status" -eq 0 ]
  [ -f "$CASE_RIG/memory/sessions/done/session-old-flat.json" ]
}
