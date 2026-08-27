#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  COMMAND="$REPO_ROOT/templates/project/.claude/commands/rig-gaps.md"
  TEST_HOME="$(mktemp -d "${BATS_TEST_TMPDIR:-/tmp}/rig-gaps-home.XXXXXX")"
  COLLECTOR="$TEST_HOME/collector.sh"

  awk '
    /<!-- rig-gaps-collector:start -->/ { wanted = 1; next }
    wanted && /^```bash$/ { code = 1; next }
    code && /^```$/ { exit }
    code { print }
  ' "$COMMAND" > "$COLLECTOR"
  chmod +x "$COLLECTOR"
}

teardown() {
  rm -rf "$TEST_HOME"
}

write_gap_log() {
  project="$1"
  content="$2"
  mkdir -p "$TEST_HOME/.rig/projects/$project/memory"
  printf '%s\n' "$content" > "$TEST_HOME/.rig/projects/$project/memory/RIG_GAPS.md"
}

@test "collector groups near-identical titles within scope and routes distinct scopes" {
  write_gap_log alpha '## [2026-07-30] — Hook blocks safe command

**Category**: friction
**Severity**: annoying
**Scope**: rig-core
**Observation**: alpha observation'
  write_gap_log beta '## [2026-07-31] — hook blocks safe command!!!

**Category**: bug
**Severity**: annoying
**Scope**: rig-core
**Observation**: beta observation

## [2026-07-29] — Hook blocks safe command

**Category**: bug
**Severity**: annoying
**Scope**: project
**Observation**: project-local observation'

  run env HOME="$TEST_HOME" bash "$COLLECTOR"

  [ "$status" -eq 0 ]
  [[ "$output" == *"2 unique unsubmitted candidate(s)"* ]] || return 1
  [[ "$output" == *"### [rig-core] Hook blocks safe command"* ]] || return 1
  [[ "$output" == *"Projects: alpha, beta"* ]] || return 1
  [[ "$output" == *"Duplicate matches: 2"* ]] || return 1
  [[ "$output" == *"### [project] Hook blocks safe command"* ]] || return 1
  [[ "$output" == *"route to project owner"* ]] || return 1
}

@test "collector ignores backups and submitted entries while retaining invalid scope" {
  write_gap_log gamma '# Rig Gaps

## Entry format

This heading is documentation, not a gap.

## [2026-07-31] — Missing metadata

**Category**: improvement
**Observation**: scope was omitted

## [2026-07-30] — Already handled [submitted 2026-07-31]

**Scope**: rig-core
**Observation**: do not report'
  mkdir -p "$TEST_HOME/.rig/projects/gamma/backups/memory"
  printf '%s\n' '## [2026-07-31] — Backup-only trap

**Scope**: rig-core' > "$TEST_HOME/.rig/projects/gamma/backups/memory/RIG_GAPS.md"
  printf '%s\n' '## [2026-07-31] — Suffix backup trap

**Scope**: rig-core' > "$TEST_HOME/.rig/projects/gamma/memory/RIG_GAPS.md.bak"

  run env HOME="$TEST_HOME" bash "$COLLECTOR"

  [ "$status" -eq 0 ]
  [[ "$output" == *"1 unique unsubmitted candidate(s)"* ]] || return 1
  [[ "$output" == *"### [needs-review] Missing metadata"* ]] || return 1
  [[ "$output" == *"needs-review (missing or invalid Scope)"* ]] || return 1
  [[ "$output" != *"Entry format"* ]] || return 1
  [[ "$output" != *"Already handled"* ]] || return 1
  [[ "$output" != *"Backup-only trap"* ]] || return 1
  [[ "$output" != *"Suffix backup trap"* ]] || return 1
}

@test "collector exits cleanly when no project logs exist" {
  run env HOME="$TEST_HOME" bash "$COLLECTOR"

  [ "$status" -eq 0 ]
  [[ "$output" == *"No project RIG_GAPS.md files found"* ]] || return 1
}

@test "command documents explicit scope, read-only collection, and no automatic issues" {
  run /usr/bin/grep -F '**Scope**: project | rig-core' "$COMMAND"
  [ "$status" -eq 0 ]

  run /usr/bin/grep -F 'Collector mode is read-only' "$COMMAND"
  [ "$status" -eq 0 ]

  run /usr/bin/grep -F 'Automatic issue creation' "$COMMAND"
  [ "$status" -eq 0 ]
}

@test "command documents validated triage classifications and privacy boundary" {
  run /usr/bin/grep -F '## Triage mode (`--triage`)' "$COMMAND"
  [ "$status" -eq 0 ]

  run /usr/bin/grep -F 'file-new' "$COMMAND"
  [ "$status" -eq 0 ]

  run /usr/bin/grep -F 'covered-open' "$COMMAND"
  [ "$status" -eq 0 ]

  run /usr/bin/grep -F 'needs-more-evidence' "$COMMAND"
  [ "$status" -eq 0 ]

  run /usr/bin/grep -F 'must not mark' "$COMMAND"
  [ "$status" -eq 0 ]
}
