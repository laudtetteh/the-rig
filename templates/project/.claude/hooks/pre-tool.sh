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

# Only the hookless fallback consumes approval here. Active Rig Git hooks
# validate expiry and claim approval at commit time instead.
commit_ok_age_seconds() {
  local file="$1" now mtime
  now=$(date +%s 2>/dev/null) || return 1
  mtime=$(stat -c %Y "$file" 2>/dev/null || stat -f %m "$file" 2>/dev/null) || return 1
  case "$now:$mtime" in *[!0-9:]*|:*) return 1 ;; esac
  printf '%s\n' "$((now - mtime))"
}

# ── Session log ──────────────────────────────────────────────────────────────
# Logs every tool call with a timestamp. Useful for debugging agent behaviour.
# Scoped per-project so concurrent sessions on different projects don't
# contaminate each other's commit counts. Override with RIG_SESSION_LOG env var.
SESSION_LOG="${RIG_SESSION_LOG:-/tmp/the-rig-session-$(basename "$REPO").log}"
echo "[$(date +%H:%M:%S)] PRE  $TOOL" >> "$SESSION_LOG"

# The early Bash gate rejects visible unmarked commits before execution. It is
# a heuristic over shell text; generated scripts and shell escapes can evade it.
# The Git hook is authoritative for explicitly marked subprocesses.
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
    # A filename such as example.sh does not execute its heredoc body. A
    # shell command or eval can, including when it appears after a pipe.
    shell_heredoc = bool(re.search(r"(?<![A-Za-z0-9_.-])(?:bash|sh|eval)(?=\s|[;<|&()]|$)", line))
    for match in heredoc.finditer(line):
        # An unquoted heredoc expands command substitutions even when the
        # receiving command is cat. Inspect its body conservatively.
        pending.append((next(group for group in match.groups()[1:] if group), shell_heredoc or bool(match.group(4)), bool(match.group(1))))
command = "".join(visible)
# Shell backslash escaping can spell the Git binary as g\it.
command = re.sub(r"\\([A-Za-z])", r"\1", command)
pattern = r"\bgit(?:\s+(?:-C(?:\s+(?:\"[^\"]*\"|\x27[^\x27]*\x27|\S+)|\S+)|-c\s+\S+|--[A-Za-z0-9-]+))*\s+commit\b"
matches = list(re.finditer(pattern, command))
if not matches:
    print(0)
elif len(matches) != 1:
    print(2)
else:
    prefix = command[:matches[0].start()]
    print(1 if re.search(r"RIG_COMMIT_POLICY=guarded[ \t]+$", prefix) else 2)
