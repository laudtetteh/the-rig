#!/usr/bin/env bash
# post-compact.sh
#
# Runs after Claude Code finishes compacting the context (PostCompact event).
# Reads the checkpoint written by pre-compact.sh and re-injects it as
# additionalContext so the agent can resume mid-task without losing awareness
# of what branch, commit, and step were active before compaction.
#
# Falls back to CONTEXT_SNAPSHOT.md if no checkpoint exists.
# Falls through silently (exit 0, no output) if neither file is present.

REPO=$(git rev-parse --show-toplevel 2>/dev/null)
[[ -z "$REPO" ]] && exit 0

if [[ -f "$REPO/.rigpath" ]]; then
  RIG_DIR=$(tr -d '[:space:]' < "$REPO/.rigpath")
else
  RIG_DIR="$REPO/.rig"
fi

SNAPSHOT="$RIG_DIR/memory/CONTEXT_SNAPSHOT.md"

CHECKPOINT="$RIG_DIR/memory/.compact-checkpoint-${PPID}.md"
if [[ ! -f "$CHECKPOINT" ]]; then
  CHECKPOINT=$(ls -t "$RIG_DIR/memory"/.compact-checkpoint-*.md 2>/dev/null | head -1 || true)
fi

if [[ -n "$CHECKPOINT" ]] && [[ -f "$CHECKPOINT" ]]; then
  CONTEXT=$(cat "$CHECKPOINT")
elif [[ -f "$SNAPSHOT" ]]; then
  CONTEXT=$(cat "$SNAPSHOT")
else
  exit 0
fi

if command -v python3 >/dev/null 2>&1; then
  printf '%s' "$CONTEXT" | python3 -c "
import json, sys
ctx = sys.stdin.read()
out = {
    'hookSpecificOutput': {
        'hookEventName': 'PostCompact',
        'additionalContext': ctx
    }
}
print(json.dumps(out))
" 2>/dev/null || true
fi

exit 0
