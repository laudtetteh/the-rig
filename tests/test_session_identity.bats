#!/usr/bin/env bats
# test_session_identity.bats
#
# Tests for the UUID-based session-identity system.
#
# PPID note: hooks use $PPID to scope /tmp sentinel files and session files.
# When we run `(cd "$REPO" && exec bash hook.sh)`, exec replaces the subshell
# process — so the hook's $PPID equals the test shell's $$. We write sentinel
# files using $$ so they match what the hook will look for via $PPID.
#
# RIG_DIR note: hooks derive RIG_DIR from .rigpath or fall back to $REPO/.rig.
# Tests use RIG_DIR inside REPO (no .rigpath) to avoid the .rigpath complexity.

setup() {
  TMPDIR=$(mktemp -d)
  REPO="$TMPDIR/repo"
  RIG_DIR="$REPO/.rig"
  mkdir -p "$REPO" "$RIG_DIR/memory/sessions" "$RIG_DIR/memory" "$RIG_DIR/tasks/active"
  git -C "$REPO" init -q
  git -C "$REPO" commit --allow-empty -m "initial" -q

  HOOK_DIR="$TMPDIR/hooks"
  mkdir -p "$HOOK_DIR"
  cp "$(pwd)/templates/project/.claude/hooks/session-start.sh" "$HOOK_DIR/session-start.sh"
  cp "$(pwd)/templates/project/.claude/hooks/stop.sh"          "$HOOK_DIR/stop.sh"
  cp "$(pwd)/templates/project/.claude/hooks/session-end.sh"   "$HOOK_DIR/session-end.sh"
  cp "$(pwd)/templates/project/.claude/hooks/pre-compact.sh"   "$HOOK_DIR/pre-compact.sh"
  chmod +x "$HOOK_DIR"/*.sh

  # Minimal CONTEXT_SNAPSHOT so startup case does not exit early
  cat > "$RIG_DIR/memory/CONTEXT_SNAPSHOT.md" <<'EOF'
# Context Snapshot
**Last updated:** 2026-06-20 — test session
**Branch:** main
EOF

  export RIG_SESSION_LOG="$TMPDIR/session.log"

  # Temp file for hook stdout capture. Hooks are called via run_hook_exec which
  # writes stdout here — we read it separately to avoid $() wrapping that would
  # add an extra subshell layer and break PPID alignment.
  RUN_OUTPUT_FILE="$TMPDIR/hook.out"

  # Session files use PPID inside hooks. When run_hook_exec calls
  # `(cd "$REPO" && exec bash hook.sh)` the subshell's PPID equals the test
  # shell's $$. We confirmed this empirically: session-$$.json is created.
  TEST_SESSION_FILE="$RIG_DIR/memory/sessions/session-$$.json"
  TEST_UUID_FILE="/tmp/.rig-session-$$.uuid"
}

teardown() {
  rm -rf "$TMPDIR"
  rm -f "/tmp/.rig-session-$$.uuid" 2>/dev/null || true
}

# Run a hook; stdout goes to $RUN_OUTPUT_FILE.
# Always call without $() wrapping — that would add an extra subshell layer
# and break PPID alignment (hook's $PPID would no longer equal test's $$).
#
# We write $input to a temp file instead of using <<< because bash 3.2 on macOS
# has a bug where here-strings + exec inside a function lose the stdin file
# descriptor before the exec'd process can read it.
run_hook_exec() {
  local hook="$1"
  # Avoid ${2:-{}} — bash 3.2 (macOS) has a bug where {} in a default value
  # leaks an extra } into the result, producing invalid JSON.
  local input; input="$2"
  [[ -z "$input" ]] && input="{}"
  local infile
  infile=$(mktemp)
  printf '%s' "$input" > "$infile"
  (cd "$REPO" && exec bash "$HOOK_DIR/$hook" < "$infile" > "$RUN_OUTPUT_FILE") 2>/dev/null
  rm -f "$infile"
}

# Convenience: read output captured by the last run_hook_exec call.
hook_output() {
  cat "$RUN_OUTPUT_FILE" 2>/dev/null || true
}

# ── session-start.sh ─────────────────────────────────────────────────────────

@test "session-start: startup creates session file with anchor UUID" {
  run_hook_exec "session-start.sh" '{"source":"startup"}'
  [ -f "$TEST_SESSION_FILE" ]
  ANCHOR=$(python3 -c "import json; print(json.load(open('$TEST_SESSION_FILE')).get('anchor',''))")
  [ -n "$ANCHOR" ]
  STATUS=$(python3 -c "import json; print(json.load(open('$TEST_SESSION_FILE')).get('status',''))")
  [ "$STATUS" = "active" ]
}

@test "session-start: startup emits additionalContext JSON" {
  run_hook_exec "session-start.sh" '{"source":"startup"}'
  hook_output | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert 'hookSpecificOutput' in d
assert 'additionalContext' in d['hookSpecificOutput']
"
}

@test "session-start: resume restores /tmp UUID from existing session file" {
  # Pre-create session file (simulates a session that lost its /tmp sentinel)
  python3 -c "
import json
with open('$TEST_SESSION_FILE', 'w') as f:
    json.dump({'anchor':'restoreme','pid':$$,'status':'active',
               'tentative_name':None,'final_name':None,
               'started_at':'2026-06-20T09:00:00','branch':'main'}, f)
"
  rm -f "$TEST_UUID_FILE"
  run_hook_exec "session-start.sh" '{"source":"resume"}'
  [ -f "$TEST_UUID_FILE" ]
  UUID=$(cat "$TEST_UUID_FILE")
  [ "$UUID" = "restoreme" ]
}

@test "session-start: compact reads anchor from checkpoint when no session file" {
  # Write a checkpoint with a known anchor (simulating prior session's pre-compact output)
  PRIOR_ANCHOR="comptest1"
  cat > "$RIG_DIR/memory/.compact-checkpoint-9999.md" <<EOF
## Compact checkpoint

**Branch:** main
**Last commit:** abc1234 — some commit
**Active task:** none
**Last progress entry:** none
**Session anchor:** $PRIOR_ANCHOR
**Session tentative name:** none
EOF

  # No session file for our $$
  rm -f "$TEST_SESSION_FILE"

  run_hook_exec "session-start.sh" '{"source":"compact"}'
  # Should emit context from the checkpoint
  hook_output | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert 'hookSpecificOutput' in d, 'no hookSpecificOutput'
assert 'additionalContext' in d['hookSpecificOutput'], 'no additionalContext'
"
}

@test "session-start: clear reuses existing session file" {
  python3 -c "
import json
with open('$TEST_SESSION_FILE', 'w') as f:
    json.dump({'anchor':'existuuid','pid':$$,'status':'active',
               'tentative_name':None,'final_name':None,
               'started_at':'2026-06-20T09:00:00','branch':'main'}, f)
"
  run_hook_exec "session-start.sh" '{"source":"clear"}'
  ANCHOR=$(python3 -c "import json; print(json.load(open('$TEST_SESSION_FILE')).get('anchor',''))")
  [ "$ANCHOR" = "existuuid" ]
}

@test "session-start: unknown source exits silently with no output" {
  OUTPUT=$(run_hook_exec "session-start.sh" '{"source":"unknown"}')
  [ -z "$OUTPUT" ]
}

# ── stop.sh ──────────────────────────────────────────────────────────────────

@test "stop: appends session-end marker with sid:UUID when UUID file present" {
  echo "abc12345" > "$TEST_UUID_FILE"
  printf '## 2026-06-20 — entry\n' > "$RIG_DIR/memory/PROGRESS.md"

  run_hook_exec "stop.sh" '{}'

  grep -q "<!-- session-end.*sid:abc12345 -->" "$RIG_DIR/memory/PROGRESS.md"
}

@test "stop: appends plain marker when UUID file absent (backward compat)" {
  rm -f "$TEST_UUID_FILE"
  printf '## 2026-06-20 — entry\n' > "$RIG_DIR/memory/PROGRESS.md"

  run_hook_exec "stop.sh" '{}'

  grep -q "<!-- session-end" "$RIG_DIR/memory/PROGRESS.md"
  ! grep -q "sid:" "$RIG_DIR/memory/PROGRESS.md"
}

@test "stop: idempotent — does not double-append marker" {
  echo "abc12345" > "$TEST_UUID_FILE"
  printf "\n<!-- session-end 2026-06-20 09:00 sid:abc12345 -->\n" \
    > "$RIG_DIR/memory/PROGRESS.md"

  run_hook_exec "stop.sh" '{}'

  COUNT=$(grep -c "<!-- session-end" "$RIG_DIR/memory/PROGRESS.md")
  [ "$COUNT" -eq 1 ]
}

# ── session-end.sh ───────────────────────────────────────────────────────────

@test "session-end: logout marks session file ended-no-wrap" {
  python3 -c "
import json
with open('$TEST_SESSION_FILE', 'w') as f:
    json.dump({'anchor':'abc12345','pid':$$,'status':'active',
               'tentative_name':None,'final_name':None,
               'started_at':'2026-06-20T09:00:00','branch':'main'}, f)
"
  # Need unexpanded stubs so .wrap-needed gets written (which drives checkpoint)
  echo "## stub <!-- Auto-logged by post-tool hook -->" > "$RIG_DIR/memory/PROGRESS.md"

  run_hook_exec "session-end.sh" '{"source":"logout"}'

  STATUS=$(python3 -c "import json; print(json.load(open('$TEST_SESSION_FILE')).get('status',''))")
  [ "$STATUS" = "ended-no-wrap" ]
}

@test "session-end: logout cleans /tmp UUID sentinel" {
  echo "abc12345" > "$TEST_UUID_FILE"
  echo "## stub <!-- Auto-logged by post-tool hook -->" > "$RIG_DIR/memory/PROGRESS.md"

  run_hook_exec "session-end.sh" '{"source":"logout"}'

  [ ! -f "$TEST_UUID_FILE" ]
}

@test "session-end: minimal checkpoint has Session anchor field (not Session name)" {
  echo "abc12345" > "$TEST_UUID_FILE"
  echo "## stub <!-- Auto-logged by post-tool hook -->" > "$RIG_DIR/memory/PROGRESS.md"

  run_hook_exec "session-end.sh" '{"source":"logout"}'

  grep -q "\*\*Session anchor:\*\*" "$RIG_DIR/memory/CONTEXT_SNAPSHOT.md"
  ! grep -q "\*\*Session name:\*\*" "$RIG_DIR/memory/CONTEXT_SNAPSHOT.md"
}

@test "session-end: clear does not set .wrap-needed" {
  echo "## stub <!-- Auto-logged by post-tool hook -->" > "$RIG_DIR/memory/PROGRESS.md"

  run_hook_exec "session-end.sh" '{"source":"clear"}'

  [ ! -f "$RIG_DIR/memory/.wrap-needed" ]
}

# ── pre-compact.sh ───────────────────────────────────────────────────────────

@test "pre-compact: writes Session anchor and tentative name from session file" {
  python3 -c "
import json
with open('$TEST_SESSION_FILE', 'w') as f:
    json.dump({'anchor':'compuuid','pid':$$,'status':'active',
               'tentative_name':'feat phase2 [tentative]','final_name':None,
               'started_at':'2026-06-20T09:00:00','branch':'main'}, f)
"
  run_hook_exec "pre-compact.sh" '{}'

  CKPT="$RIG_DIR/memory/.compact-checkpoint-$$.md"
  [ -f "$CKPT" ]
  grep -q "\*\*Session anchor:\*\* compuuid" "$CKPT"
  grep -q "\*\*Session tentative name:\*\* feat phase2" "$CKPT"
  ! grep -q "\*\*Session name:\*\*" "$CKPT"
}

@test "pre-compact: uses none for anchor when no session file exists" {
  rm -f "$TEST_SESSION_FILE"

  run_hook_exec "pre-compact.sh" '{}'

  CKPT="$RIG_DIR/memory/.compact-checkpoint-$$.md"
  [ -f "$CKPT" ]
  grep -q "\*\*Session anchor:\*\* none" "$CKPT"
}

@test "pre-compact: emits compactionSummary JSON with Session anchor field" {
  run_hook_exec "pre-compact.sh" '{}'
  hook_output | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert 'hookSpecificOutput' in d, 'missing hookSpecificOutput'
summary = d['hookSpecificOutput']['compactionSummary']
assert 'Session anchor' in summary, f'Session anchor not in summary: {summary}'
"
}

@test "session-start: prunes compact checkpoints older than 1 day on startup" {
  STALE_CKPT="$RIG_DIR/memory/.compact-checkpoint-stale99.md"
  echo "# stale checkpoint" > "$STALE_CKPT"
  # Set mtime to 50 hours ago. find -mtime +1 uses integer division (age_seconds/86400 > 1),
  # so 25h would give 1 > 1 = false. 50h gives 180000/86400 = 2 > 1 = true.
  python3 -c "import os, time; os.utime('$STALE_CKPT', (time.time()-180000, time.time()-180000))"

  run_hook_exec "session-start.sh" '{"source":"startup"}'

  [ ! -f "$STALE_CKPT" ]
}

@test "session-start: does not prune compact checkpoints younger than 1 day on startup" {
  FRESH_CKPT="$RIG_DIR/memory/.compact-checkpoint-fresh99.md"
  echo "# fresh checkpoint" > "$FRESH_CKPT"
  # mtime is now — well within 1 day

  run_hook_exec "session-start.sh" '{"source":"startup"}'

  [ -f "$FRESH_CKPT" ]
}
