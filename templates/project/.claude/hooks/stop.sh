#!/usr/bin/env bash
# stop.sh
#
# Handles two Claude Code hook events in one script:
#
#   Stop (fires after every agent turn)
#     1. Updates the date in the "Last updated:" line in CONTEXT_SNAPSHOT.md
#     2. Appends a session-end comment to PROGRESS.md (used by /wrap for naming)
#
#   SessionEnd (fires once when the session truly terminates)
#     Source values:
#       logout / prompt_input_exit — user closed the session
#           Write .wrap-needed if /wrap hasn't run and the session had meaningful
#           commits. Write minimal checkpoint. Mark session file ended-no-wrap.
#           Clean /tmp UUID sentinel and compact checkpoint.
#       clear — context was cleared; session continues in a new context window
#           Log "context cleared". Do NOT set .wrap-needed.
#       resume — new session starting; nothing to do.
#
# Dispatch is by the `source` field in the JSON payload:
#   SessionEnd payloads carry source = logout | prompt_input_exit | clear | resume
#   Stop payloads carry no source field (empty string after parse)
#
# Never blocks (exit 0 always). Fails silently on any error.
#
# Claude Code passes: stdin — event data as JSON

REPO=$(git rev-parse --show-toplevel 2>/dev/null)
[[ -z "$REPO" ]] && exit 0

# ── Resolve RIG_DIR ───────────────────────────────────────────────────────────
if [[ -f "$REPO/.rigpath" ]]; then
  RIG_DIR=$(tr -d '[:space:]' < "$REPO/.rigpath")
else
  RIG_DIR="$REPO/.rig"
fi

INPUT=$(cat)

