#!/usr/bin/env bats
# Focused contract tests for the PROGRESS.md session-ID format documentation.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
INSTALLER="$REPO_ROOT/install.sh"

setup() {
  TEST_ROOT="$(mktemp -d)"
  TEST_PROJECT="$TEST_ROOT/project"
  mkdir -p "$TEST_PROJECT"
  git -C "$TEST_PROJECT" init -q
  git -C "$TEST_PROJECT" config user.email "test@example.com"
  git -C "$TEST_PROJECT" config user.name "Test"
}

teardown() {
  rm -rf "$TEST_ROOT"
}

validate_progress_sid_contract() {
  local progress_file="$1"
  local uuid_note="Read the current session's UUID from \`/tmp/.rig-session-\${PPID}.uuid\`."

  /usr/bin/grep -Fqx '## [YYYY-MM-DD] — [one-line summary] <!-- sid:UUID -->' "$progress_file" &&
    /usr/bin/grep -Fqx "$uuid_note" "$progress_file"
}

@test "installed PROGRESS.md documents the sid suffix and UUID source" {
  run bash "$INSTALLER" --project-only \
    --target "$TEST_PROJECT" \
    --project-name "ProgressSidContract" \
    --tracking repo \
    --strategy skip
  [ "$status" -eq 0 ]

  validate_progress_sid_contract "$TEST_PROJECT/.rig/memory/PROGRESS.md"
}

@test "contract rejects a format example with no sid suffix" {
  local fixture="$TEST_ROOT/missing-sid.md"
  cp "$REPO_ROOT/templates/project/.rig/memory/PROGRESS.md" "$fixture"
  sed -i.bak 's/ <!-- sid:UUID -->//' "$fixture"

  run validate_progress_sid_contract "$fixture"
  [ "$status" -ne 0 ]
}

@test "contract rejects a malformed sid suffix" {
  local fixture="$TEST_ROOT/malformed-sid.md"
  cp "$REPO_ROOT/templates/project/.rig/memory/PROGRESS.md" "$fixture"
  sed -i.bak 's/<!-- sid:UUID -->/<!-- session:UUID -->/' "$fixture"

  run validate_progress_sid_contract "$fixture"
  [ "$status" -ne 0 ]
}
