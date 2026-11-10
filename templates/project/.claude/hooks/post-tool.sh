#!/bin/bash
# post-tool.sh
#
# Runs after Claude Code executes any tool.
# Wired via .claude/settings.json.
#
# Claude Code passes a PostToolUse event JSON with tool_name and tool_response.
# The Codex adapter may also pass a positional tool name for legacy callers.

TOOL="${1:-}"
RESULT=$(cat)
if [[ -z "$TOOL" ]]; then
  TOOL=$(printf '%s' "$RESULT" | python3 -c '
import json, sys
try:
    event = json.load(sys.stdin)
    if event.get("hook_event_name") != "PostToolUse": raise ValueError()
    name = event.get("tool_name")
    if not isinstance(name, str) or not name: raise ValueError()
    print(name)
except (ValueError, TypeError, AttributeError):
    raise SystemExit(1)
') || exit 0
fi

# Git's post-commit hook logs guarded commits when installed. For a visible
# commit in a hookless install, PreToolUse leaves one pending attempt here.
HOOK_ROOT=$(cd "$(dirname "$0")/../.." && pwd -P) || exit 0
REPO=$(git -C "$HOOK_ROOT" rev-parse --show-toplevel 2>/dev/null) || exit 0
[[ "$REPO" == "$HOOK_ROOT" ]] || exit 0
SESSION_LOG="${RIG_SESSION_LOG:-/tmp/the-rig-session-$(basename "$REPO").log}"
echo "[$(date +%H:%M:%S)] POST $TOOL" >> "$SESSION_LOG"

if [[ "$TOOL" == "Bash" ]]; then
  if [[ -f "$HOOK_ROOT/.rigpath" ]]; then
    IFS= read -r RIG_DIR < "$HOOK_ROOT/.rigpath"
  else
    RIG_DIR="$HOOK_ROOT/.rig"
  fi
  FALLBACK_ID=$(printf '%s' "$RESULT" | python3 -c '
import hashlib, json, sys
try:
    data = json.load(sys.stdin)
    value = data.get("tool_use_id")
    print(hashlib.sha256(value.encode()).hexdigest()[:16] if isinstance(value, str) and value else "legacy")
except (ValueError, TypeError, AttributeError):
    print("legacy")
') || exit 0
  FALLBACK_PENDING="$RIG_DIR/memory/.rig-commit-fallback-pending-$FALLBACK_ID"
  if [[ -f "$FALLBACK_PENDING" && "$(sed -n '1p' "$FALLBACK_PENDING")" == "$FALLBACK_ID" ]]; then
    FALLBACK_CLAIM="$FALLBACK_PENDING.claimed-$$-$RANDOM"
    if mv "$FALLBACK_PENDING" "$FALLBACK_CLAIM" 2>/dev/null; then
      TARGET_REPO=$(sed -n '2p' "$FALLBACK_CLAIM")
      PREVIOUS_HEAD=$(sed -n '3p' "$FALLBACK_CLAIM")
      rm -f "$FALLBACK_CLAIM"
      if [[ -n "$TARGET_REPO" ]]; then
        COMMIT_HASH=$(git -C "$TARGET_REPO" rev-parse HEAD 2>/dev/null || true)
        SHORT_HASH=$(git -C "$TARGET_REPO" rev-parse --short HEAD 2>/dev/null || true)
        if [[ -n "$COMMIT_HASH" && "$COMMIT_HASH" != "$PREVIOUS_HEAD" && -n "$SHORT_HASH" ]] && \
           printf '%s' "$RESULT" | grep -qE '\[[^]]+[[:space:]][a-f0-9]{7,}\]' && \
           printf '%s' "$RESULT" | grep -Fq "$SHORT_HASH"; then
          if [[ -f "$TARGET_REPO/.rigpath" ]]; then
            IFS= read -r TARGET_RIG_DIR < "$TARGET_REPO/.rigpath"
          else
            TARGET_RIG_DIR="$TARGET_REPO/.rig"
          fi
          PROGRESS_FILE="$TARGET_RIG_DIR/memory/PROGRESS.md"
          if [[ -f "$PROGRESS_FILE" ]] && ! grep -Fq "$COMMIT_HASH" "$PROGRESS_FILE"; then
            COMMIT_MSG=$(git -C "$TARGET_REPO" log -1 --format=%s 2>/dev/null || true)
            COMMIT_DATE=$(date +%Y-%m-%d)
            STUB="\n## $COMMIT_DATE — $COMMIT_MSG [$COMMIT_HASH]\n_Auto-logged by post-tool hook. Expand this entry during wrap-up._\n\n---"
            TMP_PROGRESS=$(mktemp) || exit 0
            if awk -v stub="$STUB" '/^---$/ && !done { print; printf "%s\n", stub; done=1; next } 1' \
              "$PROGRESS_FILE" > "$TMP_PROGRESS"; then
              mv "$TMP_PROGRESS" "$PROGRESS_FILE" || rm -f "$TMP_PROGRESS"
              echo "[$(date +%H:%M:%S)] PROGRESS fallback stub: $COMMIT_HASH" >> "$SESSION_LOG"
            else
              rm -f "$TMP_PROGRESS"
            fi
          fi
        fi
      fi
    fi
  fi

  # ── Branch naming convention check ───────────────────────────────────────
  # After any Bash call that creates a new branch, warn if the name doesn't
  # follow the project's naming conventions. Warning only — the branch already
  # exists at this point. Agent should relay the warning to the user.
  if echo "$RESULT" | grep -qE "Switched to a new branch '"; then
    BRANCH_NAME=$(echo "$RESULT" \
      | grep -oE "Switched to a new branch '[^']+'" \
      | sed "s/Switched to a new branch '//;s/'$//")
    VALID_BRANCH_PATTERN="^(feat|fix|chore|refactor|docs|test|perf|devops|style)/"
    if [[ -n "$BRANCH_NAME" ]] && ! echo "$BRANCH_NAME" | grep -qE "$VALID_BRANCH_PATTERN"; then
      echo "⚠️  Branch '$BRANCH_NAME' doesn't follow naming conventions."
      echo "   Expected prefix: feat/ fix/ chore/ refactor/ docs/ test/ perf/ devops/ style/"
      echo "   To rename: git branch -m '$BRANCH_NAME' '<type>/$BRANCH_NAME'"
      echo "[$(date +%H:%M:%S)] BRANCH-WARN: '$BRANCH_NAME' — non-conventional name" >> "$SESSION_LOG"
    fi
  fi
fi

exit 0
