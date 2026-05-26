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

DECISION=$(printf '%s' "$INPUT" | python3 -c "
import json, sys, re

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)

tool_name = data.get('tool_name', '')
tool_input = data.get('tool_input', {})

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

# Not an approved pattern — fall through to normal permission handling
sys.exit(0)
" 2>/dev/null || true)

if [[ -n "$DECISION" ]]; then
  echo "$DECISION"
fi

exit 0