') || fail_closed "Bash command could not be inspected for commits."
  if [[ "$VISIBLE_COMMIT" == 2 ]]; then
    fail_closed "Commit blocked by The Rig. Use one RIG_COMMIT_POLICY=guarded git commit after approval; the active Rig guard consumes the target worktree's one-use approval."
  fi
  if [[ "$VISIBLE_COMMIT" == 1 ]]; then
    BASH_CMD_LOWER=$(printf '%s' "$BASH_CMD" | tr '[:upper:]' '[:lower:]') || \
      fail_closed "Bash command could not be normalized."
    if [[ "$BASH_CMD" =~ (^|[[:space:]])(--no-verify|-n)([[:space:]]|$) ]] || \
       [[ "$BASH_CMD_LOWER" == *core.hookspath* || "$BASH_CMD" == *HUSKY=0* || "${HUSKY:-}" == 0 ]]; then
      fail_closed "Commit blocked by The Rig. This command disables the Git commit-msg hook."
    fi
    # Literal environment overrides can redirect Git after a static -C/cd
    # resolution. Run such commands from the target worktree directly.
    if [[ "$BASH_CMD" == *GIT_DIR=* || "$BASH_CMD" == *GIT_WORK_TREE=* ]]; then
      fail_closed "Git environment overrides make the visible commit target uncertain. Run from the target worktree."
    fi
  # Track literal cd and git -C arguments, including scripts passed to
  # sh/bash -c. The event cwd is used when supplied; the process cwd is the
  # legacy fallback. Refuse visible commits with an unresolved target.
  COMMIT_TARGETS=$(printf '%s' "$INPUT" | python3 -c '
import json, os, re, shlex, sys
data = json.load(sys.stdin)
command = data.get("tool_input", data).get("command", "")
cwd = data.get("cwd") if isinstance(data.get("cwd"), str) else None
operators = (";", "&&", "||", "|", "&", "(", ")")

def resolve(base, value):
    if base is None or "$" in value or "`" in value:
        return None
    return os.path.abspath(os.path.join(base, os.path.expanduser(value)))

def subject_from_file(base, value):
    path = resolve(base, value)
    if path is None:
        return ""
    try:
        with open(path, encoding="utf-8") as handle:
            return handle.readline().strip()
    except (OSError, UnicodeError):
        return ""

def inspect(script, current, depth=0):
    if depth > 8:
        raise ValueError("nested shell limit exceeded")
    lexer = shlex.shlex(script, posix=True, punctuation_chars=";&|()")
    lexer.whitespace_split = True
    lexer.commenters = ""
    # shlex groups adjacent punctuation (for example ");"). Split it into
    # shell operators so a subshell cannot leak its cd into the parent.
    tokens = []
    for token in lexer:
        tokens.extend(re.findall(r"&&|\|\||[;&|()]", token) if re.fullmatch(r"[;&|()]+", token) else [token])
    targets = []
    scopes = []
    command_base = current
    pipeline_base = None
    i = 0
    while i < len(tokens):
        token = tokens[i]
        if token == "(":
            scopes.append((current, command_base, pipeline_base))
            command_base = current
            pipeline_base = None
            i += 1
            continue
        if token == ")":
            if not scopes:
                raise ValueError("unbalanced subshell")
            current, command_base, pipeline_base = scopes.pop()
            i += 1
            continue
        if token == "|":
            if pipeline_base is None:
                pipeline_base = command_base
            current = pipeline_base
            command_base = current
            i += 1
            continue
        if token in (";", "&&", "||", "&"):
            if pipeline_base is not None:
                current = pipeline_base
                pipeline_base = None
            elif token == "&":
                current = command_base
            elif token == "||" and current != command_base:
                # The fallback runs only when the preceding cd failed.
                current = None
            command_base = current
            i += 1
            continue
        if token == "cd":
            j = i + 1
            while j < len(tokens) and tokens[j] in ("-L", "-P", "--"):
                j += 1
            if j < len(tokens) and tokens[j] not in operators:
                # cd - depends on OLDPWD and may return to another worktree.
                current = None if tokens[j] == "-" else resolve(current, tokens[j])
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
        if token == "git" or (token.startswith("/") and os.path.basename(token) == "git"):
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
                subject = ""
                k = j + 1
                while k < len(tokens) and tokens[k] not in operators:
                    option = tokens[k]
                    if option in ("-m", "--message") and k + 1 < len(tokens):
                        subject = tokens[k + 1].splitlines()[0].strip()
                        break
                    if option.startswith("--message="):
                        subject = option.split("=", 1)[1].splitlines()[0].strip()
                        break
                    if option.startswith("-m") and len(option) > 2:
                        subject = option[2:].splitlines()[0].strip()
                        break
                    if option in ("-F", "--file") and k + 1 < len(tokens):
                        subject = subject_from_file(target, tokens[k + 1])
                        break
                    if option.startswith("--file="):
                        subject = subject_from_file(target, option.split("=", 1)[1])
                        break
                    if option.startswith("-F") and len(option) > 2:
                        subject = subject_from_file(target, option[2:])
                        break
                    k += 1
                typed = re.match(r"^([a-z]+)(?:\(|:)", subject)
                targets.append((target, typed.group(1) if typed else ""))
            i = j + 1
            continue
        i += 1
    if scopes:
        raise ValueError("unbalanced subshell")
    return targets

try:
    for target, commit_type in inspect(command, os.path.abspath(cwd or sys.argv[1])):
        print(target + "\t" + commit_type)
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
print(os.path.abspath(cwd or sys.argv[1]) + "\t")
' "$PWD") || fail_closed "Bash commit cwd could not be inspected."
  fi

    COMMIT_COUNT=$(printf '%s\n' "$COMMIT_TARGETS" | awk 'NF {n++} END {print n+0}')
    [[ "$COMMIT_COUNT" -eq 1 ]] || fail_closed "marked commit target could not be verified."
    while IFS=$'\t' read -r COMMIT_TARGET DIRECT_COMMIT_TYPE; do
      [[ -n "$COMMIT_TARGET" ]] || continue
      COMMIT_REPO=$(same_project_root_for_path "$COMMIT_TARGET/.") || \
        fail_closed "commit target is outside the installed project or cannot be verified."
      COMMIT_RIG_DIR=$(rig_dir_for_root "$COMMIT_REPO")
      COMMIT_OK="$COMMIT_RIG_DIR/memory/.rig-commit-ok"
      [[ -f "$COMMIT_OK" ]] || fail_closed "Commit blocked by The Rig. Approval is missing: $COMMIT_OK"

      HOOKS_PATH=$(git -C "$COMMIT_REPO" config --get core.hooksPath 2>/dev/null || true)
      if [[ -z "$HOOKS_PATH" ]]; then
        HOOK_PATH=$(git -C "$COMMIT_REPO" rev-parse --git-path hooks/commit-msg 2>/dev/null) || \
          fail_closed "cannot resolve the target commit-msg hook."
      else
        HOOK_PATH="$HOOKS_PATH/commit-msg"
      fi
      if [[ "$HOOK_PATH" != /* ]]; then HOOK_PATH="$COMMIT_REPO/$HOOK_PATH"; fi
      if [[ -x "$HOOK_PATH" && -f "$HOOK_PATH" ]]; then
        # Run the capability argument in an isolated temporary cwd. A Git
        # commit supplies a prepared message file, never this argument. A
        # customized wrapper may still write to its cwd before delegating.
        PROBE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rig-policy-probe.XXXXXX") || \
          fail_closed "cannot create a temporary directory for the commit hook probe."
        HOOK_CAPABILITY=$(cd "$PROBE_DIR" && "$HOOK_PATH" --rig-policy-probe 2>/dev/null)
        PROBE_STATUS=$?
        rm -rf -- "$PROBE_DIR" || fail_closed "cannot clean up the commit hook probe."
        [[ "$PROBE_STATUS" -eq 0 ]] || \
          fail_closed "The target commit-msg hook does not support guarded commits: $HOOK_PATH"
        [[ "$HOOK_CAPABILITY" == rig-commit-policy-v1 ]] || \
          fail_closed "The target commit-msg hook does not support guarded commits: $HOOK_PATH"
        continue  # Git will claim approval and log final HEAD.
      fi

      # Supported --skip-git-hooks installs have no runtime guard. Preserve
      # the old visible-command gate, including its one-attempt claim. Opaque
      # scripts remain outside what PreToolUse can establish.
      COMMIT_OK_AGE=$(commit_ok_age_seconds "$COMMIT_OK") || {
        rm -f "$COMMIT_OK"
        fail_closed "commit authorization timestamp could not be verified; approval was cleared."
      }
      COMMIT_OK_TTL_SECONDS="${RIG_COMMIT_OK_TTL_SECONDS:-900}"
      if [[ "$COMMIT_OK_AGE" == -* ]]; then
        rm -f "$COMMIT_OK"
        fail_closed "commit authorization is stale; request fresh approval."
      fi
      case "$COMMIT_OK_TTL_SECONDS:$COMMIT_OK_AGE" in
        *[!0-9:]*|:*)
          rm -f "$COMMIT_OK"
          fail_closed "commit authorization expiry setting is invalid; approval was cleared."
          ;;
      esac
      if [[ "$COMMIT_OK_AGE" -gt "$COMMIT_OK_TTL_SECONDS" ]]; then
        rm -f "$COMMIT_OK"
        fail_closed "commit authorization is stale; request fresh approval."
      fi

      CURRENT_BRANCH=$(git -C "$COMMIT_REPO" branch --show-current 2>/dev/null) || \
        fail_closed "commit branch could not be verified."
      if [[ "$CURRENT_BRANCH" == main || "$CURRENT_BRANCH" == master ]]; then
        HOUSEKEEPING=$(sed -n 's/^housekeeping:[[:space:]]*\([^[:space:]#]*\).*/\1/p' "$COMMIT_REPO/CLAUDE.md" 2>/dev/null | head -1)
        [[ "$HOUSEKEEPING" == direct-push ]] || \
          fail_closed "Commit to '$CURRENT_BRANCH' blocked by The Rig; create a feature branch."
        [[ "$DIRECT_COMMIT_TYPE" == chore || "$DIRECT_COMMIT_TYPE" == docs ]] || \
          fail_closed "Direct-to-$CURRENT_BRANCH commit blocked; only chore/docs subjects are allowed."
      fi

      FALLBACK_ID=$(printf '%s' "$INPUT" | python3 -c '
import hashlib, json, sys
data = json.load(sys.stdin)
value = data.get("tool_use_id")
print(hashlib.sha256(value.encode()).hexdigest()[:16] if isinstance(value, str) and value else "legacy")
') || fail_closed "fallback event identity could not be read."
      FALLBACK_PENDING="$RIG_DIR/memory/.rig-commit-fallback-pending-$FALLBACK_ID"
      PREVIOUS_HEAD=$(git -C "$COMMIT_REPO" rev-parse HEAD 2>/dev/null || true)
      COMMIT_CLAIM="$COMMIT_OK.claimed-$$-$RANDOM"
      mv "$COMMIT_OK" "$COMMIT_CLAIM" 2>/dev/null || \
        fail_closed "commit authorization was already claimed; request fresh approval."
      rm -f "$COMMIT_CLAIM" || fail_closed "claimed commit authorization could not be removed."
      printf '%s\n%s\n%s\n' "$FALLBACK_ID" "$COMMIT_REPO" "$PREVIOUS_HEAD" > "$FALLBACK_PENDING.tmp-$$" || \
        fail_closed "fallback progress marker could not be written."
      mv "$FALLBACK_PENDING.tmp-$$" "$FALLBACK_PENDING" || \
        fail_closed "fallback progress marker could not be installed."
      echo "WARNING: No active Rig commit-msg hook; PreToolUse used the visible-command fallback." >&2
    done <<< "$COMMIT_TARGETS"
  fi
fi

# ── Block writes to protected paths ──────────────────────────────────────────
if [[ "$TOOL" == "Write" || "$TOOL" == "Edit" || "$TOOL" == "NotebookEdit" ]]; then

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
  RIG_PROTECTED=()
  load_protected_path_policy() {
    local policy="$1" policy_repo="$2" policy_rig_dir="$3" mirror_repo="$4" mirror_rig_dir="$5" protected
    local before="${#RIG_PROTECTED[@]}"
    if [[ ! -f "$policy" || ! -r "$policy" ]]; then
      echo "Blocked: The Rig protected-path policy is missing or unreadable:" >&2
      echo "  $policy" >&2
      echo "Restore it with The Rig installer before attempting writes." >&2
      exit 2
    fi

    while IFS= read -r protected || [[ -n "$protected" ]]; do
      # Allow comments and whitespace-only lines, but keep path fragments literal.
      [[ "$protected" =~ ^[[:space:]]*$ || "$protected" =~ ^[[:space:]]*# ]] && continue
      case "$protected" in
        '[RIG_DIR]/'*)
          RIG_PROTECTED+=("$policy_rig_dir/${protected#\[RIG_DIR\]/}")
          [[ "$mirror_rig_dir" == "$policy_rig_dir" ]] || RIG_PROTECTED+=("$mirror_rig_dir/${protected#\[RIG_DIR\]/}")
          ;;
        '[REPO]/'*)
          RIG_PROTECTED+=("$policy_repo/${protected#\[REPO\]/}")
          [[ "$mirror_repo" == "$policy_repo" ]] || RIG_PROTECTED+=("$mirror_repo/${protected#\[REPO\]/}")
          ;;
        *)
          echo "Blocked: The Rig protected-path policy is malformed:" >&2
          echo "  $policy" >&2
          echo "Every path must begin with [RIG_DIR]/ or [REPO]/." >&2
          exit 2
          ;;
      esac
    done < "$policy"

    if [[ "${#RIG_PROTECTED[@]}" -eq "$before" ]]; then
      echo "Blocked: The Rig protected-path policy contains no paths:" >&2
      echo "  $policy" >&2
      exit 2
    fi
  }

  # The installed hook keeps its policy across linked worktrees. The target
  # worktree may have a different policy; read it as well when its Rig
  # directory differs. Shared external .rigpath locations use one policy.
  load_protected_path_policy "$RIG_DIR/rules/protected-paths.txt" "$REPO" "$RIG_DIR" "$TARGET_REPO" "$TARGET_RIG_DIR"
  if [[ "$TARGET_RIG_DIR" != "$RIG_DIR" ]]; then
    load_protected_path_policy "$TARGET_RIG_DIR/rules/protected-paths.txt" "$TARGET_REPO" "$TARGET_RIG_DIR" "$TARGET_REPO" "$TARGET_RIG_DIR"
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
