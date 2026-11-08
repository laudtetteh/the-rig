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
COMMON_GIT_DIR=$(git -C "$REPO" rev-parse --git-common-dir 2>/dev/null) || fail_closed "cannot resolve the project Git directory."
COMMON_GIT_DIR=$(python3 -c 'import os,sys; print(os.path.realpath(os.path.join(sys.argv[1],sys.argv[2])))' "$REPO" "$COMMON_GIT_DIR")

# Return the linked worktree containing a path, including a path whose final
# directories do not exist yet. A nested, unrelated Git repository is ignored.
same_project_root_for_path() {
  local path="$1" directory root common
  directory=$(python3 -c 'import os,sys; p=os.path.realpath(sys.argv[1]); print(p if os.path.isdir(p) else os.path.dirname(p))' "$path") || return 1
  while [[ ! -d "$directory" && "$directory" != / ]]; do
    directory=$(dirname "$directory")
  done
  root=$(git -C "$directory" rev-parse --show-toplevel 2>/dev/null) || return 1
  common=$(git -C "$directory" rev-parse --git-common-dir 2>/dev/null) || return 1
  common=$(python3 -c 'import os,sys; print(os.path.realpath(os.path.join(sys.argv[1],sys.argv[2])))' "$directory" "$common") || return 1
  [[ "$common" == "$COMMON_GIT_DIR" ]] || return 1
  printf '%s\n' "$root"
}

rig_dir_for_root() {
  local root="$1"
  if [[ -f "$root/.rigpath" ]]; then
    tr -d '[:space:]' < "$root/.rigpath"
  else
    printf '%s\n' "$root/.rig"
  fi
}

