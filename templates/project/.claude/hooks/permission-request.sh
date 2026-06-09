#!/usr/bin/env bash
# permission-request.sh
#
# Runs when Claude Code requests permission to use a tool (PermissionRequest event).
# Auto-approves known-safe read-only patterns so the user isn't prompted
# repeatedly for the same operations within and across sessions.
#
# Approved patterns:
#   Read       — any file (read-only, no side effects)
#   Bash       — git log/status/diff/branch (read-only git queries)
#   Bash       — bats (test runner, local only)
#   Bash       — bash -n (syntax check, no execution)
#   Bash       — grep, find (read-only searches)
#   Edit/Write — any path under $RIG_DIR (Rig's own memory, tasks, docs)
#                opt-out: touch $RIG_DIR/memory/.rig-strict-permissions
#
# For approved patterns: outputs JSON decision with behavior: allow.
# For all other patterns: exits 0 with no output (normal permission handling).
#
# Input JSON: {"tool_name": "...", "tool_input": {...}, ...}
# Output JSON: {"hookSpecificOutput": {"hookEventName": "PermissionRequest",
#               "decision": {"behavior": "allow"}}}

INPUT=$(cat)

if ! command -v python3 >/dev/null 2>&1; then
  exit 0
fi

# Resolve RIG_DIR — check for .rigpath (stealth mode) first.
# _RIG_TEST_RIG_DIR overrides for test injection.
if [[ -n "${_RIG_TEST_RIG_DIR:-}" ]]; then
  RIG_DIR="$_RIG_TEST_RIG_DIR"
else
  REPO=$(git rev-parse --show-toplevel 2>/dev/null || true)
  if [[ -n "$REPO" && -f "$REPO/.rigpath" ]]; then
    RIG_DIR=$(tr -d '[:space:]' < "$REPO/.rigpath")
  else
    RIG_DIR="${REPO}/.rig"
  fi
fi

DECISION=$(printf '%s' "$INPUT" | RIG_DIR="$RIG_DIR" python3 -c "
import json, sys, re, os

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)

tool_name = data.get('tool_name', '')
tool_input = data.get('tool_input', {})
rig_dir = os.environ.get('RIG_DIR', '').rstrip('/')

def allow():
    out = {
        'hookSpecificOutput': {
            'hookEventName': 'PermissionRequest',
            'decision': {
                'behavior': 'allow'
            }
        }
    }
    print(json.dumps(out))
    sys.exit(0)

# Read — always safe
if tool_name == 'Read':
    allow()

# Bash — check command against safe patterns
if tool_name == 'Bash':
    cmd = tool_input.get('command', '').lstrip()
    safe_patterns = [
        r'^git (log|status|diff|branch|show|describe|tag|remote|stash list)',
        r'^bats\b',
        r'^bash\s+-n\b',
        r'^grep\b',
        r'^find\b',
    ]
    for pattern in safe_patterns:
        if re.match(pattern, cmd):
            allow()

# Edit/Write — auto-approve writes to Rig's own directory.
# Principle: Rig is allowed to manage its own memory, tasks, and docs.
# Opt-out: touch \$RIG_DIR/memory/.rig-strict-permissions to disable.
if tool_name in ('Edit', 'Write', 'NotebookEdit') and rig_dir:
    strict_sentinel = os.path.join(rig_dir, 'memory', '.rig-strict-permissions')
    if not os.path.exists(strict_sentinel):
        file_path = tool_input.get('file_path', '').rstrip('/')
        if file_path and file_path.startswith(rig_dir + '/'):
            allow()

# Not an approved pattern — fall through to normal permission handling
sys.exit(0)
" 2>/dev/null || true)

if [[ -n "$DECISION" ]]; then
  echo "$DECISION"
fi

exit 0
