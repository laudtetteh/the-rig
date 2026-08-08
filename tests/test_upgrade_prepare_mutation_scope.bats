#!/usr/bin/env bats
#
# tests/test_upgrade_prepare_mutation_scope.bats — issue #482
#
# Same bug class as PR #474's .git/hooks/* fix (issue #451/#470/#471) and PR
# #480's notification-helper/global-settings/Codex-config fix (issue #477):
# upgrade_prepare_mutation()'s very first line is
# `[[ "$COLLISION_STRATEGY" == upgrade ]] || return 0`. Under --strategy
# merge (the default for every fresh install), that guard silently no-oped
# -- no symlink refusal, no backup -- for every call site that actually
# writes on every strategy, not just upgrade. Issue #482 audited every
# remaining upgrade_prepare_mutation() call site and migrated everything
# reached under a non-upgrade strategy to guard_destination_before_write()
# directly, matching the precedent fix. This file covers the migrated
# sites not already covered by tests/test_notification_codex_strategy_guard.bats
# (.git/hooks/*, rig-notify, global settings.json, .codex/config.toml):
# .rig/VERSION, .rigpath, global and project install-targets.json, and the
# CLAUDE.md placeholder-substitution pipeline ([Project Name] +
# [BASE_BRANCH], both routed through the same migrated guard).

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

# ── .rig/VERSION ──────────────────────────────────────────────────────────

@test ".rig/VERSION: a symlinked destination is refused under --strategy merge, never destroying its target" {
  mkdir -p "$TEST_PROJECT/.rig"
  local external_target="$TEMP_DIR/external-version-target.txt"
  printf 'this-file-lives-outside-the-project\n' > "$external_target"
  ln -s "$external_target" "$TEST_PROJECT/.rig/VERSION"

  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking repo --strategy merge
  [ "$status" -eq 0 ]

  grep -q 'this-file-lives-outside-the-project' "$external_target"
  [ -L "$TEST_PROJECT/.rig/VERSION" ]
  readlink "$TEST_PROJECT/.rig/VERSION" | grep -qF "$external_target"
  [[ "$output" == *"Skipped .rig/VERSION due to a conflicting destination"* ]]
}

