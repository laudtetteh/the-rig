#!/usr/bin/env bats
# Tracker-aware ticket examples (#615): session-naming guidance in /wrap,
# /session-name and /post-merge reads issue-tracking at run time, so a
# Linear (or other tracker) project needs no edit to Rig-owned commands.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  COMMANDS="$REPO_ROOT/templates/project/.claude/commands"
  PROCESS="$REPO_ROOT/templates/project/.rig/processes/POST_MERGE_WORKFLOW.md"
}

@test "naming guidance uses a tracker-neutral REF instead of GitHub-only #N" {
  local file
  for file in "$COMMANDS/wrap.md" "$COMMANDS/session-name.md" "$COMMANDS/post-merge.md" "$PROCESS"; do
    ! grep -Fq 'short-desc #N' "$file" || { echo "GitHub-only format in $file" >&3; return 1; }
    ! grep -Fq '#A–#B' "$file" || { echo "GitHub-only range in $file" >&3; return 1; }
    grep -Fq 'type short-desc REF' "$file" || { echo "no REF format in $file" >&3; return 1; }
  done
}

@test "each naming command reads issue-tracking and defines REF for every supported tracker" {
  local file tracker
  for file in "$COMMANDS/wrap.md" "$COMMANDS/session-name.md" "$COMMANDS/post-merge.md"; do
    grep -Fq 'grep "^issue-tracking:" "$REPO/CLAUDE.md"' "$file" || { echo "no tracker read in $file" >&3; return 1; }
    for tracker in '`github` (or absent) | `#184`' '`linear` | `ENG-184`' '`trello` | `trello:a1B2c3`' \
      '`gus` | `W-1234567`' '`none` | omit it'; do
      grep -Fq "| $tracker" "$file" || { echo "missing $tracker in $file" >&3; return 1; }
    done
  done
}

@test "switching a fresh install to Linear needs no command edits: upgrade skips nothing and both providers carry Linear examples" {
  local project="$BATS_TEST_TMPDIR/linear-project" file
  mkdir -p "$project"
  git -C "$project" init -q
  git -C "$project" commit -q --allow-empty -m init
  run bash "$REPO_ROOT/install.sh" --project-only --target "$project" --project-name Linear \
    --tracking repo --project-agent both --strategy merge
  [ "$status" -eq 0 ]
  python3 - "$project/CLAUDE.md" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
assert "\nissue-tracking: github\n" in text
path.write_text(text.replace("\nissue-tracking: github\n", "\nissue-tracking: linear\n", 1))
PY
  run bash "$REPO_ROOT/install.sh" --project-only --target "$project" --project-name Linear \
    --tracking repo --project-agent both --strategy upgrade
  [ "$status" -eq 0 ]
  [[ "$output" == *"Skipped customized: 0"* ]] || return 1
  grep -q '^issue-tracking: linear$' "$project/CLAUDE.md"
  for file in .claude/commands/session-name.md .claude/commands/wrap.md .claude/commands/post-merge.md \
    .agents/skills/session-name/references/command.md .agents/skills/wrap/references/command.md \
    .agents/skills/post-merge/references/command.md; do
    grep -Fq 'ENG-184' "$project/$file" || { echo "no Linear example in $file" >&3; return 1; }
  done
  # The tracker lookup the commands tell the agent to run must report linear.
  python3 - "$project/.claude/commands/session-name.md" > "$BATS_TEST_TMPDIR/lookup.sh" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
section = text.split("#### Ticket references", 1)[1]
print(re.search(r"```bash\n(.*?)```", section, re.S).group(1))
PY
  run bash -c 'cd "$1/.claude" && bash "$2"' _ "$project" "$BATS_TEST_TMPDIR/lookup.sh"
  [ "$status" -eq 0 ]
  [ "$output" = linear ]
}
