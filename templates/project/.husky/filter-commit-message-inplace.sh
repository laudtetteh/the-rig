#!/bin/sh
# filter-commit-message-inplace.sh
#
# Strips AI-generated attribution trailers and footers from a commit message file.
# Used by both commit-msg and post-commit hooks.
#
# Usage: sh .husky/filter-commit-message-inplace.sh <message-file>
#
# Strips:
#   - Co-authored-by: lines that reference AI tools (Claude, Cursor, Copilot, etc.)
#     Human co-author attribution is preserved.
#   - AI tool footer lines: "Generated with Cursor/Claude/Copilot", etc.
#
# Why: AI coding tools inject attribution footers into every commit. These
# clutter the git log and expose which commits were AI-assisted. This script
# removes them so commit history stays clean and human-authored in tone.
#
# NOTE: Only Co-authored-by lines mentioning AI tools are stripped. Human
# pair-programmer attribution (e.g. "Co-authored-by: Jane <jane@example.com>")
# is intentionally preserved.

f="$1"
[ -n "$f" ] && [ -f "$f" ] || exit 0

t=$(mktemp) || exit 1

# Strip Co-authored-by only when the value references a known AI tool or service.
# Matches: tool names (Claude, Cursor, Copilot) and known AI no-reply addresses.
grep -viE '^[[:space:]]*co-authored-by[[:space:]]*:.*([Cc]laude|[Cc]ursor|[Cc]opilot|[Gg]it[Hh]ub[[:space:]]+[Cc]opilot|noreply@anthropic\.com|noreply@cursor\.com|noreply@github\.com)' "$f" |
  grep -viE '^[[:space:]]*([#*>-][[:space:]]*)*[Gg]enerated[[:space:]]+with[[:space:]]+(Cursor|Claude|Copilot|GitHub Copilot)([[:space:]].*)?$' |
  grep -viE '^[[:space:]]*([#*>-][[:space:]]*)*[Gg]enerated[[:space:]]+by[[:space:]]+(Cursor|Claude|Copilot|GitHub Copilot)([[:space:]].*)?$' |
  grep -viE '^[[:space:]]*([#*>-][[:space:]]*)*[Cc]ommitted[[:space:]]+with[[:space:]]+(Cursor|Claude|Copilot)([[:space:]].*)?$' |
  sed 's/\r$//' > "$t"

mv "$t" "$f"
