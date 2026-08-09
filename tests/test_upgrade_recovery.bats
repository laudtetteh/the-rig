#!/usr/bin/env bats

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

recover() {
  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking repo --recover
}

@test "recover restores backed-up files and removes the interrupted journal" {
  printf 'original user configuration\n' > "$TEST_PROJECT/CLAUDE.md"
  mkdir -p "$TEST_PROJECT/.rig-backup/.in-progress"
  printf 'original user configuration\n' > "$TEST_PROJECT/.rig-backup/.in-progress/CLAUDE.md"
  printf 'backup\tCLAUDE.md\n' > "$TEST_PROJECT/.rig-backup/.in-progress/.journal"
  printf 'partially overwritten configuration\n' > "$TEST_PROJECT/CLAUDE.md"

  recover

  [ "$status" -eq 0 ]
  grep -Fxq 'original user configuration' "$TEST_PROJECT/CLAUDE.md"
  [ ! -e "$TEST_PROJECT/.rig-backup/.in-progress" ]
  [[ "$output" == *"Interrupted upgrade restored"* ]] || return 1
}

@test "recover removes files recorded as created by an interrupted upgrade" {
  printf 'generated file\n' > "$TEST_PROJECT/.rig-generated"
  mkdir -p "$TEST_PROJECT/.rig-backup/.in-progress"
  printf 'created\t.rig-generated\n' > "$TEST_PROJECT/.rig-backup/.in-progress/.journal"

  recover

  [ "$status" -eq 0 ]
  [ ! -e "$TEST_PROJECT/.rig-generated" ]
  [ ! -e "$TEST_PROJECT/.rig-backup/.in-progress" ]
}

@test "successful upgrade finalizes its journal as a recoverable backup" {
  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking repo --strategy upgrade

  [ "$status" -eq 0 ]
  [ ! -e "$TEST_PROJECT/.rig-backup/.in-progress" ]
  [ "$(find "$TEST_PROJECT/.rig-backup" -name .journal -type f | wc -l | tr -d ' ')" -ge 1 ]
}

@test "recover rejects traversal entries without deleting the transaction" {
  printf 'outside sentinel\n' > "$TEMP_DIR/outside.txt"
  mkdir -p "$TEST_PROJECT/.rig-backup/.in-progress"
  printf 'created\t../outside.txt\n' > "$TEST_PROJECT/.rig-backup/.in-progress/.journal"

  recover

  [ "$status" -ne 0 ]
  grep -Fxq 'outside sentinel' "$TEMP_DIR/outside.txt"
  [ -f "$TEST_PROJECT/.rig-backup/.in-progress/.journal" ]
  [[ "$output" == *"Unsafe path in interrupted upgrade journal"* ]] || return 1
}

@test "recover rejects symlinked journal destinations without external writes" {
  mkdir -p "$TEMP_DIR/outside-dir"
  ln -s "$TEMP_DIR/outside-dir" "$TEST_PROJECT/escape"
  mkdir -p "$TEST_PROJECT/.rig-backup/.in-progress/escape"
  printf 'created\tescape/created.txt\n' > "$TEST_PROJECT/.rig-backup/.in-progress/.journal"

  recover

  [ "$status" -ne 0 ]
  [ ! -e "$TEMP_DIR/outside-dir/created.txt" ]
  [ -f "$TEST_PROJECT/.rig-backup/.in-progress/.journal" ]
  [[ "$output" == *"Unsafe path in interrupted upgrade journal"* ]] || return 1
}

