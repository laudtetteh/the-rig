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
  [[ "$output" == *"Interrupted upgrade restored"* ]]
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
  [[ "$output" == *"Unsafe path in interrupted upgrade journal"* ]]
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
  [[ "$output" == *"Unsafe path in interrupted upgrade journal"* ]]
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
  [[ "$output" == *"Interrupted upgrade restored"* ]]
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
  [[ "$output" == *"Recovery complete."* ]]
}
