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
  mkdir -p "$REPO/bin"
  cp "$(pwd)/templates/project/bin/rig" "$REPO/bin/rig"
  chmod +x "$REPO/bin/rig"

  HOOK_DIR="$TMPDIR/hooks"
  mkdir -p "$HOOK_DIR"
  cp "$(pwd)/templates/project/.claude/hooks/session-start.sh" "$HOOK_DIR/session-start.sh"
  cp "$(pwd)/templates/project/.claude/hooks/stop.sh"          "$HOOK_DIR/stop.sh"
  cp "$(pwd)/templates/project/.claude/hooks/pre-compact.sh"   "$HOOK_DIR/pre-compact.sh"
  chmod +x "$HOOK_DIR"/*.sh

  # Session-start sources the project-local shared tip catalog and suppresses
  # tips whose commands are unavailable. Mirror those installed fixtures.
  cp "$(pwd)/templates/project/.rig/contextual-tips.sh" "$RIG_DIR/contextual-tips.sh"
  mkdir -p "$REPO/.claude/commands"
  for command in debug rig-gaps code-review sprint task session-name; do
    cp "$(pwd)/templates/project/.claude/commands/$command.md" "$REPO/.claude/commands/$command.md"
  done

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

@test "session-start: documented native ID bootstraps an exact v1 record" {
  run_hook_exec "session-start.sh" '{"source":"startup","session_id":"claude-native-1"}'
  SESSION_FILE=$(find "$RIG_DIR/memory/sessions" -name 'session-*.json' -print | head -1)
  SESSION_F="$SESSION_FILE" python3 -c 'import json,os; d=json.load(open(os.environ["SESSION_F"])); assert d["schema_version"]==1 and d["agent"]=="claude" and d["native"]["session_id"]=="claude-native-1" and d["lifecycle"]["state"]=="active"'
}

@test "session-start: resume preserves anchor while a new clear ID gets a new anchor" {
  run_hook_exec "session-start.sh" '{"source":"startup","session_id":"native-old"}'
  OLD=$(find "$RIG_DIR/memory/sessions" -name 'session-*.json' -exec python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["anchor"])' {} \;)
  run_hook_exec "session-start.sh" '{"source":"resume","session_id":"native-old"}'
  RESUMED=$(find "$RIG_DIR/memory/sessions" -name 'session-*.json' -exec python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["anchor"])' {} \;)
  [ "$OLD" = "$RESUMED" ]
  unset RIG_SESSION_FILE RIG_SESSION_ANCHOR
  run_hook_exec "session-start.sh" '{"source":"clear","session_id":"native-new"}'
  [ "$(find "$RIG_DIR/memory/sessions" -name 'session-*.json' | wc -l | tr -d ' ')" -eq 2 ]
}

@test "native compact never injects another anchor's checkpoint" {
  printf 'FOREIGN CHECKPOINT\n' > "$RIG_DIR/memory/.compact-checkpoint-foreign.md"
  run_hook_exec "session-start.sh" '{"source":"compact","session_id":"native-compact"}'
  hook_output | python3 -c '
import json,sys
ctx=json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"]
assert "FOREIGN CHECKPOINT" not in ctx and "# Context Snapshot" in ctx
'
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

# ── stop.sh (SessionEnd events) ──────────────────────────────────────────────
# stop.sh now handles both Stop (per-turn) and SessionEnd (true termination).
# SessionEnd payloads carry source=logout|prompt_input_exit|clear|resume.

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

  run_hook_exec "stop.sh" '{"source":"logout"}'

  STATUS=$(python3 -c "import json; print(json.load(open('$TEST_SESSION_FILE')).get('status',''))")
  [ "$STATUS" = "ended-no-wrap" ]
}

@test "session-end: logout cleans /tmp UUID sentinel" {
  echo "abc12345" > "$TEST_UUID_FILE"
  echo "## stub <!-- Auto-logged by post-tool hook -->" > "$RIG_DIR/memory/PROGRESS.md"

  run_hook_exec "stop.sh" '{"source":"logout"}'

  [ ! -f "$TEST_UUID_FILE" ]
}

@test "session-end: minimal checkpoint has Session anchor field (not Session name)" {
  echo "abc12345" > "$TEST_UUID_FILE"
  echo "## stub <!-- Auto-logged by post-tool hook -->" > "$RIG_DIR/memory/PROGRESS.md"

  run_hook_exec "stop.sh" '{"source":"logout"}'

  grep -q "\*\*Session anchor:\*\*" "$RIG_DIR/memory/CONTEXT_SNAPSHOT.md"
  ! grep -q "\*\*Session name:\*\*" "$RIG_DIR/memory/CONTEXT_SNAPSHOT.md"
}

@test "session-end: clear does not set .wrap-needed" {
  echo "## stub <!-- Auto-logged by post-tool hook -->" > "$RIG_DIR/memory/PROGRESS.md"

  run_hook_exec "stop.sh" '{"source":"clear"}'

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

  CKPT="$RIG_DIR/memory/.compact-checkpoint-compuuid.md"
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

@test "pre-compact: emits systemMessage JSON with Session anchor field" {
  run_hook_exec "pre-compact.sh" '{}'
  hook_output | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert 'systemMessage' in d, 'missing systemMessage'
assert 'Session anchor' in d['systemMessage'], f'Session anchor not in systemMessage: {d[\"systemMessage\"]}'
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

# ── Feature discovery tips ────────────────────────────────────────────────────

@test "tips: opt-out sentinel suppresses all tips" {
  # Create conditions that would normally fire multiple tips
  git -C "$REPO" commit --allow-empty -m "first commit" -q
  touch "$RIG_DIR/memory/.rig-tips-disabled"

  run_hook_exec "session-start.sh" '{"source":"startup"}'

  # additionalContext must not contain any "Tip:" prefix
  hook_output | python3 -c "
import json, sys
d = json.load(sys.stdin)
ctx = d['hookSpecificOutput']['additionalContext']
assert 'Tip:' not in ctx, f'found Tip: in context with opt-out enabled: {ctx[:200]}'
"
}

@test "tips: session-name tip fires once and not again" {
  git -C "$REPO" commit --allow-empty -m "first commit" -q

  # First startup — tip should appear and sentinel should be created
  run_hook_exec "session-start.sh" '{"source":"startup"}'
  hook_output | python3 -c "
import json, sys
d = json.load(sys.stdin)
ctx = d['hookSpecificOutput']['additionalContext']
assert '/session-name' in ctx, f'/session-name tip missing on first run: {ctx[:300]}'
"
  [ -f "$RIG_DIR/memory/tips/.tip-session-name-shown" ]

  # Second startup — tip must not repeat
  run_hook_exec "session-start.sh" '{"source":"startup"}'
  hook_output | python3 -c "
import json, sys
d = json.load(sys.stdin)
ctx = d['hookSpecificOutput']['additionalContext']
assert '/session-name' not in ctx, f'/session-name tip repeated on second run: {ctx[:300]}'
"
}

@test "tips: fewer-prompts tip suppressed when .fewer-prompts-enabled exists" {
  git -C "$REPO" commit --allow-empty -m "first commit" -q
  touch "$RIG_DIR/memory/.fewer-prompts-enabled"

  run_hook_exec "session-start.sh" '{"source":"startup"}'

  hook_output | python3 -c "
import json, sys
d = json.load(sys.stdin)
ctx = d['hookSpecificOutput']['additionalContext']
assert 'fewer-prompts-enabled' not in ctx, \
  f'fewer-prompts tip fired when feature already enabled: {ctx[:300]}'
"
}

@test "tips: sprint tip fires when 3+ distinct issue refs in PROGRESS.md" {
  git -C "$REPO" commit --allow-empty -m "first commit" -q
  # Write PROGRESS.md with 3 distinct issue refs
  printf '## 2026-06-21 — work\n[#1] [#2] [#3]\n' > "$RIG_DIR/memory/PROGRESS.md"

  run_hook_exec "session-start.sh" '{"source":"startup"}'

  hook_output | python3 -c "
import json, sys
d = json.load(sys.stdin)
ctx = d['hookSpecificOutput']['additionalContext']
assert '/sprint' in ctx, f'/sprint tip not fired with 3+ issue refs: {ctx[:300]}'
"
  [ -f "$RIG_DIR/memory/tips/.tip-sprint-shown" ]
}
