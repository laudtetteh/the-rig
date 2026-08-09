#!/usr/bin/env bats
#
# tests/test_upgrade_manifest_mutation_scope.bats — issue #490
#
# Same bug class as issue #482 and #489 (see
# tests/test_upgrade_prepare_mutation_scope.bats and
# tests/test_upgrade_prepare_directory_scope.bats):
# upgrade_manifest_mutation_allowed()'s first line used to be
# `[[ "$COLLISION_STRATEGY" == upgrade ]] || return 0`. It's called from
# write_manifest_entry() on nearly every file write this script performs, so
# manifest-file symlink protection was effectively dead outside
# --strategy upgrade. Out of #482's scope (that audit covered
# upgrade_prepare_mutation() call sites specifically).
#
# Note: write_manifest_entry()'s rename-based write replaces a symlinked
# manifest destination rather than following it, so the pre-fix failure mode
# here is "the user's symlink is silently destroyed with no warning", not
# "content gets written through the symlink into its target" (the failure
# mode #489 and #482's sweep otherwise document). Confirmed live before this
# fix: a symlinked .rig-manifest was silently replaced by a plain file under
# --strategy merge; after the fix, it's correctly refused and left untouched.

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

@test ".rig-manifest: a symlinked destination is refused under --strategy merge, never destroyed" {
  mkdir -p "$TEST_PROJECT/.rig/memory"
  local external_target="$TEMP_DIR/external-manifest.txt"
  printf 'attacker-controlled manifest content\n' > "$external_target"
  ln -s "$external_target" "$TEST_PROJECT/.rig/memory/.rig-manifest"

  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking repo --strategy merge
  [ "$status" -eq 0 ]

  # The symlink itself survives (not replaced by a plain file), and its
  # target's content is completely untouched.
  [ -L "$TEST_PROJECT/.rig/memory/.rig-manifest" ]
  readlink "$TEST_PROJECT/.rig/memory/.rig-manifest" | grep -qF "$external_target"
  grep -q 'attacker-controlled manifest content' "$external_target"

  # The .json sidecar manifest is never created either, since the shared
  # manifest destination as a whole is unsafe to write to.
  [ ! -e "$TEST_PROJECT/.rig/memory/.rig-manifest.json" ]

  # The actual file-copy operations that triggered these manifest writes
  # still succeeded normally -- only manifest bookkeeping was refused, not
  # the real template files.
  [ -f "$TEST_PROJECT/CLAUDE.md" ]
  [ -f "$TEST_PROJECT/.husky/pre-commit" ]
}

@test ".rig-manifest: a missing destination is still created normally under --strategy merge" {
  [ ! -e "$TEST_PROJECT/.rig/memory/.rig-manifest" ]

  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking repo --strategy merge
  [ "$status" -eq 0 ]

  [ -f "$TEST_PROJECT/.rig/memory/.rig-manifest" ]
  [ ! -L "$TEST_PROJECT/.rig/memory/.rig-manifest" ]
  [ -f "$TEST_PROJECT/.rig/memory/.rig-manifest.json" ]
}

@test ".rig-manifest: the conflict warning names the manifest itself, once, not every file that happened to trigger a manifest write" {
  # Issue #503: upgrade_manifest_mutation_allowed() used to call
  # record_upgrade_destination_conflict() with the TRIGGERING file's own
  # $rel (e.g. ".husky/pre-commit"), not the manifest's -- so every write
  # this run printed a warning claiming an unrelated, perfectly normal file
  # was the symlinked conflict, once per file processed. Confirmed live
  # before this fix: 75 misleading warnings for a single symlinked
  # .rig-manifest, each naming a different unrelated file.
  mkdir -p "$TEST_PROJECT/.rig/memory"
  local external_target="$TEMP_DIR/external-manifest.txt"
  printf 'attacker-controlled manifest content\n' > "$external_target"
  ln -s "$external_target" "$TEST_PROJECT/.rig/memory/.rig-manifest"

  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking repo --strategy merge
  [ "$status" -eq 0 ]
  local install_output="$output"

  run grep -c "Preserved conflicting upgrade destination" <<< "$install_output"
  [ "$status" -eq 0 ]
  [ "$output" -eq 1 ]

  run grep -qF "Preserved conflicting upgrade destination: memory/.rig-manifest (symlink)" <<< "$install_output"
  [ "$status" -eq 0 ]

  # The old, misattributed wording must not appear for any unrelated file.
  run grep -qF "Preserved conflicting upgrade destination: .husky/pre-commit" <<< "$install_output"
  [ "$status" -ne 0 ]
  run grep -qF "Preserved conflicting upgrade destination: CLAUDE.md" <<< "$install_output"
  [ "$status" -ne 0 ]
}
