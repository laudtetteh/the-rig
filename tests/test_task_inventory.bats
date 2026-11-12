#!/usr/bin/env bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  TEST_ROOT="$(mktemp -d)"
  TEST_PROJECT="$TEST_ROOT/project"
  mkdir -p "$TEST_PROJECT/bin" "$TEST_PROJECT/.rig/memory"
  git -C "$TEST_PROJECT" init -q
  cp "$REPO_ROOT/templates/project/bin/rig" "$TEST_PROJECT/bin/rig"
  chmod +x "$TEST_PROJECT/bin/rig"
}

teardown() {
  rm -rf "$TEST_ROOT"
}

write_manifest() {
  local directory="$1"
  shift
  mkdir -p "$directory/memory"
  printf '# The Rig manifest\n' > "$directory/memory/.rig-manifest"
  local rel
  for rel in "$@"; do
    printf '%064d  %s\n' 0 "$rel" >> "$directory/memory/.rig-manifest"
  done
}

write_installed_inventory() {
  write_manifest "$1" \
    .rig/memory/PROGRESS.md \
    .rig/tasks/active/.gitkeep \
    .rig/tasks/done/.gitkeep \
    .rig/tasks/backlog/TASK_example.md
}

write_completed_project_state() {
  printf '{"schema":"https://the-rig.dev/schemas/install-targets/v1","schema_version":1,"layer":"project","agents":["claude"],"updated_by":{"installer_version":"1.29.2"},"project_root":"%s"}\n' "$TEST_PROJECT" \
    > "$1/install-targets.json"
}

@test "task inventory accepts an empty installed in-repo active directory" {
  write_installed_inventory "$TEST_PROJECT/.rig"
  mkdir -p "$TEST_PROJECT/.rig/tasks/active" "$TEST_PROJECT/.rig/tasks/backlog" "$TEST_PROJECT/.rig/tasks/done"

  run "$TEST_PROJECT/bin/rig" task inventory --json

  [ "$status" -eq 0 ]
  [[ "$output" == *'"state":"installed","active_directory":"present"'* ]] || return 1
}

@test "task inventory resolves an external stealth pointer" {
  external="$TEST_ROOT/external-rig"
  printf '%s\n' "$external" > "$TEST_PROJECT/.rigpath"
  write_installed_inventory "$external"
  mkdir -p "$external/tasks/active" "$external/tasks/backlog" "$external/tasks/done"

  run "$TEST_PROJECT/bin/rig" task inventory --json

  [ "$status" -eq 0 ]
  [[ "$output" == *'"state":"installed","active_directory":"present"'* ]] || return 1
  [[ "$output" == *'"rig_dir":"'"$external"'"'* ]] || return 1
}

@test "task inventory recognizes a deliberately omitted component" {
  write_manifest "$TEST_PROJECT/.rig" .rig/memory/PROGRESS.md
  write_completed_project_state "$TEST_PROJECT/.rig"

  run "$TEST_PROJECT/bin/rig" task inventory --json

  [ "$status" -eq 0 ]
  [[ "$output" == *'"state":"omitted","active_directory":"missing"'* ]] || return 1
}

@test "task inventory does not call a partial install an omission" {
  write_manifest "$TEST_PROJECT/.rig" .rig/memory/PROGRESS.md

  run "$TEST_PROJECT/bin/rig" task inventory --json

  [ "$status" -eq 3 ]
  [[ "$output" == *'"state":"ambiguous"'* ]] || return 1
  [[ "$output" == *'without completed project install metadata'* ]] || return 1
}

@test "task inventory rejects a boolean completed-state schema version" {
  write_manifest "$TEST_PROJECT/.rig" .rig/memory/PROGRESS.md
  write_completed_project_state "$TEST_PROJECT/.rig"
  sed 's/"schema_version":1/"schema_version":true/' "$TEST_PROJECT/.rig/install-targets.json" \
    > "$TEST_ROOT/bool-state.json"
  mv "$TEST_ROOT/bool-state.json" "$TEST_PROJECT/.rig/install-targets.json"

  run "$TEST_PROJECT/bin/rig" task inventory --json

  [ "$status" -eq 3 ]
  [[ "$output" == *'"state":"ambiguous"'* ]] || return 1
  [[ "$output" == *'project install metadata is malformed'* ]] || return 1
}

