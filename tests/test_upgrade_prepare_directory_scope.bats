#!/usr/bin/env bats
#
# tests/test_upgrade_prepare_directory_scope.bats — issue #489
#
# Same bug class as issue #482 (see tests/test_upgrade_prepare_mutation_scope.bats):
# upgrade_prepare_directory()'s first line used to be
# `[[ "$COLLISION_STRATEGY" == upgrade ]] || return 0`. Its one call site
# (global .claude root creation) has no enclosing COLLISION_STRATEGY==upgrade
# check, so under --strategy merge (the default for every fresh install) the
# guard silently no-oped -- a symlinked ~/.claude was followed with no
# refusal. Out of #482's scope (that audit covered upgrade_prepare_mutation()
# call sites specifically); this file covers upgrade_prepare_directory()'s
# own call site.
#
# Known residual gap, not covered here (filed separately as issue #501): even
# with this guard correctly refusing, copy_file()'s own destination-state
# symlink check is ALSO gated to --strategy upgrade only, so the CLAUDE.md
# and skills/ writes a few lines below this call site still follow the
# symlink under merge. This file only asserts what #489 itself fixes: that
# upgrade_prepare_directory() correctly detects and reports the conflict
# under every strategy, not that the whole global-layer write path is
# quarantined (that requires #501 too).

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
INSTALLER="$REPO_ROOT/install.sh"

setup() {
  TEMP_DIR="$(mktemp -d)"
  FAKE_HOME="$TEMP_DIR/home"
  mkdir -p "$FAKE_HOME"
}

teardown() { rm -rf "$TEMP_DIR"; }

@test "global .claude root: a symlinked destination is refused under --strategy merge (not just upgrade)" {
  local external_target="$TEMP_DIR/external-claude-root"
  mkdir -p "$external_target"
  ln -s "$external_target" "$FAKE_HOME/.claude"

  run env HOME="$FAKE_HOME" bash "$INSTALLER" \
    --global-only --global-agent claude --strategy merge
  [ "$status" -eq 0 ]

  # A bare `[[ "$output" == *pattern* ]]` (or `!`-negated) assertion that
  # isn't the last statement in the test does not reliably trip bats'
  # failure detection under this machine's stock bash 3.2 (`set -e` does not
  # propagate through either construct there unless it's the function's own
  # last command) -- see docs/lessons-learned.md's bash 3.2 entry. `run` +
  # an explicit `[ "$status" -eq N ]` check is immune to this, since `run`
  # captures the exit status itself rather than depending on `set -e`.
  run grep -qF "Preserving conflicting global Claude root: .claude" <<< "$output"
  [ "$status" -eq 0 ]

  [ -L "$FAKE_HOME/.claude" ]
  readlink "$FAKE_HOME/.claude" | grep -qF "$external_target"
}

@test "global .claude root: a missing destination is still created normally under --strategy merge" {
  [ ! -e "$FAKE_HOME/.claude" ]

  run env HOME="$FAKE_HOME" bash "$INSTALLER" \
    --global-only --global-agent claude --strategy merge
  [ "$status" -eq 0 ]

  # See the sibling test above for why this uses `run` + an explicit status
  # check instead of a bare/negated `[[ ]]` assertion.
  run grep -qF "Preserving conflicting global Claude root" <<< "$output"
  [ "$status" -ne 0 ]

  [ -d "$FAKE_HOME/.claude" ]
  [ ! -L "$FAKE_HOME/.claude" ]
  [ -f "$FAKE_HOME/.claude/CLAUDE.md" ]
}