# ── Resolve RIG_DIR ───────────────────────────────────────────────────────────
# Supports external .rig/ installations (see install.sh --rig-dir).
# If .rigpath exists in the repo root, it contains the absolute path to the
# .rig/ directory (which may be outside the repo). Otherwise default to $REPO/.rig.
RIG_DIR=$(rig_dir_for_root "$REPO")

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

  # A plain Bash call need not be shell-parsed. In particular, opaque scripts
  # and heredoc bodies may contain quoting that shlex cannot interpret, while
  # the old hook allowed them when no Git commit was visible.
  VISIBLE_COMMIT=$(printf '%s' "$BASH_CMD" | python3 -c '
import re, sys
command = sys.stdin.read()
heredoc = re.compile(r"<<(-?)(?!<)\s*(?:\x27([A-Za-z_][A-Za-z_0-9]*)\x27|\"([A-Za-z_][A-Za-z_0-9]*)\"|([A-Za-z_][A-Za-z_0-9]*))")
visible = []
pending = []
for line in command.splitlines(keepends=True):
    if pending:
        delimiter, keep_body, strip_tabs = pending[0]
        content = line.rstrip("\r\n")
        if (content.lstrip("\t") if strip_tabs else content) == delimiter:
            pending.pop(0)
        elif keep_body:
            visible.append(line)
        continue
    visible.append(line)
    shell_heredoc = bool(re.search(r"\b(?:bash|sh)\b", line))
    for match in heredoc.finditer(line):
        pending.append((next(group for group in match.groups()[1:] if group), shell_heredoc, bool(match.group(1))))
command = "".join(visible)
pattern = r"\bgit(?:\s+(?:-C(?:\s+(?:\"[^\"]*\"|\x27[^\x27]*\x27|\S+)|\S+)|-c\s+\S+|--[A-Za-z0-9-]+))*\s+commit\b"
print(1 if re.search(pattern, command) else 0)
') || fail_closed "Bash command could not be inspected for commits."
  COMMIT_TARGETS=""
  if [[ "$VISIBLE_COMMIT" == 1 ]]; then
  # Track literal cd and git -C arguments, including scripts passed to
  # sh/bash -c. The event cwd is used when supplied; the process cwd is the
  # legacy fallback. Refuse visible commits with an unresolved target.
  COMMIT_TARGETS=$(printf '%s' "$INPUT" | python3 -c '
import json, os, shlex, sys
data = json.load(sys.stdin)
command = data.get("tool_input", data).get("command", "")
cwd = data.get("cwd") if isinstance(data.get("cwd"), str) else None
operators = (";", "&&", "||", "|", "&")

def resolve(base, value):
    if base is None or "$" in value or "`" in value:
        return None
    return os.path.abspath(os.path.join(base, os.path.expanduser(value)))

def inspect(script, current, depth=0):
    if depth > 8:
        raise ValueError("nested shell limit exceeded")
    lexer = shlex.shlex(script, posix=True, punctuation_chars=";&|")
    lexer.whitespace_split = True
    lexer.commenters = ""
    tokens = list(lexer)
    targets = []
    i = 0
    while i < len(tokens):
        token = tokens[i]
        if token == "cd":
            j = i + 1
            while j < len(tokens) and tokens[j] in ("-L", "-P", "--"):
                j += 1
            if j < len(tokens) and tokens[j] not in operators:
                current = resolve(current, tokens[j])
                i = j + 1
                continue
            current = os.path.expanduser("~")
        if os.path.basename(token) in ("sh", "bash"):
            j = i + 1
            has_script = False
            while j < len(tokens) and tokens[j].startswith("-"):
                flag = tokens[j]
                if flag == "--":
                    j += 1
                    break
                if not flag.startswith("--") and "c" in flag[1:]:
                    has_script = True
                j += 1
            if has_script:
                if j >= len(tokens) or tokens[j] in operators:
                    raise ValueError("shell script is missing")
                nested = tokens[j]
                if nested.startswith("$") or "`" in nested:
                    raise ValueError("shell script is dynamic")
                targets.extend(inspect(nested, current, depth + 1))
                i = j + 1
                continue
        if token == "git":
            target = current
            j = i + 1
            while j < len(tokens):
                option = tokens[j]
                if option == "-C" and j + 1 < len(tokens):
                    target = resolve(target, tokens[j + 1])
                    j += 2
                elif option.startswith("-C") and len(option) > 2:
                    target = resolve(target, option[2:])
                    j += 1
                elif option in ("-c", "--config-env") and j + 1 < len(tokens):
                    j += 2
                elif option in ("--no-pager", "--paginate", "--literal-pathspecs"):
                    j += 1
                else:
                    break
            if j < len(tokens) and tokens[j] == "commit":
                if target is None:
                    raise ValueError("commit target is dynamic")
                targets.append(target)
            i = j + 1
            continue
        i += 1
    return targets

try:
    for target in inspect(command, os.path.abspath(cwd or sys.argv[1])):
        print(target)
except ValueError:
    raise SystemExit(1)
' "$PWD") || fail_closed "Bash commit target could not be inspected."
  # Retain the old broad guard for nested shell strings such as
  # bash -c 'git commit ...', whose contents are one shell token here.
  if [[ -z "$COMMIT_TARGETS" ]] && echo "$BASH_CMD" | grep -qE '\bgit\s+commit\b'; then
    COMMIT_TARGETS=$(printf '%s' "$INPUT" | python3 -c '
import json, os, sys
data = json.load(sys.stdin)
cwd = data.get("cwd") if isinstance(data.get("cwd"), str) else None
print(os.path.abspath(cwd or sys.argv[1]))
' "$PWD") || fail_closed "Bash commit cwd could not be inspected."
  fi
  fi

  # ── Gate git commit on sentinel file ───────────────────────────────────
  COMMIT_OK_TTL_SECONDS="${RIG_COMMIT_OK_TTL_SECONDS:-900}"
  while IFS= read -r COMMIT_TARGET; do
    [[ -n "$COMMIT_TARGET" ]] || continue
    COMMIT_REPO=$(same_project_root_for_path "$COMMIT_TARGET/.") || COMMIT_REPO="$REPO"
    COMMIT_RIG_DIR=$(rig_dir_for_root "$COMMIT_REPO")
    COMMIT_OK="$COMMIT_RIG_DIR/memory/.rig-commit-ok"
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
    CURRENT_BRANCH=$(git -C "$COMMIT_REPO" branch --show-current 2>/dev/null || echo "")
    if [[ "$CURRENT_BRANCH" == "main" || "$CURRENT_BRANCH" == "master" ]]; then
      HOUSEKEEPING=$(grep "^housekeeping:" "$COMMIT_REPO/CLAUDE.md" 2>/dev/null \
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
  done <<< "$COMMIT_TARGETS"
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
import json, os, sys
data = json.load(sys.stdin)
tool_input = data.get("tool_input", data)
if not isinstance(tool_input, dict): raise SystemExit(1)
path = tool_input.get("file_path") or tool_input.get("notebook_path")
if not isinstance(path, str) or not path: raise SystemExit(1)
if not os.path.isabs(path):
    cwd = data.get("cwd") if isinstance(data.get("cwd"), str) else None
    path = os.path.abspath(os.path.join(cwd or os.getcwd(), path))
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
  TARGET_REPO=$(same_project_root_for_path "$PATH_ARG") || TARGET_REPO="$REPO"
  TARGET_RIG_DIR=$(rig_dir_for_root "$TARGET_REPO")

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
      '[RIG_DIR]/'*)
        RIG_PROTECTED+=("$RIG_DIR/${protected#\[RIG_DIR\]/}")
        [[ "$TARGET_RIG_DIR" == "$RIG_DIR" ]] || RIG_PROTECTED+=("$TARGET_RIG_DIR/${protected#\[RIG_DIR\]/}")
        continue ;;
      '[REPO]/'*)
        RIG_PROTECTED+=("$REPO/${protected#\[REPO\]/}")
        [[ "$TARGET_REPO" == "$REPO" ]] || RIG_PROTECTED+=("$TARGET_REPO/${protected#\[REPO\]/}")
        continue ;;
      *)
        echo "Blocked: The Rig protected-path policy is malformed:" >&2
        echo "  $PROTECTED_PATH_POLICY" >&2
        echo "Every path must begin with [RIG_DIR]/ or [REPO]/." >&2
        exit 2
        ;;
    esac
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
