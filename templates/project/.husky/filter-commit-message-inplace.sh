#!/bin/sh
# filter-commit-message-inplace.sh
#
# Strips AI-generated attribution trailers and footers from a commit message file.
# Used by both commit-msg and post-commit hooks.
#
# Usage: sh .husky/filter-commit-message-inplace.sh <message-file>
#
# Strips:
#   - Co-authored-by: known AI tool identities and no-reply addresses
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
# An AI name alone is insufficient: a human named Claude may be a co-author.
# Copilot also emits its bot address without angle brackets.
grep -viE '^[[:space:]]*co-authored-by[[:space:]]*:[[:space:]]*(Claude( Code| (Sonnet|Opus|Haiku) [0-9]+(\.[0-9]+)?)?|Codex|Cursor|Copilot|GitHub Copilot)[[:space:]]*<noreply@(anthropic|openai|cursor|github)\.com>[[:space:]]*$' "$f" |
  grep -viE '^[[:space:]]*co-authored-by[[:space:]]*:[[:space:]]*(Copilot|GitHub Copilot)[[:space:]]+(<copilot@github\.com>|copilot@github\.com)[[:space:]]*$' |
  grep -viE '^[^[:alnum:]]*generated[[:space:]]+(with|by)[[:space:]]+\[?(Claude( Code)?|Codex|Cursor|Copilot|GitHub Copilot)\]?([[:space:]]|\(https?://|[.]|$)' |
  grep -viE '^[^[:alnum:]]*committed[[:space:]]+with[[:space:]]+\[?(Claude( Code)?|Codex|Cursor|Copilot|GitHub Copilot)\]?([[:space:]]|\(https?://|[.]|$)' |
  grep -viE '^[^[:alnum:]]*made[-[:space:]]+with[-[:space:]]+(Claude( Code)?|Codex|Cursor|Copilot|GitHub Copilot)([[:space:].:]|$)' |
  sed 's/\r$//' > "$t"

mv "$t" "$f"
