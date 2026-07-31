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
#   Bash       — cat, head, tail, wc (read-only inspection), optionally after
#                a narrow variable-assignment preamble
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
import json, sys, re, os, shlex

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

# Bash — validate the complete command. Shell syntax outside this deliberately
# narrow grammar falls through to normal permission handling.
if tool_name == 'Bash':
    cmd = tool_input.get('command', '').strip()
    dollar = chr(36)
    forbidden = ('|', '&', '<', '>', chr(96), dollar + '(')

    def safe_assignment(segment):
        if not re.match(r'^[A-Za-z_][A-Za-z0-9_]*=', segment):
            return False
        _, value = segment.split('=', 1)
        if value == dollar + '(git rev-parse --show-toplevel)':
            return True
        # Permit only inert path-like values and simple variable expansion.
        variable = re.escape(dollar) + r'(?:[A-Za-z_][A-Za-z0-9_]*|\{[A-Za-z_][A-Za-z0-9_]*\})'
        value = re.sub(variable, '', value)
        return bool(value) and re.fullmatch(r'[A-Za-z0-9_./{}\"\x27:+-]+', value) is not None

    def safe_git(tokens):
        if len(tokens) < 2:
            return False
        subcommand, args = tokens[1], tokens[2:]
        if any(arg.startswith('--output') for arg in args):
            return False
        if subcommand in ('log', 'status', 'diff', 'show', 'describe'):
            return True
        if subcommand == 'stash':
            return args == ['list']
        if subcommand == 'branch':
            read_flags = ('-a', '--all', '-r', '--remotes', '-v', '-vv', '--verbose', '--color', '--no-color', '--show-current', '--contains', '--no-contains', '--merged', '--no-merged', '--points-at', '--format', '--sort', '--column', '--no-column', '--ignore-case')
            if not args:
                return True
            if args[0] in ('-l', '--list'):
                return True
            return all(arg.startswith(read_flags) for arg in args)
        if subcommand == 'tag':
            return not args or args[0] in ('-l', '--list')
        if subcommand == 'remote':
            return not args or args[0] in ('-v', '--verbose', 'show', 'get-url')
        return False

    def safe_segment(segment):
        if not segment or any(op in segment for op in forbidden):
            return False
        try:
            tokens = shlex.split(segment, posix=True)
        except ValueError:
            return False
        if not tokens:
            return False
        if tokens[0] == 'git':
            return safe_git(tokens)
        if tokens[0] == 'bats':
            return True
        if tokens[0] == 'bash':
            return len(tokens) >= 2 and tokens[1] == '-n'
        if tokens[0] in ('grep', 'cat', 'head', 'tail', 'wc'):
            return True
        if tokens[0] == 'find':
            write_actions = ('-delete', '-exec', '-execdir', '-ok', '-okdir', '-fprint', '-fprint0', '-fprintf', '-fls')
            return not any(token in write_actions for token in tokens[1:])
        return False

    # Semicolons and newlines are the only accepted command separators. Each
    # assignment or command segment must be independently safe.
    segments = [segment.strip() for segment in re.split(r';[ \t]*\n|;|\n', cmd)]
    seen_command = False
    valid = bool(segments)
    for segment in segments:
        if not seen_command and safe_assignment(segment):
            continue
        if safe_segment(segment):
            seen_command = True
            continue
        valid = False
        break
    if valid and seen_command:
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
