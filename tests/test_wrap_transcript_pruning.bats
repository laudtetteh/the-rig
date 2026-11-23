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

claude_project_dir() {
  printf '%s/.claude/projects/%s' "$TEST_HOME" "$(printf '%s' "$TEST_REPO" | sed 's|/|-|g')"
}

@test "Claude skips old JSONL because project directory ownership is ambiguous" {
  dir="$(claude_project_dir)"
  other="$TEST_HOME/.claude/projects/other-project"
  mkdir -p "$dir" "$other"
  printf 'not parsed\n' > "$dir/old.jsonl"
  printf 'keep\n' > "$dir/recent.jsonl"
  printf 'keep\n' > "$dir/old.txt"
  printf 'keep other project\n' > "$other/old.jsonl"
  age_files "$dir/old.jsonl" "$dir/old.txt" "$other/old.jsonl"
  printf 'transcript-retention-days: 30\n' > "$TEST_REPO/CLAUDE.md"

  run_pruner claude

  [ "$status" -eq 0 ]
  [ -e "$dir/old.jsonl" ]
  [ -e "$dir/recent.jsonl" ]
  [ -e "$dir/old.txt" ]
  [ -e "$other/old.jsonl" ]
  [[ "$output" == *"Claude project directory mapping can collide"* ]] || return 1
}

@test "Claude collision leaves both repositories' old transcripts untouched" {
  local first="$TEST_ROOT/a-b/c" second="$TEST_ROOT/a/b-c" encoded
  mkdir -p "$first" "$second"
  [[ "$(printf '%s' "$first" | sed 's|/|-|g')" == "$(printf '%s' "$second" | sed 's|/|-|g')" ]] || return 1
  encoded="$(printf '%s' "$first" | sed 's|/|-|g')"
  mkdir -p "$TEST_HOME/.claude/projects/$encoded"
  printf 'could belong to either repository\n' > "$TEST_HOME/.claude/projects/$encoded/old.jsonl"
  age_files "$TEST_HOME/.claude/projects/$encoded/old.jsonl"
  printf 'transcript-retention-days: 30\n' > "$first/CLAUDE.md"
  sed 's/TRANSCRIPT_AGENT="CURRENT_AGENT"/TRANSCRIPT_AGENT="claude"/' \
    "$TEST_ROOT/prune.sh" > "$TEST_ROOT/prune-claude.sh"

  run env HOME="$TEST_HOME" REPO="$first" bash "$TEST_ROOT/prune-claude.sh"

  [ "$status" -eq 0 ]
  [ -e "$TEST_HOME/.claude/projects/$encoded/old.jsonl" ]
  [[ "$output" == *"Claude project directory mapping can collide"* ]] || return 1
}

@test "Codex skips shared sessions and archives despite retention setting" {
  codex_home="$TEST_ROOT/codex home [literal]"
  mkdir -p "$codex_home/sessions/nested" "$codex_home/archived_sessions"
  printf '{malformed rollout contents' > "$codex_home/sessions/nested/old.jsonl"
  printf 'archive\n' > "$codex_home/archived_sessions/old.jsonl"
  age_files "$codex_home/sessions/nested/old.jsonl" "$codex_home/archived_sessions/old.jsonl"
  printf 'transcript-retention-days: 30\n' > "$TEST_REPO/CLAUDE.md"

  run_pruner codex "$codex_home"

  [ "$status" -eq 0 ]
  [ -e "$codex_home/sessions/nested/old.jsonl" ]
  [ -e "$codex_home/archived_sessions/old.jsonl" ]
  [[ "$output" == *"Codex has no documented project-scoped transcript directory"* ]] || return 1
}

@test "Codex leaves default HOME sessions untouched" {
  dir="$TEST_HOME/.codex/sessions"
  mkdir -p "$dir"
  printf 'old\n' > "$dir/old.jsonl"
  age_files "$dir/old.jsonl"
  printf 'transcript-retention-days: 30\n' > "$TEST_REPO/CLAUDE.md"

  run_pruner codex

  [ "$status" -eq 0 ]
  [ -e "$dir/old.jsonl" ]
  [[ "$output" == *"Codex has no documented project-scoped transcript directory"* ]] || return 1
}

