#!/usr/bin/env bats
#
# tests/test_install_idempotence.bats — Proves that repeated `--strategy
# upgrade` runs against an unmodified target converge: the second upgrade in
# a row must produce zero further changes to the installed file tree.
#
# This is the documented procedure `rig doctor`'s "idempotence" gate points
# to (see the check("idempotence", ...) block in templates/project/bin/rig).
# Doctor deliberately never re-runs the installer against a live project
# tree itself (it is a read-only diagnostic), so idempotence is verified
# here instead, against a disposable fixture, as a real black-box run of
# install.sh — no source changes to install.sh are required or made by this
# lane.
#
# Run with: bats tests/test_install_idempotence.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
INSTALLER="$REPO_ROOT/install.sh"

setup() {
  TEMP_DIR="$(mktemp -d)"
  TEST_PROJECT="$TEMP_DIR/test-project"
  mkdir -p "$TEST_PROJECT"
  git -C "$TEST_PROJECT" init -q
  git -C "$TEST_PROJECT" config user.email "test@test.com"
  git -C "$TEST_PROJECT" config user.name "Test"
}

teardown() {
  rm -rf "$TEMP_DIR"
}

run_installer() {
  run bash "$INSTALLER" --project-only \
    --target "$TEST_PROJECT" \
    --project-name "TestProject" \
    --tracking repo \
    "$@"
}

# Deterministic snapshot: relative path, mode, and content hash for every
# tracked-or-not file under the target, excluding the manifest itself (whose
# installer_version/timestamps are allowed to be rewritten identically on
# each run) and .git internals (irrelevant to installed-artifact state).
snapshot_tree() {
  # .rig-backup can be created at more than one base within a single run
  # (e.g. $TEST_PROJECT/.rig-backup for project-root mutations,
  # $TEST_PROJECT/.rig/.rig-backup for direct-writer mutations scoped under
  # .rig/ — see 444-F's upgrade_prepare_mutation()), so prune by directory
  # name at any depth rather than matching two fixed paths.
  find "$TEST_PROJECT" \
    \( -path "$TEST_PROJECT/.git" -o -name ".rig-backup" \) -prune -o \
    -type f -print \
    | sort \
    | while IFS= read -r file; do
        rel="${file#"$TEST_PROJECT"/}"
        mode="$(stat -c '%a' "$file" 2>/dev/null || stat -f '%Lp' "$file")"
        hash="$(shasum -a 256 "$file" | awk '{print $1}')"
        printf '%s %s %s\n' "$mode" "$hash" "$rel"
      done
}

@test "a second consecutive upgrade run makes no further changes to the installed tree" {
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]
  local after_first_upgrade; after_first_upgrade="$(snapshot_tree)"

  run_installer --strategy upgrade
  [ "$status" -eq 0 ]
  local after_second_upgrade; after_second_upgrade="$(snapshot_tree)"

  [ "$after_first_upgrade" = "$after_second_upgrade" ]
}

@test "a second consecutive upgrade run reports zero stale entries and stable classification counts" {
  # Not a zero-review assertion: [BASE_BRANCH]-substituted process files are a
  # known, separately tracked false positive (see CLAUDE.md "Known gotchas" —
  # substitution runs after write_manifest_entry, so those files legitimately
  # differ from their recorded hash on every run). That is an existing,
  # out-of-scope classification bug, not a stale/drift/idempotence failure:
  # this test proves the classification itself is stable and that nothing is
  # ever reported stale, not that the false positive is absent.
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]
  local second_summary; second_summary="$(printf '%s\n' "$output" | grep -E '^(Updated|Merged|Removed obsolete|Skipped customized|Skipped conflicts|Stale/missing tracked artifacts):')"
  [[ "$output" == *"Stale/missing tracked artifacts: 0"* ]]

  run_installer --strategy upgrade
  [ "$status" -eq 0 ]
  local third_summary; third_summary="$(printf '%s\n' "$output" | grep -E '^(Updated|Merged|Removed obsolete|Skipped customized|Skipped conflicts|Stale/missing tracked artifacts):')"
  [[ "$output" == *"Stale/missing tracked artifacts: 0"* ]]

  [ "$second_summary" = "$third_summary" ]
}