@test "task inventory rejects incomplete project target metadata" {
  write_manifest "$TEST_PROJECT/.rig" .rig/memory/PROGRESS.md
  printf '%s\n' '{"schema":"https://the-rig.dev/schemas/install-targets/v1","schema_version":1,"layer":"project"}' \
    > "$TEST_PROJECT/.rig/install-targets.json"

  run "$TEST_PROJECT/bin/rig" task inventory --json

  [ "$status" -eq 3 ]
  [[ "$output" == *'"state":"ambiguous"'* ]] || return 1
  [[ "$output" == *'project install metadata is malformed'* ]] || return 1
}

@test "task inventory errors when an installed active directory is missing" {
  write_installed_inventory "$TEST_PROJECT/.rig"
  mkdir -p "$TEST_PROJECT/.rig/tasks/backlog" "$TEST_PROJECT/.rig/tasks/done"

  run "$TEST_PROJECT/bin/rig" task inventory --json

  [ "$status" -eq 3 ]
  [[ "$output" == *'"state":"installed","active_directory":"missing"'* ]] || return 1
}

@test "task inventory errors when installed backlog or done directories are missing" {
  write_installed_inventory "$TEST_PROJECT/.rig"
  mkdir -p "$TEST_PROJECT/.rig/tasks/active"

  run "$TEST_PROJECT/bin/rig" task inventory --json

  [ "$status" -eq 3 ]
  [[ "$output" == *'"state":"installed","active_directory":"present"'* ]] || return 1
  [[ "$output" == *'unusable directories: backlog, done'* ]] || return 1
}

@test "task inventory reports a partial manifest as ambiguous" {
  write_manifest "$TEST_PROJECT/.rig" .rig/memory/PROGRESS.md .rig/tasks/active/.gitkeep
  mkdir -p "$TEST_PROJECT/.rig/tasks/active"

  run "$TEST_PROJECT/bin/rig" task inventory --json

  [ "$status" -eq 3 ]
  [[ "$output" == *'"state":"ambiguous"'* ]] || return 1
}

@test "task inventory reports unrecorded task directories as ambiguous" {
  write_manifest "$TEST_PROJECT/.rig" .rig/memory/PROGRESS.md
  mkdir -p "$TEST_PROJECT/.rig/tasks/active"

  run "$TEST_PROJECT/bin/rig" task inventory --json

  [ "$status" -eq 3 ]
  [[ "$output" == *'"state":"ambiguous"'* ]] || return 1
}

@test "task inventory does not infer omission from an empty external pointer" {
  write_manifest "$TEST_PROJECT/.rig" .rig/memory/PROGRESS.md
  write_completed_project_state "$TEST_PROJECT/.rig"
  : > "$TEST_PROJECT/.rigpath"

  run "$TEST_PROJECT/bin/rig" task inventory --json

  [ "$status" -eq 3 ]
  [[ "$output" == *'"state":"ambiguous"'* ]] || return 1
  [[ "$output" == *'.rigpath is empty'* ]] || return 1
}

@test "task inventory rejects multiline or non-file external pointers" {
  write_manifest "$TEST_PROJECT/.rig" .rig/memory/PROGRESS.md
  write_completed_project_state "$TEST_PROJECT/.rig"
  printf 'first\nsecond\n' > "$TEST_PROJECT/.rigpath"

  run "$TEST_PROJECT/bin/rig" task inventory --json
  [ "$status" -eq 3 ]
  [[ "$output" == *'.rigpath is empty or multiline'* ]] || return 1

  rm "$TEST_PROJECT/.rigpath"
  mkdir "$TEST_PROJECT/.rigpath"
  run "$TEST_PROJECT/bin/rig" task inventory --json
  [ "$status" -eq 3 ]
  [[ "$output" == *'.rigpath is not a regular file'* ]] || return 1
}

@test "task inventory preserves spaces and anchors relative pointers from subdirectories" {
  external="$TEST_PROJECT/external rig"
  write_installed_inventory "$external"
  mkdir -p "$external/tasks/active" "$external/tasks/backlog" "$external/tasks/done" "$TEST_PROJECT/subdir"
  printf 'external rig\n' > "$TEST_PROJECT/.rigpath"

  cd "$TEST_PROJECT/subdir"
  run "$TEST_PROJECT/bin/rig" task inventory --json

  [ "$status" -eq 0 ]
  expected="$(cd "$TEST_PROJECT" && pwd -P)/external rig"
  [[ "$output" == *'"rig_dir":"'"$expected"'"'* ]] || return 1
}
