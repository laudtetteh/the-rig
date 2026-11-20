#!/usr/bin/env bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
KICKOFF="$REPO_ROOT/templates/project/.claude/commands/kickoff.md"

setup() {
  TEST_REPO="$BATS_TEST_TMPDIR/project"
  mkdir -p "$TEST_REPO/bin"
  cp "$REPO_ROOT/templates/project/bin/rig-tracker-config.py" "$TEST_REPO/bin/rig-tracker-config.py"
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

run_github_preflight() {
  local probe
  probe="$(sed -n '/# kickoff-github-preflight-start/,/# kickoff-github-preflight-end/p' "$KICKOFF")"
  run bash -o pipefail -c "cd \"\$1\" && $probe" _ "$TEST_REPO"
}

# A stand-in gh CLI: FAKE_GH_AUTH=fail fails auth, FAKE_GH_REPO=fail fails repo
# view, FAKE_GH_LABELS lists existing label names (newline-separated),
# FAKE_GH_EXTRA_LABELS appends that many filler labels after them, and
# FAKE_GH_LABEL_CREATE=exists|fail makes label creation fail that way.
install_fake_gh() {
  local bin="$BATS_TEST_TMPDIR/fake-bin"
  mkdir -p "$bin"
  cat > "$bin/gh" <<'GH'
#!/usr/bin/env bash
if [[ "$1" == "auth" ]]; then
  [[ "${FAKE_GH_AUTH:-ok}" == "ok" ]] || exit 1
  exit 0
fi
if [[ "$1" == "repo" ]]; then
  [[ "${FAKE_GH_REPO:-ok}" == "ok" ]] || exit 1
  printf 'owner/project\n'
  exit 0
fi
if [[ "$1" == "label" && "$2" == "create" ]]; then
  if [[ "${FAKE_GH_LABEL_CREATE:-ok}" == "exists" ]]; then
    printf 'label with name "type: feat" already exists; use `--force` to update\n' >&2
    exit 1
  fi
  if [[ "${FAKE_GH_LABEL_CREATE:-ok}" == "fail" ]]; then
    printf 'HTTP 403: Resource not accessible by integration\n' >&2
    exit 1
  fi
  exit 0
fi
if [[ "$1" == "label" ]]; then
  printf '%s\n' "${FAKE_GH_LABELS:-}"
  i=0
  while (( i < ${FAKE_GH_EXTRA_LABELS:-0} )); do
    printf 'filler-label-%s\n' "$i"
    i=$((i + 1))
  done
  exit 0
fi
exit 1
GH
  chmod +x "$bin/gh"
  PATH="$bin:$PATH"
  export PATH
}

run_type_label_step() {
  local step
  step="$(sed -n '/# kickoff-type-label-start/,/# kickoff-type-label-end/p' "$KICKOFF")"
  run bash -o pipefail -c "cd \"\$1\" && $step" _ "$TEST_REPO"
}

kickoff_section() {
  sed -n "/$1/,/$2/p" "$KICKOFF"
}

@test "kickoff tracker probe: absent fields default to github with user-created issues" {
  printf '# Project\n' > "$TEST_REPO/CLAUDE.md"
  run_tracker_probe
  [ "$status" -eq 0 ]
  [ "$output" = "tracking=github creator=user" ]
}

@test "kickoff tracker probe: reads presets and arbitrary trackers through the shared parser" {
  local mode
  for mode in github linear trello gus none jira; do
    printf '# Project\n\n```\nissue-tracking: %s\n```\n\n```\nissue-creator: agent\n```\n' "$mode" > "$TEST_REPO/CLAUDE.md"
    run_tracker_probe
    [ "$status" -eq 0 ] || return 1
    [ "$output" = "tracking=$mode creator=agent" ] || return 1
  done
  printf "issue-tracking: Jira # team tracker\nissue-ref-pattern: '[A-Z]+-[0-9]+'\nissue-creator: agent\n" > "$TEST_REPO/CLAUDE.md"
  run_tracker_probe
  [ "$status" -eq 0 ]
  [ "$output" = "tracking=jira creator=agent" ]
  run python3 "$TEST_REPO/bin/rig-tracker-config.py" validate-ref "$TEST_REPO/CLAUDE.md" APP-123
  [ "$status" -eq 0 ]
}

@test "fresh Jira install runs kickoff probe and ships generic Claude and Codex guidance" {
  local project="$BATS_TEST_TMPDIR/jira-installed"
  mkdir -p "$project"
  git -C "$project" init -q
  run bash "$REPO_ROOT/install.sh" --project-only --target "$project" \
    --project-name Jira --tracking repo --project-agent both --strategy merge
  [ "$status" -eq 0 ]
  python3 - "$project/CLAUDE.md" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
assert "\nissue-tracking: github\n" in text
path.write_text(text.replace("\nissue-tracking: github\n",
                             "\nissue-tracking: jira\nissue-ref-pattern: '[A-Z]+-[0-9]+'\n", 1))
PY
  TEST_REPO="$project"
  KICKOFF="$project/.claude/commands/kickoff.md"
  run_tracker_probe
  [ "$status" -eq 0 ]
  [ "$output" = "tracking=jira creator=user" ]
  run python3 "$project/bin/rig-tracker-config.py" validate-ref "$project/CLAUDE.md" APP-123
  [ "$status" -eq 0 ]
  grep -Fq 'Any other `tracking=` value' "$KICKOFF"
  grep -Fq 'Any other `tracking=` value' "$project/.agents/skills/kickoff/references/command.md"
}

@test "kickoff: every tracker mode has plan, record, and handoff guidance" {
  local mode
  for mode in github-agent github-user github-deferred tracker-user none; do
    /usr/bin/grep -q "^| \`$mode\` | \*\*3\. " "$KICKOFF" || return 1
    kickoff_section '^#### 5c\.' '^#### 5d\.' | /usr/bin/grep -q "\`$mode\`" || return 1
    kickoff_section '^### Step 6' '^## Notes' | /usr/bin/grep -q "\`$mode\`" || return 1
  done
  run /usr/bin/grep -q 'Any other `tracking=` value' "$KICKOFF"
  [ "$status" -eq 0 ]
}

@test "kickoff: GitHub issue creation is confined to the agent-creator github mode" {
  local total agent_only
  total=$(/usr/bin/grep -c 'gh issue create' "$KICKOFF")
  agent_only=$(kickoff_section '^\*\*`github-agent`:\*\*' '^\*\*`github-user` or `tracker-user`:\*\*' \
    | /usr/bin/grep -c 'gh issue create')
  [ "$total" -ge 1 ]
  [ "$total" -eq "$agent_only" ]
  run /usr/bin/grep -q 'never creates tickets for another tracker' "$KICKOFF"
  [ "$status" -eq 0 ]
  run /usr/bin/grep -q 'never creates GitHub issues in mode `github-user`' "$KICKOFF"
  [ "$status" -eq 0 ]
  run /usr/bin/grep -q 'N/A (issue-tracking: none)' "$KICKOFF"
  [ "$status" -eq 0 ]
  run /usr/bin/grep -q "the user's \*\*go\*\* in Step 4 authorizes these)" "$KICKOFF"
  [ "$status" -ne 0 ]
}

@test "kickoff github preflight: missing git remote defers issue creation" {
  install_fake_gh
  run_github_preflight
  [ "$status" -eq 0 ]
  [[ "$output" == *"preflight: no git remote is configured"* ]] || return 1
  [[ "$output" == *"github_ready=0 type_feat_label=unknown" ]] || return 1
}

@test "kickoff github preflight: unauthenticated gh defers issue creation" {
  git -C "$TEST_REPO" remote add origin https://github.com/owner/project.git
  install_fake_gh
  FAKE_GH_AUTH=fail run_github_preflight
  [ "$status" -eq 0 ]
  [[ "$output" == *"preflight: gh is not authenticated"* ]] || return 1
  [[ "$output" == *"github_ready=0"* ]] || return 1
}

@test "kickoff github preflight: unreachable GitHub repository defers issue creation" {
  git -C "$TEST_REPO" remote add origin https://example.com/owner/project.git
  install_fake_gh
  FAKE_GH_REPO=fail run_github_preflight
  [ "$status" -eq 0 ]
  [[ "$output" == *"preflight: the git remote is not a GitHub repository"* ]] || return 1
  [[ "$output" == *"github_ready=0"* ]] || return 1
}

@test "kickoff github preflight: fresh repository reports the missing type label" {
  git -C "$TEST_REPO" remote add origin https://github.com/owner/project.git
  install_fake_gh
  FAKE_GH_LABELS='bug' run_github_preflight
  [ "$status" -eq 0 ]
  [ "$output" = "github_ready=1 type_feat_label=missing" ]
  FAKE_GH_LABELS=$'bug\ntype: feat' run_github_preflight
  [ "$status" -eq 0 ]
  [ "$output" = "github_ready=1 type_feat_label=present" ]
}

@test "kickoff: issue creation creates missing labels and reports partial failures" {
  local agent_block
  agent_block="$(kickoff_section '^\*\*`github-agent`:\*\*' '^\*\*`github-user` or `tracker-user`:\*\*')"
  [[ "$agent_block" == *'gh label create "type: feat" --color "#0075ca" --description "New feature"'* ]] || return 1
  [[ "$agent_block" == *'never invent a label'* ]] || return 1
  [[ "$agent_block" == *'which issue numbers were already created'* ]] || return 1
  [[ "$agent_block" == *'which task files still need an issue'* ]] || return 1
  run /usr/bin/grep -q 'gh label create "type: feat" --color "#0075ca" --description "New feature"' \
    "$REPO_ROOT/templates/project/.rig/processes/SHIP_WORKFLOW.md"
  [ "$status" -eq 0 ]
}

@test "kickoff requires approval for each exact GitHub label and issue write" {
  local agent_block
  agent_block="$(kickoff_section '^\*\*`github-agent`:\*\*' '^\*\*`github-user` or `tracker-user`:\*\*')"
  [[ "$agent_block" == *'Step 4 **go** authorizes only local scaffolding'* ]] || return 1
  [[ "$agent_block" == *'target repository, name `type: feat`, color'* ]] || return 1
  [[ "$agent_block" == *'Ask for approval to create this exact'* ]] || return 1
  [[ "$agent_block" == *'exact title, full body, and every label'* ]] || return 1
  [[ "$agent_block" == *'If declined, set'* ]] || return 1
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
  run /usr/bin/grep -q 'kickoff-github-preflight-start' "$skill"
  [ "$status" -eq 0 ]
  run /usr/bin/grep -q 'N/A (issue-tracking: none)' "$skill"
  [ "$status" -eq 0 ]
  run /usr/bin/grep -q 'bin/rig-tracker-config.py' "$skill"
  [ "$status" -eq 0 ]
}

@test "kickoff github preflight: a present label listed first survives pipefail in a large label set" {
  git -C "$TEST_REPO" remote add origin https://github.com/owner/project.git
  install_fake_gh
  FAKE_GH_LABELS='type: feat' FAKE_GH_EXTRA_LABELS=5000 run_github_preflight
  [ "$status" -eq 0 ]
  [ "$output" = "github_ready=1 type_feat_label=present" ]
}

@test "kickoff type label step: an already-existing label counts as success" {
  install_fake_gh
  FAKE_GH_LABEL_CREATE=exists run_type_label_step
  [ "$status" -eq 0 ]
  [[ "$output" == *"type_feat_ready=1"* ]] || return 1
  FAKE_GH_LABEL_CREATE=ok run_type_label_step
  [ "$status" -eq 0 ]
  [ "$output" = "type_feat_ready=1" ]
}

@test "kickoff type label step: other label creation failures are surfaced" {
  install_fake_gh
  FAKE_GH_LABEL_CREATE=fail run_type_label_step
  [ "$status" -eq 0 ]
  [[ "$output" == *"HTTP 403"* ]] || return 1
  [[ "$output" == *"type_feat_ready=0" ]] || return 1
}

@test "kickoff hand-off requires tracker references before /run when any task is TBD" {
  local handoff
  handoff="$(kickoff_section '^### Step 6' '^## Notes')"
  [[ "$handoff" == *'If any task file is at `TBD`'* ]] || return 1
  [[ "$handoff" == *'Before `/run`, every task file at `TBD` needs a'* ]] || return 1
  [[ "$handoff" == *'NEW_TASK_WORKFLOW.md` stops on `TBD`'* ]] || return 1
  [[ "$handoff" == *'run `/task` for it'* ]] || return 1
  [[ "$handoff" == *'If no task file is at `TBD`'* ]] || return 1
}

@test "kickoff tracker blocks use portable grep" {
  local blocks
  blocks="$(sed -n '/# kickoff-tracker-probe-start/,/# kickoff-tracker-probe-end/p;/# kickoff-github-preflight-start/,/# kickoff-github-preflight-end/p;/# kickoff-type-label-start/,/# kickoff-type-label-end/p' "$KICKOFF")"
  [[ "$blocks" == *grep* ]] || return 1
  [[ "$blocks" != */usr/bin/grep* ]] || return 1
}
