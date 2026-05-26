#!/usr/bin/env bash
# prompt-submit.sh
#
# Runs on every user prompt (UserPromptSubmit event).
# Checks for .wrap-needed and .post-merge-pending flag files and injects
# a warning into context if either is set — so the agent sees the flag
# whether it was set at session start or mid-session (e.g. after a commit).
#
# Must be fast: UserPromptSubmit has a 30-second timeout.
# When no flags are set, exits immediately with no output.
#
# Output: JSON {"additionalContext": "..."} when a flag is present.
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

# Fast path: no flags set — exit with no output
if [[ ! -f "$WRAP_NEEDED" && ! -f "$POST_MERGE_PENDING" ]]; then
  exit 0
fi

# Build warning text
WARNINGS=""
if [[ -f "$WRAP_NEEDED" ]]; then
  WARNINGS+="⚠️ The last session ended without running /wrap. CONTEXT_SNAPSHOT.md may be stale and PROGRESS.md has unexpanded entries. Run /wrap now to capture session state before starting new work — or say 'skip wrap' to proceed anyway."
fi
if [[ -f "$POST_MERGE_PENDING" ]]; then
  [[ -n "$WARNINGS" ]] && WARNINGS+=$'\n\n'
  WARNINGS+="⚠️ A merge landed since /post-merge was last run. Memory may not reflect the merged state. Run /post-merge now — or say 'skip post-merge' to proceed anyway."
fi

# Output JSON additionalContext
if command -v python3 >/dev/null 2>&1; then
  printf '%s' "$WARNINGS" | python3 -c "
import json, sys
warnings = sys.stdin.read()
print(json.dumps({'additionalContext': warnings}))
" 2>/dev/null || true
fi

exit 0