@test "Codex does not prune shared archives even with old opt-in setting" {
  codex_home="$TEST_ROOT/codex"
  mkdir -p "$codex_home/sessions" "$codex_home/archived_sessions"
  printf 'active\n' > "$codex_home/sessions/old.jsonl"
  printf 'archive\n' > "$codex_home/archived_sessions/old.jsonl"
  age_files "$codex_home/sessions/old.jsonl" "$codex_home/archived_sessions/old.jsonl"
  printf '%s\n' 'transcript-retention-days: 30' \
    'transcript-retention-include-archived: true' > "$TEST_REPO/CLAUDE.md"

  run_pruner codex "$codex_home"

  [ "$status" -eq 0 ]
  [ -e "$codex_home/sessions/old.jsonl" ]
  [ -e "$codex_home/archived_sessions/old.jsonl" ]
  [[ "$output" == *"Codex has no documented project-scoped transcript directory"* ]] || return 1
}

@test "Claude skips cleanly when project path is missing" {
  printf 'transcript-retention-days: 30\n' > "$TEST_REPO/CLAUDE.md"

  run_pruner claude

  [ "$status" -eq 0 ]
  [[ "$output" == *"Claude project directory mapping can collide"* ]] || return 1
}

@test "disabled persistence retention skips cleanly without touching transcripts" {
  dir="$(claude_project_dir)"
  mkdir -p "$dir"
  printf 'keep\n' > "$dir/old.jsonl"
  age_files "$dir/old.jsonl"

  run_pruner claude

  [ "$status" -eq 0 ]
  [ -e "$dir/old.jsonl" ]
  [[ "$output" == *"transcript persistence retention is disabled"* ]] || return 1
}

@test "Codex home shell metacharacters cannot trigger deletion or shell execution" {
  codex_home="$TEST_ROOT/\$(touch SHOULD_NOT_EXIST); codex"$'\n''sessions-parent'
  mkdir -p "$codex_home/sessions"
  printf 'old\n' > "$codex_home/sessions/old.jsonl"
  age_files "$codex_home/sessions/old.jsonl"
  printf 'transcript-retention-days: 30\n' > "$TEST_REPO/CLAUDE.md"

  run_pruner codex "$codex_home"

  [ "$status" -eq 0 ]
  [ -e "$codex_home/sessions/old.jsonl" ]
  [ ! -e "$TEST_ROOT/SHOULD_NOT_EXIST" ]
}

@test "legacy permission-scan sentinel cannot promote commands from colliding Claude project path" {
  local repo_a="$TEST_ROOT/one/two-three" repo_b="$TEST_ROOT/one-two/three"
  local rig="$TEST_ROOT/rig" transcript_dir block
  mkdir -p "$repo_a/.claude" "$repo_b" "$rig/memory"
  touch "$rig/memory/.fewer-prompts-enabled"
  printf '{"permissions":{"allow":[]}}\n' > "$repo_a/.claude/settings.json"
  transcript_dir="$TEST_HOME/.claude/projects/$(printf '%s' "$repo_b" | sed 's|/|-|g')"
  mkdir -p "$transcript_dir"
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git status"}}]}}' \
    > "$transcript_dir/other-project.jsonl"
  [ "$(printf '%s' "$repo_a" | sed 's|/|-|g')" = "$(printf '%s' "$repo_b" | sed 's|/|-|g')" ]
  block="$(sed -n '/^# permission-scan:start$/,/^# permission-scan:end$/p' "$WRAP")"
  run env HOME="$TEST_HOME" REPO="$repo_a" RIG_DIR="$rig" bash -c "$block"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Permission scan skipped: Claude transcript directory mapping can collide"* ]] || return 1
  [ "$(cat "$repo_a/.claude/settings.json")" = '{"permissions":{"allow":[]}}' ]
  [ -f "$transcript_dir/other-project.jsonl" ]
  [[ "$block" != *"jsonl"* ]] || return 1
}

@test "wrap documents ambiguous Claude mapping and safe Codex skip" {
  grep -Fq 'Never read' "$WRAP"
  grep -Fq 'provider-private rollout contents' "$WRAP"
  grep -Fq 'shared #342/#343 behavior' "$WRAP"
  block="$(sed -n '/^# transcript-pruning:start$/,/^# transcript-pruning:end$/p' "$WRAP")"
  [[ "$block" != *"python"* ]] || return 1
  [[ "$block" != *"jq"* ]] || return 1
  [[ "$block" != *"cat "* ]] || return 1
}