@test ".rig/VERSION: an existing regular file is backed up before being overwritten under --strategy merge" {
  mkdir -p "$TEST_PROJECT/.rig"
  printf 'hand-written version marker\n' > "$TEST_PROJECT/.rig/VERSION"

  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking repo --strategy merge
  [ "$status" -eq 0 ]

  ! grep -q 'hand-written version marker' "$TEST_PROJECT/.rig/VERSION"
  run grep -rl 'hand-written version marker' "$TEST_PROJECT/.rig-backup"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

# ── .rigpath (external/stealth tracking only) ───────────────────────────────

@test ".rigpath: a symlinked destination is refused under --strategy merge, never destroying its target" {
  local external_rig_dir="$TEMP_DIR/external-rig"
  local external_target="$TEMP_DIR/external-rigpath-target.txt"
  mkdir -p "$external_rig_dir"
  printf 'this-file-lives-outside-the-project\n' > "$external_target"
  ln -s "$external_target" "$TEST_PROJECT/.rigpath"

  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking external --rig-dir "$external_rig_dir" \
    --strategy merge
  [ "$status" -eq 0 ]

  grep -q 'this-file-lives-outside-the-project' "$external_target"
  [ -L "$TEST_PROJECT/.rigpath" ]
  readlink "$TEST_PROJECT/.rigpath" | grep -qF "$external_target"
  [[ "$output" == *"Skipped .rigpath due to a conflicting destination"* ]]
}

@test ".rigpath: an existing regular file is backed up before being overwritten under --strategy merge" {
  local external_rig_dir="$TEMP_DIR/external-rig"
  mkdir -p "$external_rig_dir"
  printf 'hand-written rigpath marker\n' > "$TEST_PROJECT/.rigpath"

  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking external --rig-dir "$external_rig_dir" \
    --strategy merge
  [ "$status" -eq 0 ]

  ! grep -q 'hand-written rigpath marker' "$TEST_PROJECT/.rigpath"
  # Under external/stealth tracking, backups for the external .rig/ dir's own
  # writes land under $EXTERNAL_RIG_DIR/backups/, not $TARGET/.rig-backup/
  # (confirmed live: "Originals backed up to: <external_rig_dir>/backups/<ts>").
  run grep -rl 'hand-written rigpath marker' "$external_rig_dir/backups"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

# ── install-targets.json (global) ───────────────────────────────────────────

@test "global install-targets.json: a symlinked destination is refused under --strategy merge, never destroying its target" {
  mkdir -p "$FAKE_HOME/.rig"
  local external_target="$TEMP_DIR/external-global-state-target.json"
  printf '{"marker":"outside-home"}' > "$external_target"
  ln -s "$external_target" "$FAKE_HOME/.rig/install-targets.json"

  run env HOME="$FAKE_HOME" bash "$INSTALLER" \
    --global-only --global-agent claude --strategy merge
  [ "$status" -eq 0 ]

  grep -q 'outside-home' "$external_target"
  [ -L "$FAKE_HOME/.rig/install-targets.json" ]
  readlink "$FAKE_HOME/.rig/install-targets.json" | grep -qF "$external_target"
}

@test "global install-targets.json: an existing regular file is backed up before being overwritten under --strategy merge" {
  mkdir -p "$FAKE_HOME/.rig"
  printf '{"marker":"hand-written-global-state"}' > "$FAKE_HOME/.rig/install-targets.json"

  run env HOME="$FAKE_HOME" bash "$INSTALLER" \
    --global-only --global-agent claude --strategy merge
  [ "$status" -eq 0 ]

  ! grep -q 'hand-written-global-state' "$FAKE_HOME/.rig/install-targets.json"
  run grep -rl 'hand-written-global-state' "$FAKE_HOME/.rig-backup"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

# ── install-targets.json (project) ──────────────────────────────────────────

@test "project install-targets.json: a symlinked destination is refused under --strategy merge, never destroying its target" {
  mkdir -p "$TEST_PROJECT/.rig"
  local external_target="$TEMP_DIR/external-project-state-target.json"
  printf '{"marker":"outside-project"}' > "$external_target"
  ln -s "$external_target" "$TEST_PROJECT/.rig/install-targets.json"

  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking repo --strategy merge
  [ "$status" -eq 0 ]

  grep -q 'outside-project' "$external_target"
  [ -L "$TEST_PROJECT/.rig/install-targets.json" ]
  readlink "$TEST_PROJECT/.rig/install-targets.json" | grep -qF "$external_target"
}

@test "project install-targets.json: an existing regular file is backed up before being overwritten under --strategy merge" {
  mkdir -p "$TEST_PROJECT/.rig"
  printf '{"marker":"hand-written-project-state"}' > "$TEST_PROJECT/.rig/install-targets.json"

  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking repo --strategy merge
  [ "$status" -eq 0 ]

  ! grep -q 'hand-written-project-state' "$TEST_PROJECT/.rig/install-targets.json"
  run grep -rl 'hand-written-project-state' "$TEST_PROJECT/.rig-backup"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

# ── CLAUDE.md placeholder substitution ([Project Name] + [BASE_BRANCH]) ────

@test "CLAUDE.md: a symlinked destination is never touched by placeholder substitution under --strategy merge" {
  local external_target="$TEMP_DIR/external-claude-target.md"
  printf '# [Project Name]\n\nBase branch: [BASE_BRANCH]\n' > "$external_target"
  ln -s "$external_target" "$TEST_PROJECT/CLAUDE.md"

  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking repo --strategy merge
  [ "$status" -eq 0 ]

  # Neither substitution reached the symlink target: both placeholders
  # remain literal, unlike a real installed CLAUDE.md.
  grep -q '\[Project Name\]' "$external_target"
  grep -q '\[BASE_BRANCH\]' "$external_target"
  [ -L "$TEST_PROJECT/CLAUDE.md" ]
  readlink "$TEST_PROJECT/CLAUDE.md" | grep -qF "$external_target"
}

@test "CLAUDE.md: an existing regular file's content is backed up before placeholder substitution overwrites it in place" {
  # Known limitation, not covered by this test (filed as issue #491): CLAUDE.md
  # can be touched by up to three separate guard_destination_before_write()
  # calls in one run ([Project Name], [BASE_BRANCH] via _subst_base_branch(),
  # and the external/stealth @.rig/ rewrite), each backing up to the same
  # fixed path -- a later call's backup silently overwrites an earlier one's,
  # so the surviving backup can be an intermediate substituted state rather
  # than the true pre-run original. This test only proves *a* backup happens
  # at all (the #482 behavior in scope here), via marker text untouched by
  # either sed call, which can't distinguish a pristine backup from a
  # clobbered intermediate one. See #491 for the backup-collision fix.
  printf '# [Project Name]\n\nBase branch: [BASE_BRANCH]\n\nhand-written CLAUDE.md marker\n' \
    > "$TEST_PROJECT/CLAUDE.md"

  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking repo --strategy merge
  [ "$status" -eq 0 ]

  # The live file was substituted in place (marker content untouched by sed,
  # but the file itself is the same pre-existing regular file, now with a
  # backup taken before this run's mutation touched it).
  grep -q 'hand-written CLAUDE.md marker' "$TEST_PROJECT/CLAUDE.md"
  run grep -rl 'hand-written CLAUDE.md marker' "$TEST_PROJECT/.rig-backup"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}
