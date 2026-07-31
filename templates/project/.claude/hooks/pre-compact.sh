#!/usr/bin/env bash
# pre-compact.sh
#
# Runs before Claude Code compacts the context (PreCompact event).
# Writes a minimal checkpoint to $RIG_DIR/memory/.compact-checkpoint-{PPID}.md
# capturing current branch, last commit, active task, session anchor, and
# tentative name. The checkpoint is read back by post-compact.sh (same session)
# and by session-start.sh when source=compact (new session after compaction).
#
# Also outputs a systemMessage so the checkpoint content is injected into
# the compaction context before Claude compacts.
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

SESSION_PID="${RIG_SESSION_PID:-$PPID}"
CHECKPOINT="$RIG_DIR/memory/.compact-checkpoint-${SESSION_PID}.md"

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

SNAPSHOT="$RIG_DIR/memory/CONTEXT_SNAPSHOT.md"
SESSION_ANCHOR="none"
TENTATIVE_NAME="none"
CONTEXT_HEADER=""

# ── Read session identity from session file (UUID model) ──────────────────────
SESSION_FILE="${RIG_SESSION_FILE:-$RIG_DIR/memory/sessions/session-${SESSION_PID}.json}"
if [[ -f "$SESSION_FILE" ]]; then
  # Single python3 call for both fields — halves subprocess cost and avoids
  # a race where the file changes between two sequential reads.
  _session_data=$(SESSION_F="$SESSION_FILE" python3 -c "
import json, os, sys
try:
    d = json.load(open(os.environ['SESSION_F']))
    sys.stdout.write((d.get('anchor') or 'none') + '\n')
    sys.stdout.write((d.get('tentative_name') or 'none') + '\n')
except Exception:
    sys.stdout.write('none\nnone\n')
" 2>/dev/null || printf 'none\nnone\n')
  SESSION_ANCHOR=$(printf '%s' "$_session_data" | head -1)
  TENTATIVE_NAME=$(printf '%s' "$_session_data" | tail -n +2 | head -1)
  [[ -z "$SESSION_ANCHOR" ]] && SESSION_ANCHOR="none"
  [[ -z "$TENTATIVE_NAME" ]] && TENTATIVE_NAME="none"
elif [[ -f "$SNAPSHOT" ]]; then
  # Backward-compat: session started before UUID system was installed.
  # Try to read the legacy "Session name:" field written by old /wrap.
  _legacy=$(grep "^\*\*Session name:\*\*" "$SNAPSHOT" 2>/dev/null \
    | sed 's/\*\*Session name:\*\* *//' | head -1 || true)
  [[ -n "$_legacy" ]] && TENTATIVE_NAME="$_legacy"
fi
# ─────────────────────────────────────────────────────────────────────────────

if [[ -f "$SNAPSHOT" ]]; then
  # Extract the header section (everything before the first --- divider) for
  # post-compaction orientation; agent can read project state without needing
  # the full snapshot file. Capped at 25 lines to guard against malformed
  # files with no --- divider producing an oversized checkpoint.
  CONTEXT_HEADER=$(awk '/^---/{exit} {print}' "$SNAPSHOT" 2>/dev/null | head -25 || true)
fi

# ── Write checkpoint ───────────────────────────────────────────────────────────

cat > "$CHECKPOINT" <<CPEOF
## Compact checkpoint — ${TIMESTAMP}

**Branch:** ${BRANCH}
**Last commit:** ${LAST_COMMIT}
**Active task:** ${ACTIVE_TASK}
**Last progress entry:** ${LAST_PROGRESS}
**Session anchor:** ${SESSION_ANCHOR}
**Session tentative name:** ${TENTATIVE_NAME}

---

${CONTEXT_HEADER}
CPEOF

# ── Output checkpoint as systemMessage ────────────────────────────────────────

if command -v python3 >/dev/null 2>&1 && [[ -f "$CHECKPOINT" ]]; then
  CHECKPOINT_F="$CHECKPOINT" python3 -c "
import json, os
ctx = open(os.environ['CHECKPOINT_F']).read()
print(json.dumps({'systemMessage': ctx}))
" 2>/dev/null || true
fi

exit 0
