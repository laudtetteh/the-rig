#!/usr/bin/env bats
# Handoff suggestion scope (#665): UserPromptSubmit measures only the exact
# session resolved for the prompt, reads the bind-schema record
# (lifecycle.state, created_at), and offers the suggestion once per session.
# Other sessions' records, including stale legacy ones, never trigger it.

setup() {
  unset CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID RIG_SESSION_FILE RIG_SESSION_ANCHOR RIG_SESSION_PID RIG_AGENT
  CASE_DIR="$BATS_TEST_TMPDIR/project"
  RIG_DIR="$CASE_DIR/.rig"
  HOOKS="$CASE_DIR/.claude/hooks"
  mkdir -p "$RIG_DIR/memory/sessions/done" "$RIG_DIR/rules" "$HOOKS" "$CASE_DIR/bin"
  cp "$BATS_TEST_DIRNAME/../templates/project/.claude/hooks/prompt-submit.sh" "$HOOKS/prompt-submit.sh"
  cp "$BATS_TEST_DIRNAME/../templates/project/bin/rig" "$CASE_DIR/bin/rig"
  cp "$BATS_TEST_DIRNAME/../templates/project/bin/rig-path.py" "$CASE_DIR/bin/rig-path.py"
  cp "$BATS_TEST_DIRNAME/../templates/project/bin/rig-session-resolve.py" "$CASE_DIR/bin/rig-session-resolve.py"
  chmod +x "$CASE_DIR/bin/rig"
  git -C "$CASE_DIR" init -q
  git -C "$CASE_DIR" config user.email test@example.com
  git -C "$CASE_DIR" config user.name Test
  git -C "$CASE_DIR" commit --allow-empty -q -m 'initial'
  printf '# Snapshot\n' > "$RIG_DIR/memory/CONTEXT_SNAPSHOT.md"
  touch "$RIG_DIR/memory/.permission-nudge-offered"
}

# Bind a Claude session record for a native ID.
bind_session() {
  run env RIG_SESSION_PID=665665 bash -c 'cd "$1" && bin/rig session bind --agent claude --native-session-id "$2" --source startup --json' _ "$CASE_DIR" "$1"
  [ "$status" -eq 0 ]
  BOUND_FILE=$(OUTPUT="$output" python3 -c 'import json,os; print(json.loads(os.environ["OUTPUT"])["session_file"])')
  BOUND_ANCHOR=$(OUTPUT="$output" python3 -c 'import json,os; print(json.loads(os.environ["OUTPUT"])["anchor"])')
}

# Move a session record's created_at back by the given number of hours.
backdate() {
  python3 - "$1" "$2" <<'PY'
import datetime, json, sys
path, hours = sys.argv[1], int(sys.argv[2])
doc = json.load(open(path))
doc["created_at"] = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=hours)).isoformat()
json.dump(doc, open(path, "w"))
PY
}

# Submit one Claude prompt for a native ID (empty means no session_id);
# sets CONTEXT to the injected additional context, or empty.
submit_prompt() {
  local payload
  payload=$(python3 -c 'import json,sys; d={"hook_event_name":"UserPromptSubmit","prompt":"hi"}; d.update({"session_id":sys.argv[1]} if sys.argv[1] else {}); print(json.dumps(d))' "$1")
  run env RIG_AGENT=claude RIG_HANDOFF_ELAPSED_SECONDS=3600 bash -c 'cd "$1" && printf "%s" "$2" | bash .claude/hooks/prompt-submit.sh' _ "$CASE_DIR" "$payload"
  [ "$status" -eq 0 ]
  CONTEXT=$(OUTPUT="$output" python3 -c '
import json, os
raw = os.environ["OUTPUT"].strip()
print(json.loads(raw).get("additionalContext", "") if raw else "")
')
}

@test "handoff: an exact session past the threshold is offered the suggestion once" {
  bind_session claude-old
  backdate "$BOUND_FILE" 3
  submit_prompt claude-old
  [[ "$CONTEXT" == *"Rig handoff suggestion"* ]] || return 1
  [[ "$CONTEXT" == *"/handoff-checklist"* ]] || return 1
  [ "$(sed -n '1p' "$RIG_DIR/memory/.handoff-suggested")" = "$BOUND_ANCHOR" ]
  submit_prompt claude-old
  [[ "$CONTEXT" != *"Rig handoff suggestion"* ]] || return 1
}

@test "handoff: a fresh exact session is not offered the suggestion" {
  bind_session claude-new
  submit_prompt claude-new
  [[ "$CONTEXT" != *"Rig handoff suggestion"* ]] || return 1
  [ ! -e "$RIG_DIR/memory/.handoff-suggested" ]
}

@test "handoff: a stale legacy record from another session never triggers it" {
  python3 -c 'import json,sys,datetime; json.dump({"status":"active","started_at":(datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(hours=9)).isoformat()},open(sys.argv[1],"w"))' "$RIG_DIR/memory/sessions/session-12345.json"
  bind_session claude-current
  submit_prompt claude-current
  [[ "$CONTEXT" != *"Rig handoff suggestion"* ]] || return 1
}

@test "handoff: another bound session's old record does not trigger it for this session" {
  bind_session claude-other
  backdate "$BOUND_FILE" 5
  bind_session claude-mine
  submit_prompt claude-mine
  [[ "$CONTEXT" != *"Rig handoff suggestion"* ]] || return 1
}

@test "handoff: a prompt without an exact session is never offered the suggestion" {
  bind_session claude-old
  backdate "$BOUND_FILE" 3
  submit_prompt ""
  [[ "$CONTEXT" != *"Rig handoff suggestion"* ]] || return 1
}

@test "handoff: a suggestion to one session does not suppress it for the next" {
  : > "$RIG_DIR/memory/.handoff-suggested"
  bind_session claude-first
  backdate "$BOUND_FILE" 3
  submit_prompt claude-first
  [[ "$CONTEXT" == *"Rig handoff suggestion"* ]] || return 1
  bind_session claude-second
  backdate "$BOUND_FILE" 3
  submit_prompt claude-second
  [[ "$CONTEXT" == *"Rig handoff suggestion"* ]] || return 1
}
