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
  [[ "$output" == *'"ok":true'* ]] || return 1
  [[ "$output" == *'"first_entry_line":9'* ]] || return 1
}

@test "memory validate reports ambiguous markers and never writes" {
  write_valid_memory
  printf '%s\n' '<!-- Add entries above this line, newest first -->' >> "$TEST_PROJECT/.rig/memory/PROGRESS.md"
  before="$(cksum "$TEST_PROJECT/.rig/memory/PROGRESS.md" "$TEST_PROJECT/.rig/memory/ERRORS.md")"

  run "$TEST_PROJECT/bin/rig" memory validate

  [ "$status" -eq 1 ]
  [[ "$output" == *'WARN  PROGRESS.md: marker_duplicated'* ]] || return 1
  [ "$before" = "$(cksum "$TEST_PROJECT/.rig/memory/PROGRESS.md" "$TEST_PROJECT/.rig/memory/ERRORS.md")" ]
}

@test "memory validate rejects non-newest-first entries" {
  write_valid_memory
  sed -i.bak 's/2026-07-30/2026-08-01/' "$TEST_PROJECT/.rig/memory/PROGRESS.md"

  run "$TEST_PROJECT/bin/rig" memory validate --json

  [ "$status" -eq 1 ]
  [[ "$output" == *'entries_not_newest_first'* ]] || return 1
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
  [[ "$output" == *'"changed":["PROGRESS.md","ERRORS.md"]'* ]] || return 1
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
  [[ "$output" == *'format_duplicated'* ]] || return 1
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

@test "memory append-gap follows stealth rig path and writes explicit scope" {
  rig_external="$TEST_ROOT/external rig"
  mkdir -p "$rig_external/memory"
  cat > "$rig_external/memory/RIG_GAPS.md" <<'EOF'
# Rig Gaps

<!-- Add entries below — newest first -->

## [2026-01-01] — older gap
EOF
  printf '%s\n' "$rig_external" > "$TEST_PROJECT/.rigpath"

  run "$TEST_PROJECT/bin/rig" memory append-gap \
    --title "quick add test" \
    --scope rig-core \
    --category workflow \
    --severity medium \
    --workflow "/rig-gaps" \
    --observation "Observed from a focused test." \
    --suggested-fix "Keep the helper structured." \
    --json

  [ "$status" -eq 0 ]
  [[ "$output" == *'"ok":true'* ]] || return 1
  grep -Fq "## [" "$rig_external/memory/RIG_GAPS.md"
  grep -Fq "**Scope**: rig-core" "$rig_external/memory/RIG_GAPS.md"
  grep -Fq "Observed from a focused test." "$rig_external/memory/RIG_GAPS.md"
  [ "$(grep -nF 'quick add test' "$rig_external/memory/RIG_GAPS.md" | cut -d: -f1)" -lt "$(grep -nF 'older gap' "$rig_external/memory/RIG_GAPS.md" | cut -d: -f1)" ]
}

@test "memory append-gap refuses duplicated insertion markers without writing" {
  gaps="$TEST_PROJECT/.rig/memory/RIG_GAPS.md"
  cat > "$gaps" <<'EOF'
# Rig Gaps

<!-- Add entries below — newest first -->
<!-- Add entries below — newest first -->
EOF
  before="$(cksum "$gaps")"

  run "$TEST_PROJECT/bin/rig" memory append-gap \
    --title "ambiguous gap" \
    --scope project \
    --observation "Should not write." \
    --json

  [ "$status" -eq 1 ]
  [[ "$output" == *'"reason":"marker_ambiguous"'* || "$output" == *'"reason": "marker_ambiguous"'* ]] || return 1
  [ "$before" = "$(cksum "$gaps")" ]
}

@test "memory append-progress inserts above marker and preserves sid" {
  write_valid_memory

  run "$TEST_PROJECT/bin/rig" memory append-progress \
    --title "focused progress" \
    --body "Focused body." \
    --sid "abc-123" \
    --json

  [ "$status" -eq 0 ]
  [[ "$output" == *'"ok":true'* ]] || return 1
  progress="$TEST_PROJECT/.rig/memory/PROGRESS.md"
  grep -Fq "<!-- sid:abc-123 -->" "$progress"
  [ "$(grep -nF 'focused progress' "$progress" | cut -d: -f1)" -lt "$(grep -nF '<!-- Add entries above this line, newest first -->' "$progress" | cut -d: -f1)" ]
}

@test "memory append-progress refuses duplicated insertion markers without writing" {
  write_valid_memory
  progress="$TEST_PROJECT/.rig/memory/PROGRESS.md"
  printf '%s\n' '<!-- Add entries above this line, newest first -->' >> "$progress"
  before="$(cksum "$progress")"

  run "$TEST_PROJECT/bin/rig" memory append-progress \
    --title "ambiguous progress" \
    --body "Should not be written." \
    --json

  [ "$status" -eq 1 ]
  [[ "$output" == *'"reason":"marker_ambiguous"'* || "$output" == *'"reason": "marker_ambiguous"'* ]] || return 1
  [ "$before" = "$(cksum "$progress")" ]
}

@test "memory write-snapshot atomically replaces context snapshot" {
  printf '# Old\n' > "$TEST_PROJECT/.rig/memory/CONTEXT_SNAPSHOT.md"
  printf '# New snapshot\n\nBody without trailing newline' > "$TEST_ROOT/new-snapshot.md"

  run "$TEST_PROJECT/bin/rig" memory write-snapshot --file "$TEST_ROOT/new-snapshot.md" --json

  [ "$status" -eq 0 ]
  [[ "$output" == *'"ok":true'* ]] || return 1
  SNAPSHOT="$TEST_PROJECT/.rig/memory/CONTEXT_SNAPSHOT.md" SOURCE="$TEST_ROOT/new-snapshot.md" \
    python3 -c 'import os; assert open(os.environ["SNAPSHOT"]).read() == open(os.environ["SOURCE"]).read() + "\n"'
}

@test "memory write-snapshot accepts stdin content despite Python heredoc wrapper" {
  printf '# Old\n' > "$TEST_PROJECT/.rig/memory/CONTEXT_SNAPSHOT.md"

  run bash -c 'printf "%s" "# Stdin snapshot"$'\''\n\nBody'\'' | "$1" memory write-snapshot --stdin --json' _ "$TEST_PROJECT/bin/rig"

  [ "$status" -eq 0 ]
  [[ "$output" == *'"ok":true'* ]] || return 1
  grep -Fq "# Stdin snapshot" "$TEST_PROJECT/.rig/memory/CONTEXT_SNAPSHOT.md"
  grep -Fq "Body" "$TEST_PROJECT/.rig/memory/CONTEXT_SNAPSHOT.md"
}
