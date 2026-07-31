#!/usr/bin/env bash
# post-compact.sh
#
# Runs after Claude Code finishes compacting the context (PostCompact event).
# Reads the checkpoint written by pre-compact.sh and re-injects it as a
# systemMessage so the agent can resume mid-task without losing awareness
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
INPUT=$(cat)
NATIVE_SESSION_ID=""
if command -v python3 >/dev/null 2>&1; then
  NATIVE_SESSION_ID=$(printf '%s' "$INPUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("session_id", ""))' 2>/dev/null || true)
fi

CHECKPOINT="$RIG_DIR/memory/.compact-checkpoint-${PPID}.md"
if [[ -n "$NATIVE_SESSION_ID" && -x "$REPO/bin/rig" ]]; then
  _resolved=$("$REPO/bin/rig" session resolve --agent "${RIG_AGENT:-claude}" --native-session-id "$NATIVE_SESSION_ID" --json 2>/dev/null) || exit 0
  _anchor=$(printf '%s' "$_resolved" | python3 -c 'import json,sys; print(json.load(sys.stdin)["anchor"])' 2>/dev/null) || exit 0
  CHECKPOINT="$RIG_DIR/memory/.compact-checkpoint-${_anchor}.md"
elif [[ ! -f "$CHECKPOINT" ]]; then
  CHECKPOINT=$(ls -t "$RIG_DIR/memory"/.compact-checkpoint-*.md 2>/dev/null | head -1 || true)
fi

if [[ -n "$CHECKPOINT" ]] && [[ -f "$CHECKPOINT" ]]; then
  CONTEXT=$(cat "$CHECKPOINT")
  STORED_BRANCH=$(sed -n 's/^\*\*Branch:\*\* //p' "$CHECKPOINT" | head -1)
  STORED_HEAD=$(sed -n 's/^\*\*HEAD SHA:\*\* //p' "$CHECKPOINT" | head -1)
  LIVE_BRANCH=$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
  LIVE_HEAD=$(git -C "$REPO" rev-parse HEAD 2>/dev/null || true)
  STALE_REASONS=""
  if [[ -n "$STORED_BRANCH" && -n "$LIVE_BRANCH" && "$STORED_BRANCH" != "$LIVE_BRANCH" ]]; then
    STALE_REASONS="branch changed from ${STORED_BRANCH} to ${LIVE_BRANCH}"
  fi
  if [[ -n "$STORED_HEAD" && -n "$LIVE_HEAD" && "$STORED_HEAD" != "$LIVE_HEAD" ]]; then
    [[ -n "$STALE_REASONS" ]] && STALE_REASONS+="; "
    STALE_REASONS+="HEAD changed from ${STORED_HEAD} to ${LIVE_HEAD}"
  fi
  if [[ -n "$STALE_REASONS" ]]; then
    CONTEXT="⚠️ Advisory: compact checkpoint is stale (${STALE_REASONS}). Treat it as historical context and verify live repository state before continuing.

${CONTEXT}"
  fi
elif [[ -f "$SNAPSHOT" ]]; then
  CONTEXT=$(cat "$SNAPSHOT")
else
  exit 0
fi

if command -v python3 >/dev/null 2>&1; then
  printf '%s' "$CONTEXT" | python3 -c "
import json, sys
ctx = sys.stdin.read()
print(json.dumps({'systemMessage': ctx}))
" 2>/dev/null || true
fi

exit 0
