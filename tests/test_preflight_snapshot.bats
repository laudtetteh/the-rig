#!/usr/bin/env bats
#
# Issue #472: before any write in an upgrade-family strategy run, take one
# full recursive "before" snapshot of the target project's entire
# Rig/Claude/Codex footprint, independent of and prior to the existing
# per-file backup_file()/_upgrade_write() mechanism.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
INSTALLER="$REPO_ROOT/install.sh"

setup() {
  TEMP_DIR="$(mktemp -d)"
  TEST_PROJECT="$TEMP_DIR/project"
  mkdir -p "$TEST_PROJECT"
  git -C "$TEST_PROJECT" init -q
  git -C "$TEST_PROJECT" config user.email test@test.com
  git -C "$TEST_PROJECT" config user.name Test
}

teardown() { rm -rf "$TEMP_DIR"; }

@test "upgrade strategy takes a whole-tree pre-flight snapshot before any write, in repo tracking mode" {
  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking repo --strategy merge
  [ "$status" -eq 0 ]
  git -C "$TEST_PROJECT" add -A
  git -C "$TEST_PROJECT" commit -q -m "install"

  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking repo --strategy upgrade
  [ "$status" -eq 0 ]

  run find "$TEST_PROJECT/.rig-backup/preflight-snapshots" -mindepth 1 -maxdepth 1 -type d
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  local snap_dir="$output"
  [ -f "$snap_dir/CLAUDE.md" ]
  [ -d "$snap_dir/.claude" ]
  [ -d "$snap_dir/.rig" ]
  [ -f "$snap_dir/.rig/VERSION" ]
}

@test "pre-flight snapshot in external/stealth tracking lands under EXTERNAL_RIG_DIR and includes the external .rig/ contents" {
  local rig_ext="$TEMP_DIR/external-rig"
  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking stealth --rig-dir "$rig_ext" --strategy merge
  [ "$status" -eq 0 ]

  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking stealth --rig-dir "$rig_ext" --strategy upgrade
  [ "$status" -eq 0 ]

  run find "$rig_ext/preflight-snapshots" -mindepth 1 -maxdepth 1 -type d
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  local snap_dir="$output"
  [ -f "$snap_dir/CLAUDE.md" ]
  [ -d "$snap_dir/.rig" ]
  [ -f "$snap_dir/.rig/VERSION" ]
  # The external .rig/ dir is this snapshot's own ancestor directory (both
  # preflight-snapshots/ and any .rig-backup/ transaction dirs live inside
  # it) -- neither may appear nested inside the snapshot's own .rig/ copy,
  # or the mechanism recurses into itself.
  [ ! -e "$snap_dir/.rig/preflight-snapshots" ]
  [ ! -e "$snap_dir/.rig/.rig-backup" ]
}

@test "agent-plan (dry run) never takes a pre-flight snapshot -- there is nothing to protect in a run that writes nothing" {
  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking repo --strategy merge
  [ "$status" -eq 0 ]
  git -C "$TEST_PROJECT" add -A
  git -C "$TEST_PROJECT" commit -q -m "install"

  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking repo --strategy agent-plan
  [ ! -e "$TEST_PROJECT/.rig-backup/preflight-snapshots" ]
}

@test "merge strategy never takes a pre-flight snapshot -- only the upgrade family does" {
  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking repo --strategy merge
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_PROJECT/.rig-backup/preflight-snapshots" ]
}

@test "agent-upgrade (real, non-dry-run mutation) takes a pre-flight snapshot" {
  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking repo --strategy merge
  [ "$status" -eq 0 ]
  git -C "$TEST_PROJECT" add -A
  git -C "$TEST_PROJECT" commit -q -m "install"

  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking repo --strategy agent-upgrade
  [ "$status" -eq 0 ] || [ "$status" -eq 3 ]

  run find "$TEST_PROJECT/.rig-backup/preflight-snapshots" -mindepth 1 -maxdepth 1 -type d
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "pre-flight snapshot in external/stealth tracking excludes an existing backups/ dir, not just preflight-snapshots/ and .rig-backup/" {
  # backups/ (plural, no dash) is init_backup_dir()'s destination for
  # non-upgrade strategies in stealth/external tracking -- distinct from
  # preflight-snapshots/ and .rig-backup/, and only created once a real
  # per-file backup actually happens. Force one via --strategy overwrite
  # against an existing install before taking the snapshot, so all three
  # excluded names are genuinely present and exercised, not just asserted
  # absent by default.
  local rig_ext="$TEMP_DIR/external-rig"
  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking stealth --rig-dir "$rig_ext" --strategy merge
  [ "$status" -eq 0 ]

  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking stealth --rig-dir "$rig_ext" --strategy overwrite
  [ "$status" -eq 0 ]
  [ -d "$rig_ext/backups" ]

  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking stealth --rig-dir "$rig_ext" --strategy upgrade
  [ "$status" -eq 0 ]

  run find "$rig_ext/preflight-snapshots" -mindepth 1 -maxdepth 1 -type d
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  local snap_dir="$output"
  [ ! -e "$snap_dir/.rig/backups" ]
}

@test "pre-flight snapshot retention keeps only the 5 most recent, pruning the oldest first" {
  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking repo --strategy merge
  [ "$status" -eq 0 ]
  git -C "$TEST_PROJECT" add -A
  git -C "$TEST_PROJECT" commit -q -m "install"

  local i snap_root="$TEST_PROJECT/.rig-backup/preflight-snapshots"
  local -a all_snapshots=()
  for i in 1 2 3 4 5 6; do
    run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
      --project-name Test --tracking repo --strategy upgrade
    [ "$status" -eq 0 ]
    run find "$snap_root" -mindepth 1 -maxdepth 1 -type d
    [ "$status" -eq 0 ]
    # The single newest dir after this run -- the one just created.
    local newest
    newest="$(printf '%s\n' "$output" | sort | tail -1)"
    all_snapshots+=("$newest")
    sleep 1
  done

  run find "$snap_root" -mindepth 1 -maxdepth 1 -type d
  [ "$status" -eq 0 ]
  local count
  count="$(printf '%s\n' "$output" | grep -c .)"
  [ "$count" -eq 5 ]

  # The first (oldest) snapshot created across the 6 runs must be gone;
  # the last (newest) must still be present -- not just "5 remain", but
  # specifically the 5 most recent.
  [ ! -e "${all_snapshots[0]}" ]
  [ -e "${all_snapshots[5]}" ]
}
