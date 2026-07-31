#!/usr/bin/env bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  TEST_ROOT="$(mktemp -d)"
  TEST_PROJECT="$TEST_ROOT/project"
  mkdir -p "$TEST_PROJECT/bin" "$TEST_PROJECT/.rig/memory"
  cp "$REPO_ROOT/templates/project/bin/rig" "$TEST_PROJECT/bin/rig"
  chmod +x "$TEST_PROJECT/bin/rig"
}

teardown() {
  rm -rf "$TEST_ROOT"
}

write_valid_memory() {
  cat > "$TEST_PROJECT/.rig/memory/PROGRESS.md" <<'EOF'
# Progress

## Format

```markdown
## [YYYY-MM-DD] — example
```

## [2026-07-31] — current

## 2026-07-30 — accepted legacy heading

<!-- Add entries above this line, newest first -->
EOF
  cat > "$TEST_PROJECT/.rig/memory/ERRORS.md" <<'EOF'
# Errors

## Format

```markdown
## [YYYY-MM-DD] — example
```

<!-- Add new entries below this line, newest first -->

## [2026-07-31] — current

## 2026-07-29 — accepted legacy heading
EOF
}

@test "memory validate accepts canonical and legacy dated headings and ignores examples" {
  write_valid_memory

  run "$TEST_PROJECT/bin/rig" memory validate --json

  [ "$status" -eq 0 ]
  [[ "$output" == *'"ok":true'* ]]
  [[ "$output" == *'"first_entry_line":9'* ]]
}

@test "memory validate reports ambiguous markers and never writes" {
  write_valid_memory
  printf '%s\n' '<!-- Add entries above this line, newest first -->' >> "$TEST_PROJECT/.rig/memory/PROGRESS.md"
  before="$(cksum "$TEST_PROJECT/.rig/memory/PROGRESS.md" "$TEST_PROJECT/.rig/memory/ERRORS.md")"

  run "$TEST_PROJECT/bin/rig" memory validate

  [ "$status" -eq 1 ]
  [[ "$output" == *'WARN  PROGRESS.md: marker_duplicated'* ]]
  [ "$before" = "$(cksum "$TEST_PROJECT/.rig/memory/PROGRESS.md" "$TEST_PROJECT/.rig/memory/ERRORS.md")" ]
}

@test "memory validate rejects non-newest-first entries" {
  write_valid_memory
  sed -i.bak 's/2026-07-30/2026-08-01/' "$TEST_PROJECT/.rig/memory/PROGRESS.md"

  run "$TEST_PROJECT/bin/rig" memory validate --json

  [ "$status" -eq 1 ]
  [[ "$output" == *'entries_not_newest_first'* ]]
}

@test "memory repair-markers repositions only unambiguous markers" {
  write_valid_memory
  progress="$TEST_PROJECT/.rig/memory/PROGRESS.md"
  errors="$TEST_PROJECT/.rig/memory/ERRORS.md"
  progress_marker='<!-- Add entries above this line, newest first -->'
  errors_marker='<!-- Add new entries below this line, newest first -->'
  grep -vF "$progress_marker" "$progress" > "$TEST_ROOT/progress-without-marker"
  mv "$TEST_ROOT/progress-without-marker" "$progress"
  grep -vF "$errors_marker" "$errors" > "$TEST_ROOT/errors-without-marker"
  mv "$TEST_ROOT/errors-without-marker" "$errors"
  awk -v marker="$progress_marker" '/^## \[2026-07-31\]/{print marker} {print}' \
    "$progress" > "$TEST_ROOT/progress-mispositioned"
  mv "$TEST_ROOT/progress-mispositioned" "$progress"
  printf '\n%s\n' "$errors_marker" >> "$errors"

  run "$TEST_PROJECT/bin/rig" memory repair-markers --json

  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"changed":["PROGRESS.md","ERRORS.md"]'* ]]
  run "$TEST_PROJECT/bin/rig" memory validate
  [ "$status" -eq 0 ]
  [ "$(grep -nF "$progress_marker" "$progress" | cut -d: -f1)" -gt "$(grep -n '^## 2026-07-30' "$progress" | cut -d: -f1)" ]
  [ "$(grep -nF "$errors_marker" "$errors" | cut -d: -f1)" -lt "$(grep -n '^## \[2026-07-31\]' "$errors" | cut -d: -f1)" ]
}

@test "memory repair-markers refuses ambiguous structure without writing" {
  write_valid_memory
  progress="$TEST_PROJECT/.rig/memory/PROGRESS.md"
  progress_marker='<!-- Add entries above this line, newest first -->'
  grep -vF "$progress_marker" "$progress" > "$TEST_ROOT/progress-without-marker"
  awk -v marker="$progress_marker" '/^## \[2026-07-31\]/{print marker} {print}' \
    "$TEST_ROOT/progress-without-marker" > "$progress"
  printf '\n## Format\n' >> "$TEST_PROJECT/.rig/memory/ERRORS.md"
  before="$(cksum "$TEST_PROJECT/.rig/memory/PROGRESS.md" "$TEST_PROJECT/.rig/memory/ERRORS.md")"

  run "$TEST_PROJECT/bin/rig" memory repair-markers --json

  [ "$status" -eq 1 ]
  [[ "$output" == *'format_duplicated'* ]]
  [ "$before" = "$(cksum "$TEST_PROJECT/.rig/memory/PROGRESS.md" "$TEST_PROJECT/.rig/memory/ERRORS.md")" ]
}

@test "memory validation follows a stealth rig path containing spaces" {
  rig_external="$TEST_ROOT/external rig"
  mkdir -p "$rig_external/memory"
  write_valid_memory
  mv "$TEST_PROJECT/.rig/memory/PROGRESS.md" "$rig_external/memory/PROGRESS.md"
  mv "$TEST_PROJECT/.rig/memory/ERRORS.md" "$rig_external/memory/ERRORS.md"
  printf '%s\n' "$rig_external" > "$TEST_PROJECT/.rigpath"

  run "$TEST_PROJECT/bin/rig" memory validate

  [ "$status" -eq 0 ]
}
