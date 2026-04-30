#!/bin/bash
# stop.sh
#
# Runs when Claude Code's agent finishes its final response (Stop event).
# Wired via .claude/settings.json under "Stop".
#
# This is a lightweight session-boundary marker — not a full snapshot.
#
# What it does:
#   1. Updates the date in the "Last updated:" line in CONTEXT_SNAPSHOT.md
#      (preserves the description — only the YYYY-MM-DD changes)
#   2. Appends a session-end comment to PROGRESS.md so the session naming
#      heuristic in /wrap and /post-merge knows where this session ends
#
# What it does NOT do:
#   - Write a full CONTEXT_SNAPSHOT (that's /wrap's job)
#   - Block or fail — exits 0 always
#
# Claude Code passes: stdin — stop event data as JSON (not used here)

REPO=$(git rev-parse --show-toplevel 2>/dev/null)
if [[ -z "$REPO" ]]; then
  exit 0
fi

# ── Resolve RIG_DIR ───────────────────────────────────────────────────────────
if [[ -f "$REPO/.rigpath" ]]; then
  RIG_DIR=$(tr -d '[:space:]' < "$REPO/.rigpath")
else
  RIG_DIR="$REPO/.rig"
fi

SNAPSHOT="$RIG_DIR/memory/CONTEXT_SNAPSHOT.md"
PROGRESS="$RIG_DIR/memory/PROGRESS.md"
SESSION_LOG="/tmp/the-rig-session.log"
NOW=$(date +%Y-%m-%d)
NOW_FULL=$(date "+%Y-%m-%d %H:%M")

# ── Update Last updated: date in CONTEXT_SNAPSHOT ────────────────────────────
# Only runs if the snapshot exists and has the "Last updated:" field written
# by /wrap. Preserves the session description — only the date is refreshed.
# This keeps the freshness signal accurate for the next session without
# requiring /wrap to have run in this session.
if [[ -f "$SNAPSHOT" ]] && grep -q "^\*\*Last updated:\*\*" "$SNAPSHOT" 2>/dev/null; then
  # Extract the description (everything after "YYYY-MM-DD — ")
  DESCRIPTION=$(grep "^\*\*Last updated:\*\*" "$SNAPSHOT" \
    | sed 's/\*\*Last updated:\*\* [0-9-]* — //')

  TMP=$(mktemp)
  sed "s|^\*\*Last updated:\*\*.*|\*\*Last updated:\*\* $NOW — $DESCRIPTION|" \
    "$SNAPSHOT" > "$TMP" && mv "$TMP" "$SNAPSHOT"

  echo "[$(date +%H:%M:%S)] STOP: updated Last updated: → $NOW in CONTEXT_SNAPSHOT" \
    >> "$SESSION_LOG"
fi

# ── Append session-end marker to PROGRESS.md ─────────────────────────────────
# A lightweight HTML comment that /wrap and /post-merge use as a boundary
# when collecting entries for session naming. Safe to parse, invisible in
# rendered Markdown.
# Skip if PROGRESS.md doesn't exist yet.
if [[ -f "$PROGRESS" ]]; then
  # Idempotent: don't append if the last non-blank line is already a marker
  LAST_MEANINGFUL=$(grep -v '^[[:space:]]*$' "$PROGRESS" | tail -1)
  if [[ "$LAST_MEANINGFUL" != "<!-- session-end"* ]]; then
    printf "\n<!-- session-end %s -->\n" "$NOW_FULL" >> "$PROGRESS"
    echo "[$(date +%H:%M:%S)] STOP: session-end marker appended ($NOW_FULL)" \
      >> "$SESSION_LOG"
  else
    echo "[$(date +%H:%M:%S)] STOP: session-end marker already present — skipped" \
      >> "$SESSION_LOG"
  fi
fi

exit 0