@test "recover processes both global and project layers before exiting" {
  GLOBAL_HOME="$TEMP_DIR/home"
  mkdir -p "$GLOBAL_HOME/.claude/.rig-backup/.in-progress"
  printf 'global original\n' > "$GLOBAL_HOME/.claude/CLAUDE.md"
  printf 'global original\n' > "$GLOBAL_HOME/.claude/.rig-backup/.in-progress/CLAUDE.md"
  printf 'backup\tCLAUDE.md\n' > "$GLOBAL_HOME/.claude/.rig-backup/.in-progress/.journal"
  printf 'global partial\n' > "$GLOBAL_HOME/.claude/CLAUDE.md"

  mkdir -p "$TEST_PROJECT/.rig-backup/.in-progress"
  printf 'project original\n' > "$TEST_PROJECT/CLAUDE.md"
  printf 'project original\n' > "$TEST_PROJECT/.rig-backup/.in-progress/CLAUDE.md"
  printf 'backup\tCLAUDE.md\n' > "$TEST_PROJECT/.rig-backup/.in-progress/.journal"
  printf 'project partial\n' > "$TEST_PROJECT/CLAUDE.md"

  run env HOME="$GLOBAL_HOME" bash "$INSTALLER" \
    --target "$TEST_PROJECT" --project-name Test --tracking repo \
    --global-agent claude --project-agent claude --recover

  [ "$status" -eq 0 ]
  grep -Fxq 'global original' "$GLOBAL_HOME/.claude/CLAUDE.md"
  grep -Fxq 'project original' "$TEST_PROJECT/CLAUDE.md"
  [ ! -e "$GLOBAL_HOME/.claude/.rig-backup/.in-progress" ]
  [ ! -e "$TEST_PROJECT/.rig-backup/.in-progress" ]
  [[ "$output" == *"Interrupted upgrade restored"* ]] || return 1
}

@test "recover exits cleanly after a global-only transaction" {
  GLOBAL_HOME="$TEMP_DIR/home"
  mkdir -p "$GLOBAL_HOME/.claude/.rig-backup/.in-progress"
  printf 'global original\n' > "$GLOBAL_HOME/.claude/CLAUDE.md"
  printf 'global original\n' > "$GLOBAL_HOME/.claude/.rig-backup/.in-progress/CLAUDE.md"
  printf 'backup\tCLAUDE.md\n' > "$GLOBAL_HOME/.claude/.rig-backup/.in-progress/.journal"
  printf 'global partial\n' > "$GLOBAL_HOME/.claude/CLAUDE.md"

  run env HOME="$GLOBAL_HOME" bash "$INSTALLER" \
    --global-only --global-agent claude --recover

  [ "$status" -eq 0 ]
  grep -Fxq 'global original' "$GLOBAL_HOME/.claude/CLAUDE.md"
  [ ! -e "$GLOBAL_HOME/.claude/.rig-backup/.in-progress" ]
  [[ "$output" == *"Recovery complete."* ]] || return 1
}

@test "a global-agent-codex upgrade never leaves an orphaned in-progress transaction (retro-audit finding, found by the whole-branch review before merge)" {
  # Root cause: BACKUP_DIR="" between the global and project layers was
  # unconditional -- it never checked whether a transaction was still
  # active before wiping the pointer needed to finalize it. This was
  # reachable before this fix too (in principle, for any layer-boundary
  # transaction left open), but making upgrade_prepare_mutation()'s
  # missing-destination branch actually open a transaction (a separate fix
  # in this same audit) made it concretely reachable via
  # install-targets.json's first-ever write, right after the global Codex
  # skills loop's own transaction. Confirmed live on a real, previously-
  # installed machine: this exact scenario left a stale .in-progress
  # sitting unfinalized for days, invisibly, until the next such run hit it
  # and refused with "interrupted upgrade transaction exists... recovery is
  # required" -- on a completely clean, otherwise-successful upgrade.
  local fake_home="$TEMP_DIR/fake-home-codex"
  mkdir -p "$fake_home"

  run env HOME="$fake_home" bash "$INSTALLER" \
    --global-only --global-agent codex --strategy upgrade
  [ "$status" -eq 0 ]
  [ ! -e "$fake_home/.rig-backup/.in-progress" ]

  # The real-world symptom: a second, otherwise-unrelated run must still
  # succeed -- it must not hit a phantom "interrupted transaction" left by
  # the first.
  run env HOME="$fake_home" bash "$INSTALLER" \
    --global-only --global-agent codex --strategy upgrade
  [ "$status" -eq 0 ]
  [ ! -e "$fake_home/.rig-backup/.in-progress" ]
}

# ── Issue #444, lane 444-F: transaction coverage for direct-writer mutations ──
#
# Before this lane, upgrade_prepare_mutation() only classified a destination
# (missing/regular-file/conflict) for the smaller set of mutations that write
# a destination in place rather than going through copy_file() — settings.json
# smart-merges (in the moved-project/SubagentStart/[REPO_ROOT] rewrite steps),
# .rigpath, .rig/VERSION, .codex/config.toml, target-state metadata, and the
# [BASE_BRANCH]/[Project Name] substitutions. It never called backup_file(),
# so an existing destination at one of these points had nothing recorded to
# roll back to. These tests prove each of those points now journals a backup
# before mutating, and that recovery restores it.

