#!/usr/bin/env bash
# session-end.sh
#
# Runs when a Claude Code session terminates (SessionEnd event).
# Handles true end-of-session cleanup — distinct from stop.sh which fires
# after every agent turn (Stop event).
#
# Source values and behaviour:
#   logout / prompt_input_exit — user closed the session
#       Write .wrap-needed if /wrap hasn't run and the session had meaningful
#       commits. Write minimal checkpoint. Log session end.
#   clear — context was cleared; session will continue in a new context window
#       Log "context cleared" to session log. Do NOT set .wrap-needed.
#   resume — new session is starting; nothing to clean up here
#   other — unknown source; no action
#
# Never blocks (exit 2 shows stderr but does not prevent termination).
# Fails silently on any error.

REPO=$(git rev-parse --show-toplevel 2>/dev/null)
[[ -z "$REPO" ]] && exit 0

if [[ -f "$REPO/.rigpath" ]]; then
  RIG_DIR=$(tr -d '[:space:]' < "$REPO/.rigpath")
else
  RIG_DIR="$REPO/.rig"
fi

INPUT=$(cat)

# Parse source from stdin JSON
SOURCE=""
if command -v python3 >/dev/null 2>&1; then
  SOURCE=$(printf '%s' "$INPUT" | python3 -c "
import json, sys
try:
    print(json.load(sys.stdin).get('source', ''))
except Exception:
    pass
" 2>/dev/null || true)
fi

SNAPSHOT="$RIG_DIR/memory/CONTEXT_SNAPSHOT.md"
PROGRESS="$RIG_DIR/memory/PROGRESS.md"
WRAP_NEEDED="$RIG_DIR/memory/.wrap-needed"
SESSION_LOG="${RIG_SESSION_LOG:-/tmp/the-rig-session.log}"
NOW_FULL=$(date "+%Y-%m-%d %H:%M" 2>/dev/null || true)

# ── Helpers ───────────────────────────────────────────────────────────────────

write_wrap_needed() {
  local reason="$1"
  touch "$WRAP_NEEDED" 2>/dev/null || true
  echo "[$(date +%H:%M:%S)] SESSION_END: .wrap-needed written (${reason})" \
    >> "$SESSION_LOG" 2>/dev/null || true
}

write_minimal_checkpoint() {
  [[ ! -d "$RIG_DIR/memory" ]] && return
  local branch commit active_task session_name=""
  branch=$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
  commit=$(git -C "$REPO" log -1 --format="%h %s" 2>/dev/null || echo "none")
  active_task=""
  if [[ -d "$RIG_DIR/tasks/active" ]]; then
    active_task=$(ls "$RIG_DIR/tasks/active"/*.md 2>/dev/null \
      | head -1 | xargs basename 2>/dev/null || true)
  fi
  # Preserve the session name from the existing snapshot before overwriting it.
  if [[ -f "$SNAPSHOT" ]]; then
    session_name=$(grep -m1 "^\*\*Session name:\*\*" "$SNAPSHOT" 2>/dev/null \
      | sed 's/\*\*Session name:\*\* *//' || true)
  fi

  {
    echo "# Context Snapshot — session-end checkpoint"
    echo ""
    echo "> Minimal checkpoint written at session end by session-end.sh."
    echo "> Run \`/wrap\` at the start of the next session for a full snapshot."
    echo ""
    echo "**Last updated:** $NOW_FULL — session-end checkpoint"
    echo "**Branch:** $branch"
    echo "**Last commit:** $commit"
    [[ -n "$active_task" ]] && echo "**Active task:** $active_task"
    [[ -n "$session_name" ]] && echo "**Session name:** $session_name"
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

# ── Dispatch by source ────────────────────────────────────────────────────────

case "$SOURCE" in
  logout|prompt_input_exit)
    # Determine whether .wrap-needed should be set
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

    if [[ "$NEEDS_WRAP" == true ]]; then
      write_minimal_checkpoint
    fi

    echo "[$(date +%H:%M:%S)] SESSION_END: source=${SOURCE} — session terminated" \
      >> "$SESSION_LOG" 2>/dev/null || true
    ;;

  clear)
    echo "[$(date +%H:%M:%S)] SESSION_END: source=clear — context cleared, session continues" \
      >> "$SESSION_LOG" 2>/dev/null || true
    ;;

  resume|*)
    # No action needed
    ;;
esac

exit 0
