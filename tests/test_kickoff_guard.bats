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

@test "kickoff scaffold step surfaces generator refusals and verifies expected files" {
  run /usr/bin/grep -q 'Scaffold command safety gate' "$KICKOFF"
  [ "$status" -eq 0 ]
  run /usr/bin/grep -q 'Capture and inspect the exit status, stdout, and stderr' "$KICKOFF"
  [ "$status" -eq 0 ]
  run /usr/bin/grep -q 'non-empty directory' "$KICKOFF"
  [ "$status" -eq 0 ]
  run /usr/bin/grep -q 'Verify every expected file or directory' "$KICKOFF"
  [ "$status" -eq 0 ]
  run /usr/bin/grep -q 'Do not report kickoff or the scaffold item as' "$KICKOFF"
  [ "$status" -eq 0 ]
}

run_tracker_probe() {
  local probe
  probe="$(sed -n '/# kickoff-tracker-probe-start/,/# kickoff-tracker-probe-end/p' "$KICKOFF")"
  run bash -o pipefail -c "cd \"\$1\" && $probe" _ "$TEST_REPO"
}

@test "kickoff tracker probe: absent issue-tracking field defaults to github" {
  printf '# Project\n' > "$TEST_REPO/CLAUDE.md"
  run_tracker_probe
  [ "$status" -eq 0 ]
  [ "$output" = "github" ]
}

@test "kickoff tracker probe: reads every supported configured tracker" {
  local mode
  for mode in github linear trello gus none; do
    printf '# Project\n\n```\nissue-tracking: %s\n```\n' "$mode" > "$TEST_REPO/CLAUDE.md"
    run_tracker_probe
    [ "$status" -eq 0 ] || return 1
    [ "$output" = "$mode" ] || return 1
  done
}

@test "kickoff: every supported tracker mode has plan, record, and handoff guidance" {
  local mode
  for mode in github linear trello gus none; do
    /usr/bin/grep -q "^| \`$mode\` | \*\*3\. " "$KICKOFF" || return 1
    /usr/bin/grep -q "\`$mode\`" <(sed -n '/^#### 5c\./,/^#### 5d\./p' "$KICKOFF") || return 1
    /usr/bin/grep -q "\`$mode\`" <(sed -n '/^### Step 6/,/^## Notes/p' "$KICKOFF") || return 1
  done
  run /usr/bin/grep -q 'is not a supported tracker' "$KICKOFF"
  [ "$status" -eq 0 ]
}

@test "kickoff: GitHub issue creation is confined to the github tracker mode" {
  run /usr/bin/grep -n 'GitHub issue' "$KICKOFF"
  [ "$status" -eq 0 ]
  local line
  while IFS= read -r line; do
    [[ "$line" == *'`github`'* || "$line" == *'**GitHub issue**'* ]] || {
      printf 'unconditional GitHub wording: %s\n' "$line"
      return 1
    }
  done <<< "$output"
  local total github_only
  total=$(/usr/bin/grep -c 'gh issue create' "$KICKOFF")
  github_only=$(sed -n '/^\*\*`github`:\*\*/,/^\*\*`linear`, `trello`, or `gus`:\*\*/p' "$KICKOFF" \
    | /usr/bin/grep -c 'gh issue create')
  [ "$total" -ge 1 ]
  [ "$total" -eq "$github_only" ]
  run /usr/bin/grep -q 'agent never creates Linear tickets, Trello cards, or GUS work items' "$KICKOFF"
  [ "$status" -eq 0 ]
  run /usr/bin/grep -q 'N/A (issue-tracking: none)' "$KICKOFF"
  [ "$status" -eq 0 ]
}

@test "kickoff: generated Codex skill carries the tracker-aware guidance" {
  local out="$BATS_TEST_TMPDIR/codex-skills"
  run python3 "$REPO_ROOT/installer/generate-codex-skills.py" \
    --output "$out" --base-branch main "$KICKOFF"
  [ "$status" -eq 0 ]
  local skill="$out/kickoff/references/command.md"
  [ -f "$skill" ]
  run /usr/bin/grep -q 'kickoff-tracker-probe-start' "$skill"
  [ "$status" -eq 0 ]
  run /usr/bin/grep -q 'N/A (issue-tracking: none)' "$skill"
  [ "$status" -eq 0 ]
  run /usr/bin/grep -q 'Open GitHub issues #' "$skill"
  [ "$status" -ne 0 ]
}
