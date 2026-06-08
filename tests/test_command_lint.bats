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

# ── wrap / post-merge behavior spec ───────────────────────────────────────────

@test "wrap.md: contains Wrap report step section" {
  grep -q "## Wrap report step" "$COMMAND_DIR/wrap.md"
}

@test "wrap.md: Wrap report step defines collection phase and report format" {
  grep -q "Collection phase" "$COMMAND_DIR/wrap.md"
  grep -q "This session" "$COMMAND_DIR/wrap.md"
  grep -q "Wrap report —" "$COMMAND_DIR/wrap.md"
}

@test "wrap.md: PROGRESS.md trim executes automatically — no confirmation gate" {
  # Must NOT contain the old 'Trim now?' prompt
  ! grep -q "Trim now?" "$COMMAND_DIR/wrap.md"
}

@test "wrap.md: ERRORS.md logging infers from context — no 'ask' prompt" {
  # Must NOT ask the user whether anything unexpected happened
  ! grep -q "Did anything unexpected" "$COMMAND_DIR/wrap.md"
}

@test "wrap.md: trim steps reference Wrap report — not standalone confirmations" {
  grep -q "note in the Wrap report" "$COMMAND_DIR/wrap.md"
}

@test "post-merge.md: contains Post-merge report step section" {
  grep -q "## Post-merge report step" "$COMMAND_DIR/post-merge.md"
}

@test "post-merge.md: Post-merge report step defines collection and report format" {
  grep -q "Collection phase" "$COMMAND_DIR/post-merge.md"
  grep -q "Post-merge report —" "$COMMAND_DIR/post-merge.md"
}

@test "post-merge.md: executes POST_MERGE_WORKFLOW automatically after report" {
  grep -q "execute POST_MERGE_WORKFLOW steps" "$COMMAND_DIR/post-merge.md"
}

# ── PR description freshness ───────────────────────────────────────────────────

@test "wrap.md: contains PR description freshness step" {
  grep -q "## PR description freshness step" "$COMMAND_DIR/wrap.md"
}

@test "wrap.md: PR freshness step skips housekeeping commit types" {
  grep -q "chore(memory)" "$COMMAND_DIR/wrap.md"
}

@test "wrap.md: PR freshness step skips silently when no open PR" {
  grep -q "skip silently" "$COMMAND_DIR/wrap.md"
}

@test "ship.md: Step 9 compares commits against existing PR description before prompting" {
  grep -q "compare the branch commits against the existing PR description" "$COMMAND_DIR/ship.md"
}

@test "ship.md: Step 9 skips housekeeping commit types in freshness check" {
  grep -qE "chore\(memory\)" "$COMMAND_DIR/ship.md"
}
