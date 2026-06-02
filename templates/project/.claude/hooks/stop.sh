#!/bin/bash
# stop.sh
#
# Runs after every Claude Code agent turn (Stop event).
# Lightweight per-turn session-boundary marker only.
#
# What it does:
#   1. Updates the date in the "Last updated:" line in CONTEXT_SNAPSHOT.md
#   2. Appends a session-end comment to PROGRESS.md (used by /wrap for naming)
#
# What it does NOT do:
#   - Write .wrap-needed — that's session-end.sh's job (fires on true termination)
#   - Write a full CONTEXT_SNAPSHOT — that's /wrap's job
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
# Scoped per-project to prevent cross-project commit count contamination.
# Override with RIG_SESSION_LOG env var (used in tests).
SESSION_LOG="${RIG_SESSION_LOG:-/tmp/the-rig-session-$(basename "$REPO").log}"
NOW_FULL=$(date "+%Y-%m-%d %H:%M")

# ── Update Last updated: date in CONTEXT_SNAPSHOT ────────────────────────────
# Only runs if the snapshot exists and has the "Last updated:" field written
# by /wrap. Preserves the session description — only the date is refreshed.
# This keeps the freshness signal accurate for the next session without
# requiring /wrap to have run in this session.
if [[ -f "$SNAPSHOT" ]] && grep -q "^\*\*Last updated:\*\*" "$SNAPSHOT" 2>/dev/null; then
  # Extract the description (everything after "YYYY-MM-DD[ HH:MM] — ").
  # Handles both old date-only and new datetime formats for backward compat.
  DESCRIPTION=$(grep "^\*\*Last updated:\*\*" "$SNAPSHOT" \
    | sed 's/\*\*Last updated:\*\*[^—]*— //')

  # Use awk instead of sed so that | characters in session names (e.g.
  # "fix auth #91 | feat dashboard #92") do not corrupt the replacement.
  TMP=$(mktemp)
  awk -v now="$NOW_FULL" -v desc="$DESCRIPTION" -v em="—" '
    /^\*\*Last updated:\*\*/ { print "**Last updated:** " now " " em " " desc; next }
    { print }
  ' "$SNAPSHOT" > "$TMP" && mv "$TMP" "$SNAPSHOT"

  echo "[$(date +%H:%M:%S)] STOP: updated Last updated: → $NOW_FULL in CONTEXT_SNAPSHOT" \
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
