#!/usr/bin/env bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
KICKOFF="$REPO_ROOT/templates/project/.claude/commands/kickoff.md"

setup() {
  TEST_REPO="$BATS_TEST_TMPDIR/project"
  mkdir -p "$TEST_REPO"
  git -C "$TEST_REPO" init -q
  git -C "$TEST_REPO" config user.email test@example.com
  git -C "$TEST_REPO" config user.name "Kickoff Guard Test"
}

commit_file() {
  local name="$1"
  printf '%s\n' "$name" > "$TEST_REPO/$name"
  git -C "$TEST_REPO" add "$name"
  git -C "$TEST_REPO" commit -qm "$name"
}

run_probe() {
  local probe
  probe="$(sed -n '/# kickoff-maturity-probe-start/,/# kickoff-maturity-probe-end/p' "$KICKOFF")"
  run bash -o pipefail -c "cd \"\$1\" && $probe" _ "$TEST_REPO"
}

@test "kickoff guard: genuine greenfield repository has no maturity signals" {
  run_probe
  [ "$status" -eq 0 ]
  [ "$output" = "commits=0 release_tags=0 claude_filled=0 backlog_nonempty=0 signals=0" ]
}

@test "kickoff guard: absent git metadata and project files are safe" {
  TEST_REPO="$BATS_TEST_TMPDIR/not-a-repository"
  mkdir -p "$TEST_REPO"
  run_probe
  [ "$status" -eq 0 ]
  [ "$output" = "commits=0 release_tags=0 claude_filled=0 backlog_nonempty=0 signals=0" ]
}

@test "kickoff guard: a lone commit-history signal remains ambiguous" {
  commit_file one
  commit_file two
  run_probe
  [ "$status" -eq 0 ]
  [[ "$output" == *"commits=2"* ]] || return 1
  [[ "$output" == *"signals=1" ]] || return 1
}

@test "kickoff guard: shallow history does not falsely look established" {
  commit_file one
  commit_file two
  commit_file three
  local shallow="$BATS_TEST_TMPDIR/shallow"
  git clone -q --depth 1 "file://$TEST_REPO" "$shallow"
  TEST_REPO="$shallow"
  run_probe
  [ "$status" -eq 0 ]
  [ "$output" = "commits=1 release_tags=0 claude_filled=0 backlog_nonempty=0 signals=0" ]
}

@test "kickoff guard: release tags are detected safely" {
  commit_file one
  git -C "$TEST_REPO" tag v1.2.3
  run_probe
  [ "$status" -eq 0 ]
  [[ "$output" == *"release_tags=1"* ]] || return 1
  [[ "$output" == *"signals=1" ]] || return 1
}

@test "kickoff guard: semver-like glob matches are rejected" {
  commit_file one
  git -C "$TEST_REPO" tag v1foo.2bar.3bad
  git -C "$TEST_REPO" tag v1.2.3-rc1
  git -C "$TEST_REPO" tag release-v1.2.3
  run_probe
  [ "$status" -eq 0 ]
  [[ "$output" == *"release_tags=0"* ]] || return 1
  [[ "$output" == *"signals=0" ]] || return 1
}

@test "kickoff guard: placeholder CLAUDE.md is not considered filled" {
  printf '# [PROJECT_NAME]\n' > "$TEST_REPO/CLAUDE.md"
  run_probe
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude_filled=0"* ]] || return 1
}

@test "kickoff guard: filled CLAUDE.md is a maturity signal" {
  printf '# Acme project\n' > "$TEST_REPO/CLAUDE.md"
  run_probe
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude_filled=1"* ]] || return 1
  [[ "$output" == *"signals=1" ]] || return 1
}

@test "kickoff guard: backlog files are detected through .rigpath" {
  local external_rig="$BATS_TEST_TMPDIR/external-rig"
  mkdir -p "$external_rig/tasks/backlog"
  printf '%s\n' "$external_rig" > "$TEST_REPO/.rigpath"
  touch "$external_rig/tasks/backlog/feat-one.md"
  run_probe
  [ "$status" -eq 0 ]
  [[ "$output" == *"backlog_nonempty=1"* ]] || return 1
  [[ "$output" == *"signals=1" ]] || return 1
}

@test "kickoff guard: multiple independent signals identify an established repository" {
  commit_file one
  commit_file two
  printf '# Acme project\n' > "$TEST_REPO/CLAUDE.md"
  mkdir -p "$TEST_REPO/.rig/tasks/done"
  touch "$TEST_REPO/.rig/tasks/done/feat-shipped.md"
  run_probe
  [ "$status" -eq 0 ]
  [[ "$output" == *"commits=2"* ]] || return 1
  [[ "$output" == *"claude_filled=1"* ]] || return 1
  [[ "$output" == *"backlog_nonempty=1"* ]] || return 1
  [[ "$output" == *"signals=3" ]] || return 1
}

@test "kickoff guard: explicit confirmation and task handoff are required" {
  run /usr/bin/grep -q 'exact explicit confirmation' "$KICKOFF"
  [ "$status" -eq 0 ]
  run /usr/bin/grep -q 'continue kickoff' "$KICKOFF"
  [ "$status" -eq 0 ]
  run /usr/bin/grep -q 'hand off directly to `/task`' "$KICKOFF"
  [ "$status" -eq 0 ]
}
