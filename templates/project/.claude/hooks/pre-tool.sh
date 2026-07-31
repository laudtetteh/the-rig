#!/bin/bash
# pre-tool.sh
#
# Runs before Claude Code executes any tool.
# Exit 0 to allow the tool call. Exit 1 to block it (stderr is shown to Claude).
#
# Claude Code passes:
#   $1  — tool name (PascalCase: Write, Edit, Bash, Read, Glob, Grep, etc.)
#   stdin — tool input as JSON
#
# IMPORTANT: Tool names are PascalCase. Using snake_case (write_file, edit_file)
# will cause this script to silently never block anything. This was a real bug
# in production for 30+ PRs before it was caught.

TOOL="$1"
INPUT=$(cat)

# ── Repo root — dynamic, never hardcoded ─────────────────────────────────────
REPO=$(git rev-parse --show-toplevel 2>/dev/null)
if [[ -z "$REPO" ]]; then
  exit 0  # Not in a git repo, nothing to do
fi

# ── Resolve RIG_DIR ───────────────────────────────────────────────────────────
# Supports external .rig/ installations (see install.sh --rig-dir).
# If .rigpath exists in the repo root, it contains the absolute path to the
# .rig/ directory (which may be outside the repo). Otherwise default to $REPO/.rig.
if [[ -f "$REPO/.rigpath" ]]; then
  RIG_DIR=$(tr -d '[:space:]' < "$REPO/.rigpath")
else
  RIG_DIR="$REPO/.rig"
fi

# ── Session log ──────────────────────────────────────────────────────────────
# Logs every tool call with a timestamp. Useful for debugging agent behaviour.
# Scoped per-project so concurrent sessions on different projects don't
# contaminate each other's commit counts. Override with RIG_SESSION_LOG env var.
SESSION_LOG="${RIG_SESSION_LOG:-/tmp/the-rig-session-$(basename "$REPO").log}"
echo "[$(date +%H:%M:%S)] PRE  $TOOL" >> "$SESSION_LOG"

# ── Guard: git commit and git push ───────────────────────────────────────────
#
# Prevents the agent from committing or pushing before the user has tested.
#
# git push  — blocked unconditionally. The user pushes from their own terminal
#             after local testing. This ensures nothing reaches the remote
#             until the user has validated the change.
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
  # Parse the command string from the JSON input.
  # python3 handles embedded quotes and escapes correctly; falls back to grep
  # on systems where python3 is absent so the guard is never silently disabled.
  if command -v python3 >/dev/null 2>&1; then
    BASH_CMD=$(python3 -c \
      "import json,sys; print(json.load(sys.stdin).get('command',''))" \
      <<< "$INPUT" 2>/dev/null || true)
  else
    BASH_CMD=$(echo "$INPUT" | grep -o '"command":"[^"]*"' | head -1 | cut -d'"' -f4)
  fi

  # ── Gate git commit on sentinel file ───────────────────────────────────
  COMMIT_OK="$RIG_DIR/memory/.rig-commit-ok"
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
      exit 1
    fi

    # ── Guard: block commits directly to main/master ──────────────────────
    # Exception: projects that set 'housekeeping: direct-push' in CLAUDE.md
    # allow chore(memory), chore(release), chore(post-merge), and similar
    # housekeeping commits directly to main. Code-change types (feat, fix,
    # refactor, test, perf, devops, style) are always blocked, even with
    # direct-push — they must go through a feature branch and PR.
    CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "")
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
        exit 1
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
        exit 1
      fi
    fi
  fi
fi

# ── Block writes to protected paths ──────────────────────────────────────────
if [[ "$TOOL" == "Write" || "$TOOL" == "Edit" || "$TOOL" == "NotebookEdit" ]]; then

  # Extract the target file path from the JSON input.
  # python3 handles embedded quotes and escapes correctly; falls back to grep
  # on systems where python3 is absent so write protection is never silently disabled.
  if command -v python3 >/dev/null 2>&1; then
    PATH_ARG=$(python3 -c \
      "import json,sys; print(json.load(sys.stdin).get('file_path',''))" \
      <<< "$INPUT" 2>/dev/null || true)
  else
    PATH_ARG=$(echo "$INPUT" | grep -o '"file_path":"[^"]*"' | head -1 | cut -d'"' -f4)
  fi

  # ── Worktree write redirect ───────────────────────────────────────────────
  # Hard rule #12: never write files inside .claude/worktrees/ — edits there
  # are invisible to the user's git client. Redirect to the main repo instead.
  if [[ "$PATH_ARG" == *"/.claude/worktrees/"* ]]; then
    REDIRECTED_PATH=""
    if command -v python3 >/dev/null 2>&1; then
      REDIRECTED_PATH=$(echo "$INPUT" | python3 -c "
import json, re, sys
data = json.load(sys.stdin)
path = data.get('file_path', '')
m = re.match(r'^(.*)/\.claude/worktrees/[^/]+(/.*|$)', path)
if not m:
    sys.exit(0)
new_path = m.group(1) + (m.group(2) if m.group(2) else '/')
data['file_path'] = new_path
import json as _j
print(_j.dumps({'updatedToolInput': data}))
sys.stderr.write('Redirected write from worktree path to main repo: ' + new_path + '\n')
" 2>/tmp/the-rig-worktree-redirect.tmp || true)
    fi
    if [[ -n "$REDIRECTED_PATH" ]]; then
      echo "$REDIRECTED_PATH"
      cat /tmp/the-rig-worktree-redirect.tmp >&2 2>/dev/null || true
      exit 0
    fi
  fi

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
    exit 1
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
        exit 1
        ;;
    esac
    RIG_PROTECTED+=("$protected")
  done < "$PROTECTED_PATH_POLICY"

  if [[ "${#RIG_PROTECTED[@]}" -eq 0 ]]; then
    echo "Blocked: The Rig protected-path policy contains no paths:" >&2
    echo "  $PROTECTED_PATH_POLICY" >&2
    exit 1
  fi

  for protected in "${RIG_PROTECTED[@]}"; do
    if [[ "$PATH_ARG" == *"$protected"* ]]; then
      echo "Blocked: '$PATH_ARG' is a The Rig governance file." >&2
      echo "The agent must not modify its own rules directly." >&2
      echo "Use /rig-propose to stage a change for human review, or edit manually." >&2
      exit 1
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
    if [[ "$PATH_ARG" == *"$blocked"* ]]; then
      echo "Blocked: '$PATH_ARG' matches protected path '$blocked'" >&2
      echo "This path is off-limits. Edit it manually if a change is truly needed." >&2
      exit 1
    fi
  done
fi

exit 0
