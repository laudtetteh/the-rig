#!/usr/bin/env bash
# Translate Codex hook payloads to The Rig's canonical Claude hook scripts.

set -u

INPUT=$(cat)

fail_closed() {
  echo "Blocked: $1" >&2
  exit 2
}

command -v python3 >/dev/null 2>&1 || fail_closed "python3 is required by the Codex hook adapter."
REPO=$(git rev-parse --show-toplevel 2>/dev/null) || fail_closed "cannot resolve the project root."
[[ -n "$REPO" ]] || fail_closed "cannot resolve the project root."

if [[ -f "$REPO/.rigpath" ]]; then
  IFS= read -r RIG_DIR < "$REPO/.rigpath"
  RIG_DIR="${RIG_DIR%$'\r'}"
  [[ "$RIG_DIR" == /* ]] || fail_closed ".rigpath must contain an absolute path."
else
  RIG_DIR="$REPO/.rig"
fi

MANIFEST="$RIG_DIR/memory/.rig-manifest"
[[ -r "$MANIFEST" ]] || fail_closed "project identity manifest is missing or unreadable."
/usr/bin/grep -Eq '^[[:xdigit:]]+[[:space:]]+\.rig/rules/protected-paths\.txt$' "$MANIFEST" || \
  fail_closed "project identity manifest does not own the protected-path policy."
EXPECTED_ADAPTER=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$REPO/.codex/hooks/rig-adapter.sh")
ACTUAL_ADAPTER=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$0")
[[ "$ACTUAL_ADAPTER" == "$EXPECTED_ADAPTER" ]] || fail_closed "Codex adapter path does not match this project."

EVENT=$(printf '%s' "$INPUT" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    event = data.get("hook_event_name", data.get("hookEventName", ""))
    print(event if isinstance(event, str) else "")
except Exception:
    pass
')
[[ -n "$EVENT" ]] || fail_closed "hook payload is invalid or has no event name."

normalize_payload() {
  printf '%s' "$INPUT" | python3 -c '
import json, sys
d = json.load(sys.stdin)
aliases = {
    "hookEventName": "hook_event_name", "toolName": "tool_name",
    "toolInput": "tool_input", "toolResponse": "tool_response",
    "agentType": "agent_type", "agentId": "agent_id",
    "lastAssistantMessage": "last_assistant_message",
    "stopHookActive": "stop_hook_active",
}
for old, new in aliases.items():
    if new not in d and old in d: d[new] = d[old]
event = d.get("hook_event_name", "")
if event == "SessionEnd": d["source"] = "logout"
if event in ("PreCompact", "PostCompact") and "trigger" in d:
    d["source"] = "compact"
print(json.dumps(d))
'
}

translate_output() {
  local event="$1" output="$2"
  [[ -z "$output" ]] && return 0
  printf '%s' "$output" | python3 -c '
import json, sys
event = sys.argv[1]
raw = sys.stdin.read()
try:
    data = json.loads(raw)
except Exception:
    print(raw, end="")
    raise SystemExit
if event == "UserPromptSubmit" and isinstance(data.get("additionalContext"), str):
    context = data.pop("additionalContext")
    data["hookSpecificOutput"] = {
        "hookEventName": "UserPromptSubmit", "additionalContext": context
    }
print(json.dumps(data))
' "$event"
}

validate_protected_policy() {
  local policy="$RIG_DIR/rules/protected-paths.txt" line expanded count=0
  [[ -r "$policy" ]] || fail_closed "The Rig protected-path policy is missing or unreadable: $policy"
  PROTECTED_PATHS=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]] && continue
    case "$line" in
      '[RIG_DIR]/'*) expanded="$RIG_DIR/${line#\[RIG_DIR\]/}" ;;
      '[REPO]/'*) expanded="$REPO/${line#\[REPO\]/}" ;;
      *) fail_closed "The Rig protected-path policy is malformed: $policy" ;;
    esac
    expanded=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$expanded")
    PROTECTED_PATHS+=("$expanded")
    count=$((count + 1))
  done < "$policy"
  [[ "$count" -gt 0 ]] || fail_closed "The Rig protected-path policy contains no paths: $policy"
}

validate_apply_patch() {
  validate_protected_policy
  local paths path protected found=0
  paths=$(printf '%s' "$INPUT" | python3 -c '
import json, os, re, sys
d = json.load(sys.stdin)
tool = d.get("tool_input", d.get("toolInput", {}))
command = tool.get("command", "") if isinstance(tool, dict) else ""
for value in re.findall(r"^\*\*\* (?:(?:Add|Update|Delete) File|Move to): (.+)$", command, re.M):
    path = value if os.path.isabs(value) else os.path.join(sys.argv[1], value)
    print(os.path.realpath(path))
' "$REPO") || fail_closed "apply_patch payload is malformed."
  [[ -n "$paths" ]] || fail_closed "apply_patch payload contains no file targets."
  while IFS= read -r path; do
    found=1
    for protected in "${PROTECTED_PATHS[@]}"; do
      if [[ "$path" == "$protected" || "$path" == "$protected/"* ]]; then
        fail_closed "'$path' is a The Rig governance file."
      fi
    done
  done <<< "$paths"
  [[ "$found" -eq 1 ]] || fail_closed "apply_patch payload contains no file targets."
}

PAYLOAD=$(normalize_payload) || fail_closed "hook payload could not be normalized."
TOOL=$(printf '%s' "$PAYLOAD" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("tool_name", ""))')
HOOK_PAYLOAD="$PAYLOAD"

# Claude's PreToolUse hook receives the tool input object directly, while Codex
# wraps that object in its event envelope. Delegate the equivalent shape so the
# canonical hook sees the same command/file fields on both agent paths.
if [[ "$EVENT" == "PreToolUse" ]]; then
  HOOK_PAYLOAD=$(printf '%s' "$PAYLOAD" | python3 -c '
import json, sys
data = json.load(sys.stdin)
tool_input = data.get("tool_input", {})
if not isinstance(tool_input, dict):
    raise SystemExit(1)
print(json.dumps(tool_input))
') || fail_closed "PreToolUse payload has invalid tool input."
fi

if [[ "$EVENT" == "PreToolUse" && "$TOOL" == "apply_patch" ]]; then
  validate_apply_patch
fi

HOOK_DIR="$REPO/.claude/hooks"
notify_event() {
  [[ -x "$HOME/.claude/bin/rig-notify" ]] || return 0
  "$HOME/.claude/bin/rig-notify" "$1" >/dev/null 2>&1 || true
}
case "$EVENT" in
  PreToolUse)
    [[ "$TOOL" == "apply_patch" ]] && TOOL="Write"
    HOOK="$HOOK_DIR/pre-tool.sh" ;;
  PermissionRequest) notify_event permission-request; HOOK="$HOOK_DIR/permission-request.sh" ;;
  PostToolUse) HOOK="$HOOK_DIR/post-tool.sh" ;;
  PreCompact) HOOK="$HOOK_DIR/pre-compact.sh" ;;
  PostCompact) HOOK="$HOOK_DIR/post-compact.sh" ;;
  UserPromptSubmit) HOOK="$HOOK_DIR/prompt-submit.sh" ;;
  SessionStart) HOOK="$HOOK_DIR/session-start.sh" ;;
  SessionEnd|Stop) [[ "$EVENT" == Stop ]] && notify_event stop; HOOK="$HOOK_DIR/stop.sh" ;;
  SubagentStart) HOOK="$HOOK_DIR/subagent-start.sh" ;;
  # The Rig has no canonical Claude SubagentStop hook. Keep this event distinct
  # from root Stop and return valid neutral JSON so the subagent may finish.
  SubagentStop) notify_event subagent-stop; printf '{}\n'; exit 0 ;;
  *) fail_closed "unsupported Codex hook event: $EVENT" ;;
esac

[[ -r "$HOOK" ]] || fail_closed "canonical hook is missing or unreadable: $HOOK"
if [[ "$EVENT" == "PreToolUse" || "$EVENT" == "PostToolUse" ]]; then
  OUTPUT=$(printf '%s' "$HOOK_PAYLOAD" | RIG_AGENT=codex bash "$HOOK" "$TOOL"); STATUS=$?
else
  OUTPUT=$(printf '%s' "$PAYLOAD" | RIG_AGENT=codex bash "$HOOK"); STATUS=$?
fi
[[ "$STATUS" -eq 0 ]] || exit "$STATUS"
translate_output "$EVENT" "$OUTPUT"
