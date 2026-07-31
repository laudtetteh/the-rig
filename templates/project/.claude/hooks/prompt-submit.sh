#!/usr/bin/env bash
# prompt-submit.sh
#
# Runs on every user prompt (UserPromptSubmit event).
# Checks for .wrap-needed and .post-merge-pending flag files and injects
# a warning into context if either is set — so the agent sees the flag
# whether it was set at session start or mid-session (e.g. after a commit).
#
# Also fires a one-time nudge when the project's permission allowlist is
# sparse, suggesting /fewer-permission-prompts to reduce session friction.
#
# Must be fast: UserPromptSubmit has a 30-second timeout.
# When no flags are set and the nudge has already been offered, exits immediately.
#
# Output: JSON {"additionalContext": "..."} when there is something to surface.
# Claude Code receives this as context alongside the user's message.

REPO=$(git rev-parse --show-toplevel 2>/dev/null)
[[ -z "$REPO" ]] && exit 0

if [[ -f "$REPO/.rigpath" ]]; then
  RIG_DIR=$(tr -d '[:space:]' < "$REPO/.rigpath")
else
  RIG_DIR="$REPO/.rig"
fi

WRAP_NEEDED="$RIG_DIR/memory/.wrap-needed"
POST_MERGE_PENDING="$RIG_DIR/memory/.post-merge-pending"
NUDGE_FLAG="$RIG_DIR/memory/.permission-nudge-offered"

# Fast path: no flags AND nudge already evaluated — exit immediately
if [[ ! -f "$WRAP_NEEDED" && ! -f "$POST_MERGE_PENDING" && -f "$NUDGE_FLAG" ]]; then
  exit 0
fi

# Build warning text for housekeeping flags
WARNINGS=""
if [[ -f "$WRAP_NEEDED" ]]; then
  WARNINGS+="⚠️ The last session ended without running /wrap. CONTEXT_SNAPSHOT.md may be stale and PROGRESS.md has unexpanded entries. Run /wrap now to capture session state before starting new work — or say 'skip wrap' to proceed anyway."
fi
if [[ -f "$POST_MERGE_PENDING" ]]; then
  [[ -n "$WARNINGS" ]] && WARNINGS+=$'\n\n'
  MERGE_SHA=$(sed -n 's/^merge_sha=//p' "$POST_MERGE_PENDING" 2>/dev/null | head -1)
  MERGED_AT=$(sed -n 's/^merged_at=//p' "$POST_MERGE_PENDING" 2>/dev/null | head -1)
  MERGE_DETAIL=""
  [[ -n "$MERGE_SHA" ]] && MERGE_DETAIL=" Merge: ${MERGE_SHA}"
  [[ -n "$MERGED_AT" ]] && MERGE_DETAIL+=" at ${MERGED_AT}."
  [[ -n "$MERGE_DETAIL" && "$MERGE_DETAIL" != *. ]] && MERGE_DETAIL+="."
  WARNINGS+="⚠️ A merge landed since /post-merge was last run.${MERGE_DETAIL} Memory may not reflect the merged state. Run /post-merge now — or say 'skip for current task' to proceed without clearing the reminder."
fi

# Permission nudge — once per project when allowlist is sparse
if [[ ! -f "$NUDGE_FLAG" ]] && command -v python3 >/dev/null 2>&1; then
  SETTINGS="$REPO/.claude/settings.json"
  if [[ -f "$SETTINGS" ]]; then
    allowed_count=$(python3 -c "
import json, sys
try:
    d = json.load(open('$SETTINGS'))
    print(len(d.get('permissions', {}).get('allow', [])))
except Exception:
    print(99)
" 2>/dev/null || echo 99)
    touch "$NUDGE_FLAG"
    if [[ "$allowed_count" -lt 5 ]]; then
      [[ -n "$WARNINGS" ]] && WARNINGS+=$'\n\n'
      WARNINGS+="Tip: run /fewer-permission-prompts to build a permission allowlist from your session history — reduces repetitive prompts without affecting oversight of write operations."
    fi
  fi
fi

# Exit cleanly if nothing to report
[[ -z "$WARNINGS" ]] && exit 0

# Output JSON additionalContext
if command -v python3 >/dev/null 2>&1; then
  printf '%s' "$WARNINGS" | python3 -c "
import json, sys
warnings = sys.stdin.read()
print(json.dumps({'additionalContext': warnings}))
" 2>/dev/null || true
fi

exit 0
