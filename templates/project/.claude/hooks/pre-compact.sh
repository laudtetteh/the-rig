#!/usr/bin/env bash
# pre-compact.sh
#
# Runs before Claude Code compacts the context (PreCompact event).
# Writes a minimal checkpoint to $RIG_DIR/memory/.compact-checkpoint.md
# capturing current branch, last commit, active task, and last progress entry.
# The checkpoint is read back by post-compact.sh (same session) and by
# session-start.sh when source=compact (new session after compaction).
#
# Also outputs a compactionSummary so the checkpoint survives in the
# compacted summary itself.
#
# Falls through silently (exit 0, no output) on any error or missing files.

REPO=$(git rev-parse --show-toplevel 2>/dev/null)
[[ -z "$REPO" ]] && exit 0

if [[ -f "$REPO/.rigpath" ]]; then
  RIG_DIR=$(tr -d '[:space:]' < "$REPO/.rigpath")
else
  RIG_DIR="$REPO/.rig"
fi

[[ ! -d "$RIG_DIR/memory" ]] && exit 0

CHECKPOINT="$RIG_DIR/memory/.compact-checkpoint.md"

# ── Gather context ─────────────────────────────────────────────────────────────

TIMESTAMP=$(date '+%Y-%m-%d %H:%M' 2>/dev/null || true)
BRANCH=$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
LAST_COMMIT=$(git -C "$REPO" log -1 --format="%h — %s" 2>/dev/null || echo "none")

ACTIVE_TASK="none"
if [[ -d "$RIG_DIR/tasks/active" ]]; then
  TASK_FILE=$(ls "$RIG_DIR/tasks/active"/*.md 2>/dev/null | head -1 || true)
  if [[ -n "$TASK_FILE" ]]; then
    ACTIVE_TASK=$(basename "$TASK_FILE" .md)
  fi
fi

LAST_PROGRESS="none"
PROGRESS_FILE="$RIG_DIR/memory/PROGRESS.md"
if [[ -f "$PROGRESS_FILE" ]]; then
  LAST_PROGRESS=$(grep -m1 "^## " "$PROGRESS_FILE" 2>/dev/null | sed 's/^## //' || echo "none")
fi

# ── Write checkpoint ───────────────────────────────────────────────────────────

cat > "$CHECKPOINT" <<CPEOF
## Compact checkpoint — ${TIMESTAMP}

**Branch:** ${BRANCH}
**Last commit:** ${LAST_COMMIT}
**Active task:** ${ACTIVE_TASK}
**Last progress entry:** ${LAST_PROGRESS}
CPEOF

# ── Output compactionSummary ───────────────────────────────────────────────────

if command -v python3 >/dev/null 2>&1; then
  SUMMARY="Branch: ${BRANCH} | Last commit: ${LAST_COMMIT} | Active task: ${ACTIVE_TASK} | Last progress: ${LAST_PROGRESS}"
  printf '%s' "$SUMMARY" | python3 -c "
import json, sys
summary = sys.stdin.read()
out = {
    'hookSpecificOutput': {
        'hookEventName': 'PreCompact',
        'compactionSummary': summary
    }
}
print(json.dumps(out))
" 2>/dev/null || true
fi

exit 0
