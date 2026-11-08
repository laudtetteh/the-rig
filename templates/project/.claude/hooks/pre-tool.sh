#!/bin/bash
# pre-tool.sh
#
# Runs before Claude Code executes any tool.
# Exit 0 to allow the tool call. Exit 2 to block it (stderr is shown to Claude).
#
# Claude Code passes:
#   stdin — an event JSON object with tool_name and nested tool_input
# The Codex adapter also supports its legacy positional tool-name/root-input shape.
#
# IMPORTANT: Tool names are PascalCase. Using snake_case (write_file, edit_file)
# will cause this script to silently never block anything. This was a real bug
# in production for 30+ PRs before it was caught.

TOOL="${1:-}"
INPUT=$(cat)

fail_closed() {
  echo "Blocked: $1" >&2
  exit 2
}

command -v python3 >/dev/null 2>&1 || fail_closed "python3 is required to inspect PreToolUse payloads."
TOOL=$(printf '%s' "$INPUT" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    if not isinstance(data, dict): raise ValueError("event is not an object")
    positional = sys.argv[1]
    native = data.get("tool_name", "")
    if not isinstance(native, str) or (native and positional and native != positional):
        raise ValueError("tool name mismatch")
    name = native or positional
    if not name: raise ValueError("tool name is missing")
    if not positional and "tool_input" not in data:
        raise ValueError("tool input is missing")
    if "tool_input" in data and not isinstance(data["tool_input"], dict):
        raise ValueError("tool input is not an object")
    event = data.get("hook_event_name", "PreToolUse")
    if event != "PreToolUse": raise ValueError("unexpected hook event")
    print(name)
except (ValueError, TypeError):
    raise SystemExit(1)
' "$TOOL") || fail_closed "PreToolUse payload is malformed or has no trustworthy tool name."

# ── Repo root — derive from the installed hook, not the current directory ───
# A tool may run after /cd; its cwd must not decide which policy protects it.
HOOK_ROOT=$(cd "$(dirname "$0")/../.." && pwd -P) || fail_closed "cannot resolve the installed hook root."
REPO=$(git -C "$HOOK_ROOT" rev-parse --show-toplevel 2>/dev/null) || fail_closed "cannot resolve the installed project root."
[[ "$REPO" == "$HOOK_ROOT" ]] || fail_closed "hook path is outside its project root."

# ── Resolve RIG_DIR ───────────────────────────────────────────────────────────
# Supports external .rig/ installations (see install.sh --rig-dir).
# If .rigpath exists in the repo root, it contains the absolute path to the
# .rig/ directory (which may be outside the repo). Otherwise default to $REPO/.rig.
if [[ -f "$REPO/.rigpath" ]]; then
  RIG_DIR=$(tr -d '[:space:]' < "$REPO/.rigpath")
else
  RIG_DIR="$REPO/.rig"
fi

commit_ok_age_seconds() {
  local file="$1"
  local now mtime

  now=$(date +%s 2>/dev/null || echo "")
  if [[ -z "$now" ]]; then
    return 1
  fi

  mtime=$(stat -c %Y "$file" 2>/dev/null || stat -f %m "$file" 2>/dev/null || echo "")
  if [[ -z "$mtime" ]]; then
    return 1
  fi

  case "$now:$mtime" in
    *[!0-9:]*|:*) return 1 ;;
  esac

  echo $((now - mtime))
}

# ── Session log ──────────────────────────────────────────────────────────────
# Logs every tool call with a timestamp. Useful for debugging agent behaviour.
# Scoped per-project so concurrent sessions on different projects don't
# contaminate each other's commit counts. Override with RIG_SESSION_LOG env var.
SESSION_LOG="${RIG_SESSION_LOG:-/tmp/the-rig-session-$(basename "$REPO").log}"
echo "[$(date +%H:%M:%S)] PRE  $TOOL" >> "$SESSION_LOG"

# ── Guard: git commit ────────────────────────────────────────────────────────
#
# Prevents the agent from committing before the user has approved the commit.
#
# git commit — blocked until a sentinel file exists:
#              $RIG_DIR/memory/.rig-commit-ok
#              The agent creates this file only after the user explicitly
#              confirms local testing is done (e.g. "ready to commit").
#              post-tool.sh deletes it automatically after the commit lands.
#              The file is gitignored via .rig/memory/.gitignore.
#
# In /ship: the agent creates the sentinel as part of Step 7, after the user
# has already confirmed local testing at Step 5 and approved the commit
# message at Step 6. The gate is satisfied in the normal /ship flow.
#
# Outside /ship: the gate fires whenever the agent tries to commit mid-task
# without the user's explicit go-ahead.