@test "recover restores a customized .claude/settings.json backed up mid-merge" {
  mkdir -p "$TEST_PROJECT/.claude"
  printf '{"hooks":{}}\n' > "$TEST_PROJECT/.claude/settings.json"
  mkdir -p "$TEST_PROJECT/.rig-backup/.in-progress/.claude"
  printf '{"hooks":{}}\n' > "$TEST_PROJECT/.rig-backup/.in-progress/.claude/settings.json"
  printf 'backup\t.claude/settings.json\n' > "$TEST_PROJECT/.rig-backup/.in-progress/.journal"
  printf '{"hooks":{},"partial":true}\n' > "$TEST_PROJECT/.claude/settings.json"

  recover

  [ "$status" -eq 0 ]
  grep -Fxq '{"hooks":{}}' "$TEST_PROJECT/.claude/settings.json"
  [ ! -e "$TEST_PROJECT/.rig-backup/.in-progress" ]
}

@test "upgrade backs up a customized project settings.json before smart-merging it" {
  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking repo --strategy upgrade
  [ "$status" -eq 0 ]

  python3 -c "
import json
p = '$TEST_PROJECT/.claude/settings.json'
d = json.load(open(p))
d.setdefault('permissions', {}).setdefault('allow', []).append('Bash(echo rig-444f-marker:*)')
json.dump(d, open(p, 'w'), indent=2)
"

  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking repo --strategy upgrade
  [ "$status" -eq 0 ]

  # The pre-merge (customized) content must be recoverable from a backup —
  # not just discarded once merge_settings_json() folds it into the new file.
  run grep -rl 'rig-444f-marker' "$TEST_PROJECT/.rig-backup"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "upgrade backs up .rig/VERSION and project target-state metadata before rewriting them" {
  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking repo --strategy upgrade
  [ "$status" -eq 0 ]

  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking repo --strategy upgrade
  [ "$status" -eq 0 ]

  run find "$TEST_PROJECT/.rig-backup" -path '*.rig/VERSION'
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  run find "$TEST_PROJECT/.rig-backup" -path '*.rig/install-targets.json'
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "upgrade backs up .rigpath before rewriting it in stealth mode" {
  local rig_ext="$TEMP_DIR/external-rig"
  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking stealth --rig-dir "$rig_ext" --strategy upgrade
  [ "$status" -eq 0 ]

  printf '%s\n' "/tmp/some-other-rig-dir-that-does-not-exist" > "$TEST_PROJECT/.rigpath"

  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking stealth --rig-dir "$rig_ext" --strategy upgrade
  [ "$status" -eq 0 ]

  # .rigpath is corrected back to the real external dir...
  grep -Fxq "$rig_ext" "$TEST_PROJECT/.rigpath"
  # ...and the corrupted value it replaced is recoverable from a backup.
  run grep -rl 'some-other-rig-dir-that-does-not-exist' "$TEST_PROJECT/.rig-backup"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "finalized transactions against the same base never collide within one run" {
  # A single project-layer upgrade run can legitimately open and finalize more
  # than one transaction (e.g. $TARGET-rooted and an external .rig/-rooted
  # base in external/stealth tracking, or $TARGET vs $TARGET/.rig in
  # repo/local tracking via the [BASE_BRANCH] substitution step). BACKUP_TS
  # and $$ are fixed for the whole run, so revisiting a base previously used
  # this run must not make finish_upgrade_transaction() compute a final_dir
  # that already exists — that used to make `mv` nest the new transaction's
  # contents one level inside the old one instead of leaving two clean,
  # independently-readable transaction directories.
  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking repo --strategy upgrade
  [ "$status" -eq 0 ]

  python3 -c "
import json
p = '$TEST_PROJECT/.claude/settings.json'
d = json.load(open(p))
d.setdefault('permissions', {}).setdefault('allow', []).append('Bash(echo rig-444f-marker:*)')
json.dump(d, open(p, 'w'), indent=2)
"

  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking repo --strategy upgrade
  [ "$status" -eq 0 ]

  run find "$TEST_PROJECT/.rig-backup" -name ".in-progress"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
