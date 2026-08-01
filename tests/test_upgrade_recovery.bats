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