if [[ "$TOOL" == "Bash" ]]; then
  BASH_CMD=$(printf '%s' "$INPUT" | python3 -c '
import json, sys
data = json.load(sys.stdin)
tool_input = data.get("tool_input", data)
command = tool_input.get("command") if isinstance(tool_input, dict) else None
if not isinstance(command, str): raise SystemExit(1)
print(command, end="")
') || fail_closed "Bash tool input has no command."

  # ── Gate git commit on sentinel file ───────────────────────────────────
  COMMIT_OK="$RIG_DIR/memory/.rig-commit-ok"
  COMMIT_OK_TTL_SECONDS="${RIG_COMMIT_OK_TTL_SECONDS:-900}"
  if echo "$BASH_CMD" | grep -qE '\bgit\s+commit\b'; then
    if [[ ! -f "$COMMIT_OK" ]]; then
      echo "" >&2
      echo "  Commit blocked by The Rig." >&2
      echo "" >&2
      echo "  I need your go-ahead before I commit. Here's how it works:" >&2
      echo "    1. Test the changes in your terminal" >&2
      echo "    2. Say one of: 'commit approved' · 'ship it' · 'lgtm' · 'go'" >&2
      echo "       I'll create the authorization and immediately commit and push." >&2
      echo "" >&2
      echo "  (Or create it yourself: touch '${COMMIT_OK}')" >&2
      exit 2
    fi

    COMMIT_OK_AGE=""
    if COMMIT_OK_AGE=$(commit_ok_age_seconds "$COMMIT_OK"); then
      :
    else
      rm -f "$COMMIT_OK" 2>/dev/null || true
      echo "" >&2
      echo "  Commit blocked by The Rig." >&2
      echo "" >&2
      echo "  The commit authorization could not be verified and was cleared." >&2
      echo "  Ask for commit approval again, then recreate:" >&2
      echo "    touch '${COMMIT_OK}'" >&2
      exit 2
    fi

    case "$COMMIT_OK_TTL_SECONDS:$COMMIT_OK_AGE" in
      *[!0-9:]*|:*)
        rm -f "$COMMIT_OK" 2>/dev/null || true
        echo "" >&2
        echo "  Commit blocked by The Rig." >&2
        echo "" >&2
        echo "  The commit authorization expiry setting is invalid and was cleared." >&2
        echo "  Set RIG_COMMIT_OK_TTL_SECONDS to a positive number, or unset it." >&2
        exit 2
        ;;
    esac

    if [[ "$COMMIT_OK_AGE" -gt "$COMMIT_OK_TTL_SECONDS" ]]; then
      rm -f "$COMMIT_OK" 2>/dev/null || true
      echo "" >&2
      echo "  Commit blocked by The Rig." >&2
      echo "" >&2
      echo "  The commit authorization is stale (${COMMIT_OK_AGE}s old; limit ${COMMIT_OK_TTL_SECONDS}s) and was cleared." >&2
      echo "  Re-run the ship approval step or ask for commit approval again." >&2
      exit 2
    fi

    # ── Guard: block commits directly to main/master ──────────────────────
    # Exception: projects that set 'housekeeping: direct-push' in CLAUDE.md
    # allow chore(memory), chore(release), chore(post-merge), and similar
    # housekeeping commits directly to main. Code-change types (feat, fix,
    # refactor, test, perf, devops, style) are always blocked, even with
    # direct-push — they must go through a feature branch and PR.
    CURRENT_BRANCH=$(git -C "$REPO" branch --show-current 2>/dev/null || echo "")
    if [[ "$CURRENT_BRANCH" == "main" || "$CURRENT_BRANCH" == "master" ]]; then
      HOUSEKEEPING=$(grep "^housekeeping:" "$REPO/CLAUDE.md" 2>/dev/null \
        | awk '{print $2}' | tr -d '[:space:]' || echo "")
      if [[ "$HOUSEKEEPING" != "direct-push" ]]; then
        echo "" >&2
        echo "  Commit to '$CURRENT_BRANCH' blocked by The Rig." >&2
        echo "" >&2
        echo "  Committing directly to '$CURRENT_BRANCH' is not allowed." >&2
        echo "  Create a feature branch first:" >&2
        echo "    git checkout -b feat/your-description" >&2
        echo "" >&2
        echo "  To allow direct housekeeping commits, set in CLAUDE.md:" >&2
        echo "    housekeeping: direct-push" >&2
        exit 2
      fi

      # direct-push is set — still restrict to housekeeping commit types.
      # Code-change types must go through a branch and PR regardless.
      DIRECT_COMMIT_TYPE=""
      if command -v python3 >/dev/null 2>&1; then
        DIRECT_COMMIT_TYPE=$(echo "$BASH_CMD" | python3 -c "
import re, sys
cmd = sys.stdin.read()
m = re.search(r\"'EOF'\\s*\\n\\s*(\\S[^\\n]*)\", cmd)
if not m:
    m = re.search(r'-m\\s+\"([^\"]+)\"', cmd)
if not m:
    m = re.search(r\"-m\\s+'([^']+)'\", cmd)
if m:
    first_line = m.group(1).strip()
    tm = re.match(r'^([a-z]+)[\(:]', first_line)
    if tm:
        print(tm.group(1))
" 2>/dev/null || true)
      else
        DIRECT_COMMIT_TYPE=$(echo "$BASH_CMD" | grep -o '"[a-z]*(' | tr -d '"(' | head -1 || true)
      fi

      CODE_TYPES="^(feat|fix|refactor|test|perf|devops|style)$"
      if [[ -n "$DIRECT_COMMIT_TYPE" ]] && echo "$DIRECT_COMMIT_TYPE" | grep -qE "$CODE_TYPES"; then
        echo "" >&2
        echo "  Direct-to-main commit blocked by The Rig." >&2
        echo "" >&2
        echo "  'housekeeping: direct-push' only allows chore and docs commits" >&2
        echo "  directly to main. A '$DIRECT_COMMIT_TYPE(...)' commit requires a PR:" >&2
        echo "    git checkout -b $DIRECT_COMMIT_TYPE/your-description" >&2
        exit 2
      fi
    fi
  fi
fi

# ── Block writes to protected paths ──────────────────────────────────────────
if [[ "$TOOL" == "Write" || "$TOOL" == "Edit" || "$TOOL" == "NotebookEdit" ]]; then

  # The Codex adapter has already checked every apply_patch target against the
  # shared protected-path policy. It then passes a command, not a file_path.
  if [[ "${RIG_CODEX_PATCH_VALIDATED:-0}" == 1 ]]; then
    [[ "${RIG_AGENT:-}" == codex && "$TOOL" == Write ]] || fail_closed "invalid Codex patch validation context."
    exit 0
  fi

  PATH_ARG=$(printf '%s' "$INPUT" | python3 -c '
import json, sys
data = json.load(sys.stdin)
tool_input = data.get("tool_input", data)
if not isinstance(tool_input, dict): raise SystemExit(1)
path = tool_input.get("file_path") or tool_input.get("notebook_path")
if not isinstance(path, str) or not path: raise SystemExit(1)
print(path, end="")
') || fail_closed "write tool input has no file path."

  # ── Worktree write redirect ───────────────────────────────────────────────
  # Determine the destination now, but run every path policy against that
  # destination before returning updatedInput to the provider.
  REDIRECT_ORIGINAL=""
  if [[ "$PATH_ARG" == *"/.claude/worktrees/"* ]]; then
    REDIRECT_ORIGINAL="$PATH_ARG"
    PATH_ARG=$(printf '%s' "$PATH_ARG" | python3 -c '
import re, sys
path = sys.stdin.read()
match = re.match(r"^(.*)/\.claude/worktrees/[^/]+(/.*|$)", path)
if not match: raise SystemExit(1)
print(match.group(1) + (match.group(2) or "/"), end="")
') || fail_closed "worktree write destination could not be resolved."
  fi
  PATH_CANONICAL=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$PATH_ARG") || fail_closed "write path could not be resolved."

  # ── THE RIG'S OWN GOVERNANCE FILES (self-protection) ─────────────────────
  # The agent must not rewrite the rules it is supposed to follow.
  # These paths are protected unconditionally — even after a /rig-propose approval.
  #
  # APPROVED CHANGE FLOW:
  #   1. Run /rig-propose — agent writes proposal to /tmp/rig-proposal-[name].md
  #      and shows the exact before/after diff.
  #   2. Review and approve the proposal in chat.
  #   3. The agent cannot apply the change itself (this block stops it).
  #      Apply it one of two ways:
  #      (a) Copy the diff from the proposal and paste it manually into the file.
  #      (b) Open the file in your editor and apply the change.
  #
  # This is intentional. The governance system protects itself even during
  # approved changes — the human is always the one who applies them.
  #
  # Uses absolute paths so the block works whether .rig/ is inside the repo
  # or at an external location (see .rigpath / install.sh --rig-dir).
  PROTECTED_PATH_POLICY="$RIG_DIR/rules/protected-paths.txt"
  if [[ ! -r "$PROTECTED_PATH_POLICY" ]]; then
    echo "Blocked: The Rig protected-path policy is missing or unreadable:" >&2
    echo "  $PROTECTED_PATH_POLICY" >&2
    echo "Restore it with The Rig installer before attempting writes." >&2
    exit 2
  fi

  RIG_PROTECTED=()
  while IFS= read -r protected || [[ -n "$protected" ]]; do
    # Allow comments and whitespace-only lines, but keep path fragments literal.
    [[ "$protected" =~ ^[[:space:]]*$ || "$protected" =~ ^[[:space:]]*# ]] && continue
    case "$protected" in
      '[RIG_DIR]/'*) protected="$RIG_DIR/${protected#\[RIG_DIR\]/}" ;;
      '[REPO]/'*)    protected="$REPO/${protected#\[REPO\]/}" ;;
      *)
        echo "Blocked: The Rig protected-path policy is malformed:" >&2
        echo "  $PROTECTED_PATH_POLICY" >&2
        echo "Every path must begin with [RIG_DIR]/ or [REPO]/." >&2
        exit 2
        ;;
    esac
    RIG_PROTECTED+=("$protected")
  done < "$PROTECTED_PATH_POLICY"

  if [[ "${#RIG_PROTECTED[@]}" -eq 0 ]]; then
    echo "Blocked: The Rig protected-path policy contains no paths:" >&2
    echo "  $PROTECTED_PATH_POLICY" >&2
    exit 2
  fi

  for protected in "${RIG_PROTECTED[@]}"; do
    protected_canonical=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$protected") || fail_closed "protected path could not be resolved."
    if [[ "$PATH_ARG" == *"$protected"* || "$PATH_CANONICAL" == "$protected_canonical" || "$PATH_CANONICAL" == "$protected_canonical/"* ]]; then
      echo "Blocked: '$PATH_ARG' is a The Rig governance file." >&2
      echo "The agent must not modify its own rules directly." >&2
      echo "Use /rig-propose to stage a change for human review, or edit manually." >&2
      exit 2
    fi
  done

  # ── PROJECT-SPECIFIC PROTECTED PATHS ─────────────────────────────────────
  # Add paths that should never be written by the agent in this project.
  # Substring matching — any file path containing the string will be blocked.
  # Examples:
  #   ".env.production"   — production environment file
  #   "migrations/"       — database migrations (run manually, not by agent)
  #   "data/approved/"    — curated data files managed by humans
  BLOCKED_PATHS=(
    ".env.production"
    # "migrations/"
    # "data/approved/"
  )

  for blocked in "${BLOCKED_PATHS[@]}"; do
    if [[ "$PATH_ARG" == *"$blocked"* || "$PATH_CANONICAL" == *"$blocked"* ]]; then
      echo "Blocked: '$PATH_ARG' matches protected path '$blocked'" >&2
      echo "This path is off-limits. Edit it manually if a change is truly needed." >&2
      exit 2
    fi
  done

  if [[ -n "$REDIRECT_ORIGINAL" ]]; then
    REDIRECTED_INPUT=$(printf '%s' "$INPUT" | python3 -c '
import json,sys
data=json.load(sys.stdin)
tool_input=data.get("tool_input",data)
path_key="file_path" if "file_path" in tool_input else "notebook_path"
tool_input[path_key]=sys.argv[1]
if "tool_input" in data:
    print(json.dumps({"hookSpecificOutput":{"hookEventName":"PreToolUse","updatedInput":tool_input}}))
else:
    print(json.dumps({"updatedToolInput":tool_input}))
' "$PATH_ARG") || fail_closed "worktree write could not be redirected."
    printf '%s\n' "$REDIRECTED_INPUT"
    echo "Redirected write from worktree path to main repo: $PATH_ARG" >&2
  fi
fi

exit 0