# Parse source — present only in SessionEnd payloads; empty for Stop
SOURCE=""
NATIVE_SESSION_ID=""
if command -v python3 >/dev/null 2>&1; then
  _identity_input=$(printf '%s' "$INPUT" | python3 -c "
import json, sys
try:
    d=json.load(sys.stdin)
    print(d.get('source', ''))
    print(d.get('session_id', ''))
except Exception:
    pass
" 2>/dev/null || true)
  SOURCE=$(printf '%s' "$_identity_input" | sed -n '1p')
  NATIVE_SESSION_ID=$(printf '%s' "$_identity_input" | sed -n '2p')
fi

SNAPSHOT="$RIG_DIR/memory/CONTEXT_SNAPSHOT.md"
PROGRESS="$RIG_DIR/memory/PROGRESS.md"
WRAP_NEEDED="$RIG_DIR/memory/.wrap-needed"
SNAP_LOCK="$RIG_DIR/memory/.snapshot-write-in-progress"
SESSION_LOG="${RIG_SESSION_LOG:-/tmp/the-rig-session-$(basename "$REPO").log}"
NOW_FULL=$(date "+%Y-%m-%d %H:%M" 2>/dev/null || true)
SESSION_PID="${RIG_SESSION_PID:-$PPID}"
SESSION_FILE="${RIG_SESSION_FILE:-$RIG_DIR/memory/sessions/session-${SESSION_PID}.json}"
if [[ -n "$NATIVE_SESSION_ID" && -x "$REPO/bin/rig" ]]; then
  _resolved=$("$REPO/bin/rig" session resolve --agent "${RIG_AGENT:-claude}" --native-session-id "$NATIVE_SESSION_ID" --json 2>/dev/null) || exit 0
  SESSION_FILE=$(printf '%s' "$_resolved" | python3 -c 'import json,sys; print(json.load(sys.stdin)["session_file"])' 2>/dev/null) || exit 0
  RIG_SESSION_ANCHOR=$(printf '%s' "$_resolved" | python3 -c 'import json,sys; print(json.load(sys.stdin)["anchor"])' 2>/dev/null) || exit 0
fi

# ── Dispatch ──────────────────────────────────────────────────────────────────

case "$SOURCE" in

  # ── SessionEnd: logout or explicit exit ────────────────────────────────────
  logout|prompt_input_exit)
    # Helpers scoped to this branch
    write_wrap_needed() {
      local reason="$1"
      touch "$WRAP_NEEDED" 2>/dev/null || true
      echo "[$(date +%H:%M:%S)] SESSION_END: .wrap-needed written (${reason})" \
        >> "$SESSION_LOG" 2>/dev/null || true
    }

    write_minimal_checkpoint() {
      [[ ! -d "$RIG_DIR/memory" ]] && return
      if [[ -f "$SNAP_LOCK" ]]; then
        echo "[$(date +%H:%M:%S)] SESSION_END: snapshot write in progress — skipping minimal checkpoint" \
          >> "$SESSION_LOG" 2>/dev/null || true
        return
      fi
      local branch commit active_task session_anchor=""
      branch=$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
      commit=$(git -C "$REPO" log -1 --format="%h %s" 2>/dev/null || echo "none")
      active_task=""
      if [[ -d "$RIG_DIR/tasks/active" ]]; then
        active_task=$(ls "$RIG_DIR/tasks/active"/*.md 2>/dev/null \
          | head -1 | xargs basename 2>/dev/null || true)
      fi
      session_anchor="${RIG_SESSION_ANCHOR:-$(cat "/tmp/.rig-session-${SESSION_PID}.uuid" 2>/dev/null || true)}"
      {
        echo "# Context Snapshot — session-end checkpoint"
        echo ""
        echo "> Minimal checkpoint written at session end by stop.sh (SessionEnd)."
        echo "> Run \`/wrap\` at the start of the next session for a full snapshot."
        echo ""
        echo "**Last updated:** $NOW_FULL — session-end checkpoint"
        echo "**Branch:** $branch"
        echo "**Last commit:** $commit"
        [[ -n "$active_task" ]] && echo "**Active task:** $active_task"
        [[ -n "$session_anchor" ]] && echo "**Session anchor:** $session_anchor"
        echo ""
        echo "---"
        echo ""
        echo "## Status"
        echo ""
        echo "Session ended without running \`/wrap\`. Run \`/wrap\` to capture full context."
      } > "$SNAPSHOT" 2>/dev/null || true
      echo "[$(date +%H:%M:%S)] SESSION_END: minimal checkpoint written" \
        >> "$SESSION_LOG" 2>/dev/null || true
    }

    NEEDS_WRAP=false

    if [[ -f "$PROGRESS" ]] && grep -q "Auto-logged by post-tool hook" "$PROGRESS" 2>/dev/null; then
      write_wrap_needed "unexpanded stubs in PROGRESS.md"
      NEEDS_WRAP=true
    fi

    if [[ "$NEEDS_WRAP" == false ]] && [[ ! -f "$SNAPSHOT" ]] && [[ -f "$PROGRESS" ]]; then
      write_wrap_needed "no CONTEXT_SNAPSHOT.md"
      NEEDS_WRAP=true
    fi

    if [[ "$NEEDS_WRAP" == false ]]; then
      SESSION_COMMIT_COUNT=$(grep -c "PROGRESS stub:" "$SESSION_LOG" 2>/dev/null || echo 0)
      if [[ "$SESSION_COMMIT_COUNT" -ge 2 ]]; then
        write_wrap_needed "${SESSION_COMMIT_COUNT} commits this session"
        NEEDS_WRAP=true
      fi
    fi

    [[ "$NEEDS_WRAP" == true ]] && write_minimal_checkpoint

    rm -f "$RIG_DIR/memory/.compact-checkpoint-${SESSION_PID}.md" 2>/dev/null || true
    rm -f "/tmp/.rig-session-${SESSION_PID}.uuid" 2>/dev/null || true

    if [[ -f "$SESSION_FILE" ]]; then
      SESSION_F="$SESSION_FILE" WRAP_F="$WRAP_NEEDED" END_SOURCE="$SOURCE" python3 -c "
import datetime, fcntl, json, os, tempfile
try:
    p = os.environ['SESSION_F']
    lock=open(p+'.lock','a+'); fcntl.flock(lock.fileno(),fcntl.LOCK_EX)
    with open(p) as f:
        d = json.load(f)
    if d.get('schema_version') == 1:
        now=datetime.datetime.now(datetime.timezone.utc).astimezone().isoformat(timespec='seconds')
        d['updated_at']=now; d['revision']=int(d.get('revision',0))+1
        d['lifecycle'].update({'state':'ended_no_wrap' if os.path.exists(os.environ['WRAP_F']) else 'inactive','last_event':'session_end','last_event_at':now,'end_reason':os.environ['END_SOURCE']})
    else: d['status'] = 'ended-no-wrap'
    fd,tmp=tempfile.mkstemp(prefix='.session-',suffix='.tmp',dir=os.path.dirname(p))
    with os.fdopen(fd,'w') as f: json.dump(d,f,indent=2); f.write('\n'); f.flush(); os.fsync(f.fileno())
    os.replace(tmp,p)
except Exception:
    pass
" 2>/dev/null || true
    fi

    echo "[$(date +%H:%M:%S)] SESSION_END: source=${SOURCE} — session terminated" \
      >> "$SESSION_LOG" 2>/dev/null || true
    ;;

  # ── SessionEnd: context cleared, session continues ─────────────────────────
  clear)
    echo "[$(date +%H:%M:%S)] SESSION_END: source=clear — context cleared, session continues" \
      >> "$SESSION_LOG" 2>/dev/null || true
    ;;

  # ── SessionEnd: resume (new session starting) — no action ──────────────────
  resume)
    ;;

  # ── Stop: per-turn work (source is empty for Stop events) ──────────────────
  *)
    # Update Last updated: date in CONTEXT_SNAPSHOT
    if [[ -f "$SNAPSHOT" ]] && grep -q "^\*\*Last updated:\*\*" "$SNAPSHOT" 2>/dev/null; then
      DESCRIPTION=$(grep "^\*\*Last updated:\*\*" "$SNAPSHOT" \
        | sed 's/\*\*Last updated:\*\*[^—]*— //')
      TMP=$(mktemp)
      awk -v now="$NOW_FULL" -v desc="$DESCRIPTION" -v em="—" '
        /^\*\*Last updated:\*\*/ { print "**Last updated:** " now " " em " " desc; next }
        { print }
      ' "$SNAPSHOT" > "$TMP" && mv "$TMP" "$SNAPSHOT"
      echo "[$(date +%H:%M:%S)] STOP: updated Last updated: → $NOW_FULL in CONTEXT_SNAPSHOT" \
        >> "$SESSION_LOG" 2>/dev/null || true
    fi

    # Append session-end marker to PROGRESS.md
    if [[ -f "$PROGRESS" ]]; then
      SESSION_UUID="${RIG_SESSION_ANCHOR:-$(cat "/tmp/.rig-session-${SESSION_PID}.uuid" 2>/dev/null || true)}"
      LAST_MEANINGFUL=$(grep -v '^[[:space:]]*$' "$PROGRESS" | tail -1)
      if [[ "$LAST_MEANINGFUL" != "<!-- session-end"* ]]; then
        if [[ -n "$SESSION_UUID" ]]; then
          printf "\n<!-- session-end %s sid:%s -->\n" "$NOW_FULL" "$SESSION_UUID" >> "$PROGRESS"
          echo "[$(date +%H:%M:%S)] STOP: session-end marker appended ($NOW_FULL sid:$SESSION_UUID)" \
            >> "$SESSION_LOG" 2>/dev/null || true
        else
          printf "\n<!-- session-end %s -->\n" "$NOW_FULL" >> "$PROGRESS"
          echo "[$(date +%H:%M:%S)] STOP: session-end marker appended ($NOW_FULL, no UUID)" \
            >> "$SESSION_LOG" 2>/dev/null || true
        fi
      else
        echo "[$(date +%H:%M:%S)] STOP: session-end marker already present — skipped" \
          >> "$SESSION_LOG" 2>/dev/null || true
      fi
    fi
    ;;

esac

exit 0
