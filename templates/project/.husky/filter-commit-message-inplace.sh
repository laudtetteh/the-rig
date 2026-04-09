#!/bin/sh
# filter-commit-message-inplace.sh
#
# Strips AI-generated attribution trailers and footers from a commit message file.
# Used by both commit-msg and post-commit hooks.
#
# Usage: sh .husky/filter-commit-message-inplace.sh <message-file>
#
# Strips:
#   - Git trailer lines: Co-authored-by, Signed-off-by, Reviewed-by, etc.
#   - AI tool footer lines: "Generated with Cursor/Claude/Copilot", etc.
#
# Why: AI coding tools inject attribution footers into every commit. These
# clutter the git log and expose which commits were AI-assisted. This script
# removes them so commit history stays clean and human-authored in tone.

f="$1"
[ -n "$f" ] && [ -f "$f" ] || exit 0

t=$(mktemp) || exit 1

grep -viE '^[[:space:]]*(co-authored-by|signed-off-by|reviewed-by|acked-by|tested-by|helped-by|on-behalf-of|made-with)[[:space:]]*:' "$f" |
  grep -viE '^[[:space:]]*([#*>-][[:space:]]*)*[Gg]enerated[[:space:]]+with[[:space:]]+(Cursor|Claude|Copilot|GitHub Copilot)([[:space:]].*)?$' |
  grep -viE '^[[:space:]]*([#*>-][[:space:]]*)*[Gg]enerated[[:space:]]+by[[:space:]]+(Cursor|Claude|Copilot|GitHub Copilot)([[:space:]].*)?$' |
  grep -viE '^[[:space:]]*([#*>-][[:space:]]*)*[Cc]ommitted[[:space:]]+with[[:space:]]+(Cursor|Claude|Copilot)([[:space:]].*)?$' |
  sed 's/\r$//' > "$t"

mv "$t" "$f"
