#!/usr/bin/env bash
# session-start.sh
#
# Runs at Claude Code session start (SessionStart event).
# Injects context before the first turn so the agent is oriented without
# relying on instruction-dependent file reading — hook-enforced orientation.
#
# Source values and behaviour:
#   startup / resume  — inject CONTEXT_SNAPSHOT.md + housekeeping flag warnings
#   compact           — inject .compact-checkpoint.md (PreCompact output);
#                       falls back to CONTEXT_SNAPSHOT.md if checkpoint absent
#   clear             — inject minimal orientation (project name + run /status)
#
# Output: JSON with hookSpecificOutput.additionalContext
# Falls through silently (exit 0, no output) on any error or missing files.

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
WRAP_NEEDED="$RIG_DIR/memory/.wrap-needed"
POST_MERGE_PENDING="$RIG_DIR/memory/.post-merge-pending"

# ── Helpers ───────────────────────────────────────────────────────────────────

flag_warnings() {
  local w=""
  if [[ -f "$WRAP_NEEDED" ]]; then
    w+="⚠️ The last session ended without running /wrap. CONTEXT_SNAPSHOT.md may be stale and PROGRESS.md has unexpanded entries. Run /wrap now to capture session state before starting new work — or say 'skip wrap' to proceed anyway."
  fi
  if [[ -f "$POST_MERGE_PENDING" ]]; then
    [[ -n "$w" ]] && w+=$'\n\n'
    w+="⚠️ A merge landed since /post-merge was last run. Memory may not reflect the merged state. Run /post-merge now — or say 'skip post-merge' to proceed anyway."
  fi
  printf '%s' "$w"
}

emit_context() {
  local ctx="$1"
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$ctx" | python3 -c "
import json, sys
ctx = sys.stdin.read()
out = {
    'hookSpecificOutput': {
        'hookEventName': 'SessionStart',
        'additionalContext': ctx
    }
}
print(json.dumps(out))
" 2>/dev/null || true
  fi
}

# ── Dispatch by source ────────────────────────────────────────────────────────

case "$SOURCE" in
  startup|resume)
    [[ ! -f "$SNAPSHOT" ]] && exit 0
    CONTEXT=$(cat "$SNAPSHOT")
    WARNINGS=$(flag_warnings)
    if [[ -n "$WARNINGS" ]]; then
      emit_context "${WARNINGS}"$'\n\n---\n\n'"${CONTEXT}"
    else
      emit_context "$CONTEXT"
    fi
    ;;

  compact)
    COMPACT_CHECKPOINT="$RIG_DIR/memory/.compact-checkpoint-${PPID}.md"
    if [[ ! -f "$COMPACT_CHECKPOINT" ]]; then
      COMPACT_CHECKPOINT=$(ls -t "$RIG_DIR/memory"/.compact-checkpoint-*.md 2>/dev/null | head -1 || true)
    fi
    if [[ -n "$COMPACT_CHECKPOINT" ]] && [[ -f "$COMPACT_CHECKPOINT" ]]; then
      CONTEXT=$(cat "$COMPACT_CHECKPOINT")
    elif [[ -f "$SNAPSHOT" ]]; then
      CONTEXT=$(cat "$SNAPSHOT")
    else
      exit 0
    fi
    WARNINGS=$(flag_warnings)
    if [[ -n "$WARNINGS" ]]; then
      emit_context "${WARNINGS}"$'\n\n---\n\n'"${CONTEXT}"
    else
      emit_context "$CONTEXT"
    fi
    ;;

  clear)
    PROJECT_NAME=$(basename "$REPO")
    emit_context "Project: ${PROJECT_NAME}. Session cleared — run /status for current state."
    ;;

  *)
    # Unknown source or unparseable input — fail silently
    exit 0
    ;;
esac

exit 0
