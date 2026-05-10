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
#   3. Writes .wrap-needed if PROGRESS.md has unexpanded auto-stubs,
#      signalling that /wrap should be run before the next session starts
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
WRAP_NEEDED="$RIG_DIR/memory/.wrap-needed"
# Allow tests to inject a custom session log path via RIG_SESSION_LOG env var.
SESSION_LOG="${RIG_SESSION_LOG:-/tmp/the-rig-session.log}"
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

# ── Write .wrap-needed flag if unexpanded auto-stubs exist ────────────────────
# post-tool.sh auto-stubs PROGRESS.md after every git commit with a line:
#   "_Auto-logged by post-tool hook. Expand this entry during wrap-up._"
# /wrap expands those stubs and removes that marker text.
# If stubs are still present, /wrap hasn't run since the last commit.
# The next session will read this flag and prompt the user to run /wrap first.
if [[ -f "$PROGRESS" ]] && grep -q "Auto-logged by post-tool hook" "$PROGRESS"; then
  touch "$WRAP_NEEDED"
  echo "[$(date +%H:%M:%S)] STOP: .wrap-needed written (unexpanded stubs found)" \
    >> "$SESSION_LOG"
elif [[ ! -f "$SNAPSHOT" ]] && [[ -f "$PROGRESS" ]]; then
  # No snapshot at all — /wrap has never been run in this project
  touch "$WRAP_NEEDED"
  echo "[$(date +%H:%M:%S)] STOP: .wrap-needed written (no CONTEXT_SNAPSHOT.md)" \
    >> "$SESSION_LOG"
fi

# ── Write .wrap-needed if 2+ commits landed this session ──────────────────────
# Even if stubs are expanded, 2+ commits means enough context has accumulated
# to warrant capturing it. The session log records one "PROGRESS stub:" entry
# per commit (written by post-tool.sh). If the flag is already set from above,
# skip — no need to write it twice.
if [[ ! -f "$WRAP_NEEDED" ]]; then
  SESSION_COMMIT_COUNT=$(grep -c "PROGRESS stub:" "$SESSION_LOG" 2>/dev/null || echo 0)
  if [[ "$SESSION_COMMIT_COUNT" -ge 2 ]]; then
    touch "$WRAP_NEEDED"
    echo "[$(date +%H:%M:%S)] STOP: .wrap-needed written (${SESSION_COMMIT_COUNT} commits this session — wrap recommended)" \
      >> "$SESSION_LOG"
  fi
fi

# ── Write minimal checkpoint to CONTEXT_SNAPSHOT when .wrap-needed is set ────
# If /wrap hasn't run and the session had meaningful commits, write a minimal
# orientation block to CONTEXT_SNAPSHOT.md so the next session isn't flying blind.
# This is not a full /wrap — it just records branch, last commit, and active task.
# /wrap overwrites this with a complete snapshot; this is a safety net only.
if [[ -f "$WRAP_NEEDED" ]]; then
  _BRANCH=$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
  _COMMIT=$(git -C "$REPO" log -1 --format="%h %s" 2>/dev/null || echo "none")
  _ACTIVE_TASK=""
  _ACTIVE_DIR="$RIG_DIR/tasks/active"
  if [[ -d "$_ACTIVE_DIR" ]]; then
    _ACTIVE_TASK=$(ls "$_ACTIVE_DIR"/*.md 2>/dev/null | head -1 | xargs basename 2>/dev/null || true)
  fi

  {
    echo "# Context Snapshot — auto-checkpoint"
    echo ""
    echo "> This is a minimal checkpoint written by stop.sh — not a full /wrap snapshot."
    echo "> Run \`/wrap\` to replace this with a complete context snapshot."
    echo ""
    echo "**Last updated:** $NOW — auto-checkpoint (stop.sh)"
    echo "**Branch:** $_BRANCH"
    echo "**Last commit:** $_COMMIT"
    if [[ -n "$_ACTIVE_TASK" ]]; then
      echo "**Active task:** $_ACTIVE_TASK"
    fi
    echo ""
    echo "---"
    echo ""
    echo "## Status"
    echo ""
    echo "Session ended without running \`/wrap\`. Run \`/wrap\` at the start of the"
    echo "next session to capture full context before starting new work."
  } > "$SNAPSHOT"

  echo "[$(date +%H:%M:%S)] STOP: minimal checkpoint written to CONTEXT_SNAPSHOT.md" \
    >> "$SESSION_LOG"
fi

exit 0
