#!/usr/bin/env bash
# subagent-start.sh
#
# Runs when Claude Code spawns a subagent (SubagentStart event).
# Injects project context — branch, active task, and key conventions from CLAUDE.md —
# so the subagent starts with enough orientation to give project-aware feedback.
#
# Particularly useful for the code-reviewer agent (#228): a reviewer that doesn't
# know the project's coding standards can only produce generic feedback.
#
# Input JSON includes `agent_type` for conditional injection (not used here —
# context is injected for all subagents).
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

PROJECT_NAME=$(basename "$REPO")
BRANCH=$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")

# ── Gather active task ────────────────────────────────────────────────────────

ACTIVE_TASK=""
if [[ -d "$RIG_DIR/tasks/active" ]]; then
  TASK_FILE=$(ls "$RIG_DIR/tasks/active"/*.md 2>/dev/null | head -1 || true)
  if [[ -n "$TASK_FILE" ]]; then
    ACTIVE_TASK=$(basename "$TASK_FILE" .md)
  fi
fi

# ── Gather key conventions from CLAUDE.md ─────────────────────────────────────
# Extract the "Key conventions" section if present; fall back to off-limits only.

CLAUDE_MD="$REPO/CLAUDE.md"
CONVENTIONS=""
if [[ -f "$CLAUDE_MD" ]]; then
  if command -v python3 >/dev/null 2>&1; then
    CONVENTIONS=$(python3 -c "
import re, sys
try:
    text = open('$CLAUDE_MD').read()
    m = re.search(r'## Key conventions\n(.*?)(?=\n## |\Z)', text, re.DOTALL)
    if m:
        print(m.group(1).strip())
except Exception:
    pass
" 2>/dev/null || true)
  fi
fi

# ── Off-limits paths ──────────────────────────────────────────────────────────

OFF_LIMITS=""
if [[ -f "$CLAUDE_MD" ]] && command -v python3 >/dev/null 2>&1; then
  OFF_LIMITS=$(python3 -c "
import re, sys
try:
    text = open('$CLAUDE_MD').read()
    m = re.search(r'## Off-limits.*?\n(.*?)(?=\n## |\Z)', text, re.DOTALL)
    if m:
        print(m.group(1).strip())
except Exception:
    pass
" 2>/dev/null || true)
fi

# ── Build context block ───────────────────────────────────────────────────────

CONTEXT="Project: ${PROJECT_NAME}
Branch: ${BRANCH}"

[[ -n "$ACTIVE_TASK" ]] && CONTEXT+="
Active task: ${ACTIVE_TASK}"

if [[ -n "$CONVENTIONS" ]]; then
  CONTEXT+="

Key conventions:
${CONVENTIONS}"
fi

if [[ -n "$OFF_LIMITS" ]]; then
  CONTEXT+="

Off-limits (never touch without explicit instruction):
${OFF_LIMITS}"
fi

# ── Emit ──────────────────────────────────────────────────────────────────────

if command -v python3 >/dev/null 2>&1; then
  printf '%s' "$CONTEXT" | python3 -c "
import json, sys
ctx = sys.stdin.read()
out = {
    'hookSpecificOutput': {
        'hookEventName': 'SubagentStart',
        'additionalContext': ctx
    }
}
print(json.dumps(out))
" 2>/dev/null || true
fi

exit 0
