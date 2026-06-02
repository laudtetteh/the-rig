#!/bin/bash
# post-tool.sh
#
# Runs after Claude Code executes any tool.
# Wired via .claude/settings.json.
#
# Claude Code passes:
#   $1  — tool name (PascalCase: Write, Edit, Bash, Read, Glob, Grep, etc.)
#   stdin — tool result as JSON

TOOL="$1"
RESULT=$(cat)

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

PROGRESS_FILE="$RIG_DIR/memory/PROGRESS.md"
SESSION_LOG="${RIG_SESSION_LOG:-/tmp/the-rig-session-$(basename "$REPO").log}"

# ── Session log ───────────────────────────────────────────────────────────────
echo "[$(date +%H:%M:%S)] POST $TOOL" >> "$SESSION_LOG"

# ── Auto-stub PROGRESS.md after git commits ───────────────────────────────────
# After any Bash tool call, check whether a new commit just landed.
# If so, append a dated stub entry to PROGRESS.md so the record exists even
# if Claude forgets to update it during wrap-up. Claude expands the stub later.
#
# Heuristic: git commit output always contains a short hash in brackets,
# e.g. "[feat/auth abc1234] feat(auth): add token validation [#12]"
if [[ "$TOOL" == "Bash" ]]; then

  if echo "$RESULT" | grep -qE '\[[a-f0-9]{7,}\]'; then
    COMMIT_MSG=$(git -C "$REPO" log -1 --format="%s" 2>/dev/null)
    COMMIT_HASH=$(git -C "$REPO" log -1 --format="%h" 2>/dev/null)
    COMMIT_DATE=$(date +%Y-%m-%d)

    if [[ -n "$COMMIT_MSG" && -n "$COMMIT_HASH" ]]; then

      # Only append if this hash isn't already logged (idempotent)
      if ! grep -q "$COMMIT_HASH" "$PROGRESS_FILE" 2>/dev/null; then

        STUB="\n## $COMMIT_DATE — $COMMIT_MSG [$COMMIT_HASH]\n_Auto-logged by post-tool hook. Expand this entry during wrap-up._\n\n---"

        # Insert after the first --- separator in PROGRESS.md
        TMP=$(mktemp)
        awk -v stub="$STUB" '/^---$/ && !done { print; printf "%s\n", stub; done=1; next } 1' \
          "$PROGRESS_FILE" > "$TMP" && mv "$TMP" "$PROGRESS_FILE"

        echo "[$(date +%H:%M:%S)] PROGRESS stub: $COMMIT_HASH $COMMIT_MSG" >> "$SESSION_LOG"
      fi

      # ── Clear commit-ok sentinel ────────────────────────────────────────
      # The sentinel (.rig-commit-ok) authorises a single commit.
      # Remove it immediately after the commit lands so the next commit
      # requires a fresh authorisation.
      COMMIT_OK="$RIG_DIR/memory/.rig-commit-ok"
      if [[ -f "$COMMIT_OK" ]]; then
        rm -f "$COMMIT_OK"
        echo "[$(date +%H:%M:%S)] COMMIT-OK sentinel cleared after $COMMIT_HASH" >> "$SESSION_LOG"
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
