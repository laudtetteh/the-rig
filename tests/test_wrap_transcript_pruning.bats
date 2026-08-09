#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  WRAP="$REPO_ROOT/templates/project/.claude/commands/wrap.md"
  TEST_ROOT="$(mktemp -d)"
  TEST_HOME="$TEST_ROOT/home"
  TEST_REPO="$TEST_ROOT/repo"
  mkdir -p "$TEST_HOME" "$TEST_REPO"
  awk '/^# transcript-pruning:start$/ { copy=1 } copy { print } /^# transcript-pruning:end$/ { exit }' "$WRAP" \
    | sed '/^# transcript-pruning:/d' > "$TEST_ROOT/prune.sh"
}

teardown() { rm -rf "$TEST_ROOT"; }

run_pruner() {
  local agent="$1" codex_home="${2:-}"
  sed "s/TRANSCRIPT_AGENT=\"CURRENT_AGENT\"/TRANSCRIPT_AGENT=\"$agent\"/" \
    "$TEST_ROOT/prune.sh" > "$TEST_ROOT/prune-$agent.sh"
  run env HOME="$TEST_HOME" CODEX_HOME="$codex_home" REPO="$TEST_REPO" \
    bash "$TEST_ROOT/prune-$agent.sh"
}

age_files() {
  touch -t 202001010000 "$@"
}

@test "Claude prunes only old JSONL files from its documented project location" {
  dir="$TEST_HOME/.claude/projects/project-one"
  mkdir -p "$dir"
  printf 'not parsed\n' > "$dir/old.jsonl"
  printf 'keep\n' > "$dir/recent.jsonl"
  printf 'keep\n' > "$dir/old.txt"
  age_files "$dir/old.jsonl" "$dir/old.txt"
  printf 'transcript-retention-days: 30\n' > "$TEST_REPO/CLAUDE.md"

  run_pruner claude

  [ "$status" -eq 0 ]
  [ ! -e "$dir/old.jsonl" ]
  [ -e "$dir/recent.jsonl" ]
  [ -e "$dir/old.txt" ]
  [[ "$output" == *"Pruned 1 JSONL transcript file(s)"* ]] || return 1
}

@test "Codex uses configured CODEX_HOME sessions and excludes archives by default" {
  codex_home="$TEST_ROOT/codex home [literal]"
  mkdir -p "$codex_home/sessions/nested" "$codex_home/archived_sessions"
  printf '{malformed rollout contents' > "$codex_home/sessions/nested/old.jsonl"
  printf 'archive\n' > "$codex_home/archived_sessions/old.jsonl"
  age_files "$codex_home/sessions/nested/old.jsonl" "$codex_home/archived_sessions/old.jsonl"
  printf 'transcript-retention-days: 30\n' > "$TEST_REPO/CLAUDE.md"

  run_pruner codex "$codex_home"

  [ "$status" -eq 0 ]
  [ ! -e "$codex_home/sessions/nested/old.jsonl" ]
  [ -e "$codex_home/archived_sessions/old.jsonl" ]
  [[ "$output" == *"Pruned 1 JSONL transcript file(s)"* ]] || return 1
}

@test "Codex defaults to HOME dot-codex sessions" {
  dir="$TEST_HOME/.codex/sessions"
  mkdir -p "$dir"
  printf 'old\n' > "$dir/old.jsonl"
  age_files "$dir/old.jsonl"
  printf 'transcript-retention-days: 30\n' > "$TEST_REPO/CLAUDE.md"

  run_pruner codex

  [ "$status" -eq 0 ]
  [ ! -e "$dir/old.jsonl" ]
  [[ "$output" == *"Pruned 1 JSONL transcript file(s)"* ]] || return 1
}

@test "Codex archives require an explicit retention opt-in" {
  codex_home="$TEST_ROOT/codex"
  mkdir -p "$codex_home/sessions" "$codex_home/archived_sessions"
  printf 'active\n' > "$codex_home/sessions/old.jsonl"
  printf 'archive\n' > "$codex_home/archived_sessions/old.jsonl"
  age_files "$codex_home/sessions/old.jsonl" "$codex_home/archived_sessions/old.jsonl"
  printf '%s\n' 'transcript-retention-days: 30' \
    'transcript-retention-include-archived: true' > "$TEST_REPO/CLAUDE.md"

  run_pruner codex "$codex_home"

  [ "$status" -eq 0 ]
  [ ! -e "$codex_home/sessions/old.jsonl" ]
  [ ! -e "$codex_home/archived_sessions/old.jsonl" ]
  [[ "$output" == *"Pruned 2 JSONL transcript file(s)"* ]] || return 1
}

@test "missing persistence path skips cleanly with an explicit note" {
  printf 'transcript-retention-days: 30\n' > "$TEST_REPO/CLAUDE.md"

  run_pruner codex "$TEST_ROOT/missing codex home"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Transcript pruning skipped missing path:"* ]] || return 1
}

@test "disabled persistence retention skips cleanly without touching transcripts" {
  dir="$TEST_HOME/.claude/projects/project-one"
  mkdir -p "$dir"
  printf 'keep\n' > "$dir/old.jsonl"
  age_files "$dir/old.jsonl"

  run_pruner claude

  [ "$status" -eq 0 ]
  [ -e "$dir/old.jsonl" ]
  [[ "$output" == *"transcript persistence retention is disabled"* ]] || return 1
}

@test "Codex home shell metacharacters remain literal" {
  codex_home="$TEST_ROOT/\$(touch SHOULD_NOT_EXIST); codex"$'\n''sessions-parent'
  mkdir -p "$codex_home/sessions"
  printf 'old\n' > "$codex_home/sessions/old.jsonl"
  age_files "$codex_home/sessions/old.jsonl"
  printf 'transcript-retention-days: 30\n' > "$TEST_REPO/CLAUDE.md"

  run_pruner codex "$codex_home"

  [ "$status" -eq 0 ]
  [ ! -e "$codex_home/sessions/old.jsonl" ]
  [ ! -e "$TEST_ROOT/SHOULD_NOT_EXIST" ]
}

@test "wrap documents path-only Codex pruning and shared identity behavior" {
  grep -Fq 'never read or parse their rollout contents' "$WRAP"
  grep -Fq 'shared #342/#343 behavior' "$WRAP"
  block="$(sed -n '/^# transcript-pruning:start$/,/^# transcript-pruning:end$/p' "$WRAP")"
  [[ "$block" != *"python"* ]] || return 1
  [[ "$block" != *"jq"* ]] || return 1
  [[ "$block" != *"cat "* ]] || return 1
}
