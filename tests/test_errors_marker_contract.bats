#!/usr/bin/env bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
INSTALLER="$REPO_ROOT/install.sh"

setup() {
  TEST_ROOT="$(mktemp -d)"
  TEST_PROJECT="$TEST_ROOT/project"
  mkdir -p "$TEST_PROJECT"
  git -C "$TEST_PROJECT" init -q
  git -C "$TEST_PROJECT" config user.email "test@test.com"
  git -C "$TEST_PROJECT" config user.name "Test"
}

teardown() {
  rm -rf "$TEST_ROOT"
}

run_installer() {
  run bash "$INSTALLER" --project-only \
    --target "$TEST_PROJECT" \
    --project-name "MarkerContract" \
    --tracking repo \
    "$@"
}

assert_marker_contract() {
  local errors_file="$1"
  local marker='<!-- Add new entries below this line, newest first -->'
  local marker_line example_section_line marker_count

  marker_count="$(/usr/bin/grep -Fxc "$marker" "$errors_file")"
  [ "$marker_count" -eq 1 ]
  if /usr/bin/grep -Fq '<!-- Add new entries above this line' "$errors_file"; then return 1; fi

  marker_line="$(/usr/bin/grep -Fn "$marker" "$errors_file" | cut -d: -f1)"
  example_section_line="$(/usr/bin/grep -n '^## Example entry$' "$errors_file" | cut -d: -f1)"
  [ -n "$example_section_line" ]
  [ "$marker_line" -lt "$example_section_line" ]
}

file_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

@test "fresh install puts the ERRORS marker before entries with top-insertion wording" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]

  assert_marker_contract "$TEST_PROJECT/.rig/memory/ERRORS.md"
}

@test "upgrade replaces an unmodified manifest-tracked legacy ERRORS template" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]

  local errors_file="$TEST_PROJECT/.rig/memory/ERRORS.md"
  local manifest="$TEST_PROJECT/.rig/memory/.rig-manifest"
  local legacy_hash manifest_tmp
  manifest_tmp="$TEST_ROOT/manifest"

  sed '/<!-- Add new entries below this line, newest first -->/d' "$errors_file" > "$TEST_ROOT/legacy-errors"
  printf '\n---\n\n<!-- Add new entries above this line, newest first -->\n' >> "$TEST_ROOT/legacy-errors"
  mv "$TEST_ROOT/legacy-errors" "$errors_file"
  legacy_hash="$(file_sha256 "$errors_file")"
  /usr/bin/grep -v '  \.rig/memory/ERRORS\.md$' "$manifest" > "$manifest_tmp"
  printf '%s  .rig/memory/ERRORS.md\n' "$legacy_hash" >> "$manifest_tmp"
  mv "$manifest_tmp" "$manifest"

  run_installer --strategy upgrade
  [ "$status" -eq 0 ]

  assert_marker_contract "$errors_file"
}
