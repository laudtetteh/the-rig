#!/usr/bin/env bats
#
# tests/test_same_run_creation_tracking.bats — issue #493
#
# guard_destination_before_write()'s regular-file classification could not
# distinguish "this destination existed before this run started" from "this
# destination was written moments ago by an earlier step in this same run"
# -- both look identical: an existing regular file. This surfaced when issue
# #482's sweep migrated the SubagentStart-injection and [REPO_ROOT]-
# substitution settings.json call sites to guard_destination_before_write():
# both run immediately after the SAME settings.json was just created or
# smart-merged earlier in the SAME run, so migrating them took a second,
# spurious backup of the just-written file, silently overwriting the smart-
# merge's own correct backup with intermediate content and breaking issue
# #470's regression test ("merge strategy: backs up settings.json before
# merging into an existing one"). Reverted to unblock; #493 fixes the root
# cause with a run-scoped _RUN_WRITTEN_DESTINATIONS tracker (see
# install.sh, just above guard_destination_before_write()) so a later guard
# call recognizes a same-run creation and skips the backup entirely, then
# re-migrates both call sites back to guard_destination_before_write().
#
# This file specifically proves the "no double-backup clobbering" mechanism
# --- that at most ONE settings.json backup exists after a run that touches
# it three times (smart-merge, SubagentStart injection, REPO_ROOT
# substitution), and it holds the true pre-run content, not an intermediate
# state. Issue #470's own test (tests/test_install.bats) already covers the
# externally-observable "a backup with the right hash exists" case; this
# file adds the multiplicity check that test doesn't make.

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

@test "settings.json touched 3x in one run (smart-merge, SubagentStart, REPO_ROOT) backs up exactly once, with true pre-run content" {
  mkdir -p "$TEST_PROJECT/.claude"
  printf '{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"echo hand-written-hook"}]}]}}\n' \
    > "$TEST_PROJECT/.claude/settings.json"
  local before_hash
  before_hash="$(sha256sum "$TEST_PROJECT/.claude/settings.json" 2>/dev/null | awk '{print $1}' || shasum -a 256 "$TEST_PROJECT/.claude/settings.json" | awk '{print $1}')"

  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking repo --strategy merge --subagents
  [ "$status" -eq 0 ]

  # Exactly one settings.json backup -- a second guard call clobbering the
  # first would still leave exactly one *file* at the same fixed backup
  # path (issue #491's dedup already prevents a second distinct backup
  # directory), so the real proof is CONTENT: it must be the true pre-run
  # original, not an intermediate state from between the three touches.
  run find "$TEST_PROJECT/.rig-backup" -name settings.json
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  local backup_count
  backup_count="$(printf '%s\n' "$output" | wc -l | tr -d ' ')"
  [ "$backup_count" -eq 1 ]

  local backup_hash
  backup_hash="$(sha256sum "$output" 2>/dev/null | awk '{print $1}' || shasum -a 256 "$output" | awk '{print $1}')"
  [ "$backup_hash" = "$before_hash" ]

  # The live file reflects all three touches: merged (hand-written hook
  # preserved), SubagentStart wired in, [REPO_ROOT] substituted for real.
  run grep -q 'hand-written-hook' "$TEST_PROJECT/.claude/settings.json"
  [ "$status" -eq 0 ]
  run grep -q 'SubagentStart' "$TEST_PROJECT/.claude/settings.json"
  [ "$status" -eq 0 ]
  run grep -q '\[REPO_ROOT\]' "$TEST_PROJECT/.claude/settings.json"
  [ "$status" -ne 0 ]
}

@test "settings.json created fresh this run (no pre-existing file) is never spuriously backed up" {
  # This is the specific case backup_file()'s own #491 dedup (skip a
  # destination whose backup path already exists this run) does NOT cover:
  # there is no earlier backup_file() call to deduplicate against at all,
  # since copy_file()'s missing-destination branch does a raw `cp` with no
  # backup step (nothing existed before this run to back up). Without
  # was_written_this_run() tracking, the SubagentStart-injection guard call
  # below would see this just-created file as an ordinary "regular-file"
  # and take a spurious first-ever backup of content that has no real prior
  # state -- proof-by-revert (temporarily removing the was_written_this_run
  # short-circuit in guard_destination_before_write()) confirms a backup
  # appears in that case; with the fix, it must not.
  [ ! -e "$TEST_PROJECT/.claude/settings.json" ]

  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking repo --strategy merge --subagents
  [ "$status" -eq 0 ]

  [ -f "$TEST_PROJECT/.claude/settings.json" ]
  run grep -q 'SubagentStart' "$TEST_PROJECT/.claude/settings.json"
  [ "$status" -eq 0 ]

  run find "$TEST_PROJECT/.rig-backup" -name settings.json
  [ "$status" -ne 0 ] || [ -z "$output" ]
}
