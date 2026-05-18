#!/usr/bin/env bats
#
# tests/test_command_lint.bats — Structural linting for command markdown files
#
# Run with: bats tests/test_command_lint.bats
#
# Enforces four structural invariants across every .md file in
# templates/project/.claude/commands/:
#   1. H1 first line matches "# Command: /slug"
#   2. Slug in H1 matches the filename (debug.md → /debug)
#   3. At least one H2 section exists
#   4. No H2 header is missing a space after "##"

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
COMMAND_DIR="$REPO_ROOT/templates/project/.claude/commands"

# ── Helpers ───────────────────────────────────────────────────────────────────

_fail_with_list() {
  local label="$1"
  shift
  printf '%s:\n' "$label"
  printf '  %s\n' "$@"
  return 1
}

# ── Tests ─────────────────────────────────────────────────────────────────────

@test "command files: H1 first line matches '# Command: /slug' format" {
  local failures=()
  for f in "$COMMAND_DIR"/*.md; do
    local first
    first="$(head -1 "$f")"
    if ! echo "$first" | grep -qE '^# Command: /[a-z-]+$'; then
      failures+=("$(basename "$f"): got '${first}'")
    fi
  done
  [ "${#failures[@]}" -eq 0 ] || _fail_with_list "Malformed H1" "${failures[@]}"
}

@test "command files: slug in H1 matches filename" {
  local failures=()
  for f in "$COMMAND_DIR"/*.md; do
    local name first slug
    name="$(basename "$f" .md)"
    first="$(head -1 "$f")"
    slug="${first#\# Command: /}"
    if [[ "$slug" != "$name" ]]; then
      failures+=("$(basename "$f"): expected /${name}, H1 says /${slug}")
    fi
  done
  [ "${#failures[@]}" -eq 0 ] || _fail_with_list "Slug mismatch" "${failures[@]}"
}

@test "command files: all files have at least one H2 section" {
  local failures=()
  for f in "$COMMAND_DIR"/*.md; do
    if ! grep -q "^## " "$f"; then
      failures+=("$(basename "$f")")
    fi
  done
  [ "${#failures[@]}" -eq 0 ] || _fail_with_list "Missing H2 section" "${failures[@]}"
}

@test "command files: no H2 header missing space after '##'" {
  local failures=()
  for f in "$COMMAND_DIR"/*.md; do
    # Matches ## at line start followed by a char that is not # or space.
    # This catches "##Foo" but not "### Foo" (H3) or "## Foo" (valid H2).
    if grep -qE '^##[^# ]' "$f"; then
      failures+=("$(basename "$f")")
    fi
  done
  [ "${#failures[@]}" -eq 0 ] || _fail_with_list "H2 missing space after ##" "${failures[@]}"
}
