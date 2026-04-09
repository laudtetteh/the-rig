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

# ── Session log ──────────────────────────────────────────────────────────────
# Logs every tool call with a timestamp. Useful for debugging agent behaviour.
# Comment out if too noisy.
echo "[$(date +%H:%M:%S)] PRE  $TOOL" >> /tmp/the-rig-session.log

# ── Block writes to protected paths ──────────────────────────────────────────
if [[ "$TOOL" == "Write" || "$TOOL" == "Edit" ]]; then

  # Extract the target file path from the JSON input
  PATH_ARG=$(echo "$INPUT" | grep -o '"file_path":"[^"]*"' | head -1 | cut -d'"' -f4)

  # ── Configure your project's protected paths here ────────────────────────
  # These paths cannot be written to by the agent under any circumstances.
  # Use partial paths — anything containing the string will be blocked.
  # Examples:
  #   ".env.production"   — production environment file
  #   "migrations/"       — database migrations (run manually, not by agent)
  #   "data/approved/"    — curated data files managed by humans
  BLOCKED_PATHS=(
    ".env.production"
    # "migrations/"
    # "data/approved/"
  )
  # ─────────────────────────────────────────────────────────────────────────

  for blocked in "${BLOCKED_PATHS[@]}"; do
    if [[ "$PATH_ARG" == *"$blocked"* ]]; then
      echo "Blocked: '$PATH_ARG' matches protected path '$blocked'" >&2
      echo "This path is off-limits. Edit it manually if a change is truly needed." >&2
      exit 1
    fi
  done
fi

exit 0
