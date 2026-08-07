#!/usr/bin/env bats
#
# tests/test_notification_codex_strategy_guard.bats — issue #477
#
# Same bug class as PR #474's .git/hooks/* fix (issue #451/#470/#471): the
# notification-helper (~/.claude/bin/rig-notify, ~/.claude/settings.json) and
# Codex-config (.codex/config.toml) writes were gated only by
# upgrade_prepare_mutation(), whose very first line is
# `[[ "$COLLISION_STRATEGY" == upgrade ]] || return 0`. Under --strategy merge
# (the default for every fresh install with --notifications or
# --project-agent codex), that guard silently no-oped -- no backup, no
# refusal -- and the unconditional write below it ran anyway, following a
# symlink and overwriting whatever it pointed to, in place, even outside the
# project. Fixed by routing both call sites through
# guard_destination_before_write() directly, matching the .git/hooks/* fix.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
INSTALLER="$REPO_ROOT/install.sh"

setup() {
  TEMP_DIR="$(mktemp -d)"
  TEST_PROJECT="$TEMP_DIR/project"
  FAKE_HOME="$TEMP_DIR/home"
  mkdir -p "$TEST_PROJECT" "$FAKE_HOME"
  git -C "$TEST_PROJECT" init -q
  git -C "$TEST_PROJECT" config user.email test@test.com
  git -C "$TEST_PROJECT" config user.name Test
}

teardown() { rm -rf "$TEMP_DIR"; }

@test "a symlinked notification helper is refused under --strategy merge, never silently destroying its target" {
  mkdir -p "$FAKE_HOME/.claude/bin"
  local external_target="$TEMP_DIR/external-notify-target.sh"
  printf '#!/bin/sh\necho this-file-lives-outside-home\n' > "$external_target"
  ln -s "$external_target" "$FAKE_HOME/.claude/bin/rig-notify"

  run env HOME="$FAKE_HOME" bash "$INSTALLER" \
    --global-only --global-agent claude --notifications --strategy merge
  [ "$status" -eq 0 ]

  grep -q 'this-file-lives-outside-home' "$external_target"
  [ -L "$FAKE_HOME/.claude/bin/rig-notify" ]
  readlink "$FAKE_HOME/.claude/bin/rig-notify" | grep -qF "$external_target"
  [[ "$output" == *"Skipped notification helper due to a conflicting destination"* ]]
}

@test "an existing regular-file notification helper is backed up before being overwritten under --strategy merge" {
  mkdir -p "$FAKE_HOME/.claude/bin"
  printf 'hand-written notify marker\n' > "$FAKE_HOME/.claude/bin/rig-notify"

  run env HOME="$FAKE_HOME" bash "$INSTALLER" \
    --global-only --global-agent claude --notifications --strategy merge
  [ "$status" -eq 0 ]

  ! grep -q 'hand-written notify marker' "$FAKE_HOME/.claude/bin/rig-notify"
  run grep -rl 'hand-written notify marker' "$FAKE_HOME/.rig-backup"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "a symlinked global settings.json is refused under --strategy merge when notifications are enabled" {
  mkdir -p "$FAKE_HOME/.claude"
  local external_target="$TEMP_DIR/external-settings-target.json"
  printf '{"marker":"outside-home"}' > "$external_target"
  ln -s "$external_target" "$FAKE_HOME/.claude/settings.json"

  run env HOME="$FAKE_HOME" bash "$INSTALLER" \
    --global-only --global-agent claude --notifications --strategy merge
  [ "$status" -eq 0 ]

  grep -q 'outside-home' "$external_target"
  [ -L "$FAKE_HOME/.claude/settings.json" ]
  readlink "$FAKE_HOME/.claude/settings.json" | grep -qF "$external_target"
}

@test "a symlinked .codex/config.toml is refused under --strategy merge, never silently destroying its target" {
  mkdir -p "$TEST_PROJECT/.codex"
  local external_target="$TEMP_DIR/external-codex-config.toml"
  printf 'marker = "outside-project"\n' > "$external_target"
  ln -s "$external_target" "$TEST_PROJECT/.codex/config.toml"

  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking repo --project-agent codex --strategy merge
  [ "$status" -eq 0 ]

  grep -q 'outside-project' "$external_target"
  [ -L "$TEST_PROJECT/.codex/config.toml" ]
  readlink "$TEST_PROJECT/.codex/config.toml" | grep -qF "$external_target"
  [[ "$output" == *"Skipped Codex project config due to a conflicting destination"* ]]
}

@test "an existing regular-file .codex/config.toml is backed up before being merged under --strategy merge" {
  mkdir -p "$TEST_PROJECT/.codex"
  printf 'hand-written codex marker = true\n' > "$TEST_PROJECT/.codex/config.toml"

  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking repo --project-agent codex --strategy merge
  [ "$status" -eq 0 ]

  run grep -rl 'hand-written codex marker' "$TEST_PROJECT/.rig-backup"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}
