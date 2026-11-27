#!/usr/bin/env bats

setup() {
  export REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export CASE_DIR="$BATS_TEST_TMPDIR/project"
  mkdir -p "$CASE_DIR/bin" "$CASE_DIR/.rig/memory/sessions/done"
  cp "$REPO_ROOT/templates/project/bin/rig" "$CASE_DIR/bin/rig"
  cp "$REPO_ROOT/templates/project/bin/rig-path.py" "$CASE_DIR/bin/rig-path.py"
  cp "$REPO_ROOT/templates/project/bin/rig-session-resolve.py" "$CASE_DIR/bin/rig-session-resolve.py"
  chmod +x "$CASE_DIR/bin/rig"
  git -C "$CASE_DIR" init -q
  git -C "$CASE_DIR" checkout -q -b feat/session-skills
  unset RIG_SESSION_FILE RIG_SESSION_ANCHOR RIG_SESSION_PID CODEX_THREAD_ID CLAUDE_CODE_SESSION_ID
}

bind() {
  "$CASE_DIR/bin/rig" session bind --agent claude --native-session-id "$1" --source startup
}

field() {
  printf '%s' "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$2"
}

@test "session decision ledger is private, session-scoped, and closes answered entries" {
  local first second first_file second_file first_anchor
  first=$(bind native-first); second=$(bind native-second)
  first_file=$(field "$first" session_file); second_file=$(field "$second" session_file)
  first_anchor=$(field "$first" anchor)

  run env RIG_SESSION_FILE="$first_file" "$CASE_DIR/bin/rig" session decision append --question 'Should the handoff include the draft PR?' --json
  [ "$status" -eq 0 ]
  local decision_id
  decision_id=$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["decision"]["id"])')
  [ -f "$CASE_DIR/.rig/memory/session-decisions/$first_anchor.json" ]
  [ "$(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$CASE_DIR/.rig/memory/session-decisions/$first_anchor.json")" = "0o600" ]

  run env RIG_SESSION_FILE="$second_file" "$CASE_DIR/bin/rig" session decision list --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["decisions"]))')" -eq 0 ]
  run env RIG_SESSION_FILE="$first_file" "$CASE_DIR/bin/rig" session decision list --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'Should the handoff include the draft PR?'* ]] || return 1
  run env RIG_SESSION_FILE="$first_file" "$CASE_DIR/bin/rig" session decision close --id "$decision_id" --answer 'Yes, include the link.' --json
  [ "$status" -eq 0 ]
  run env RIG_SESSION_FILE="$first_file" "$CASE_DIR/bin/rig" session decision list --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["decisions"]))')" -eq 0 ]
  grep -q 'session-decisions/' "$REPO_ROOT/templates/project/.rig/memory/.gitignore"
}

@test "session decision ledger resolves an external stealth rigpath" {
  local external result session_file anchor
  external="$BATS_TEST_TMPDIR/external-rig"
  mkdir -p "$external"
  printf '%s\n' "$external" > "$CASE_DIR/.rigpath"

  result=$(bind stealth-ledger)
  session_file=$(field "$result" session_file)
  anchor=$(field "$result" anchor)
  run env RIG_SESSION_FILE="$session_file" "$CASE_DIR/bin/rig" session decision append --question 'Keep this in the external Rig directory.' --json
  [ "$status" -eq 0 ]
  [ -f "$external/memory/session-decisions/$anchor.json" ]
  [ ! -e "$CASE_DIR/.rig/memory/session-decisions/$anchor.json" ]
}

@test "session decision writes refuse unresolved session identity" {
  run "$CASE_DIR/bin/rig" session decision append --question 'Do not infer this session.' --json
  [ "$status" -ne 0 ]
  [ "$status" -ne 64 ]
  [ ! -e "$CASE_DIR/.rig/memory/session-decisions" ]
}

@test "session decision list does not create a lock file when the ledger is absent" {
  local session_file anchor directory lock_file
  local result
  result=$(bind read-only-list)
  session_file=$(field "$result" session_file)
  anchor=$(field "$result" anchor)
  directory="$CASE_DIR/.rig/memory/session-decisions"
  lock_file="$directory/$anchor.lock"
  mkdir -m 700 -p "$directory"
  run env RIG_SESSION_FILE="$session_file" "$CASE_DIR/bin/rig" session decision list --json
  [ "$status" -eq 0 ]
  [ ! -e "$lock_file" ]
  [[ "$output" == *'"decisions": []'* ]] || return 1
}

@test "session decision list rejects a dangling ledger symlink" {
  local session_file anchor directory
  local result
  result=$(bind dangling-ledger)
  session_file=$(field "$result" session_file)
  anchor=$(field "$result" anchor)
  directory="$CASE_DIR/.rig/memory/session-decisions"
  mkdir -m 700 -p "$directory"
  ln -s "$directory/missing-target.json" "$directory/$anchor.json"
  run env RIG_SESSION_FILE="$session_file" "$CASE_DIR/bin/rig" session decision list --json
  [ "$status" -ne 0 ]
  [[ "$output" == *'ledger file is a symlink'* ]] || return 1
  [ ! -e "$directory/$anchor.lock" ]
}

@test "session decision append secures an existing ledger directory" {
  local session_file anchor directory result
  result=$(bind secure-ledger)
  session_file=$(field "$result" session_file)
  anchor=$(field "$result" anchor)
  directory="$CASE_DIR/.rig/memory/session-decisions"
  mkdir -p "$directory"
  chmod 755 "$directory"
  run env RIG_SESSION_FILE="$session_file" "$CASE_DIR/bin/rig" session decision append --question 'Protect this ledger.' --json
  [ "$status" -eq 0 ]
  [ "$(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$directory")" = "0o700" ]
  [ -f "$directory/$anchor.json" ]
}

@test "rig-next stays read-only and reports exact-session and repository evidence" {
  local command="$REPO_ROOT/templates/project/.claude/commands/rig-next.md"
  grep -Fq 'Read-only status' "$command"
  grep -Fq 'confidence: exact' "$command"
  grep -Fq 'head SHA and CI state only when checks are for that exact SHA' "$command"
  grep -Fq 'session decision list --json' "$command"
  grep -Fq 'one concrete action' "$command"
  grep -Fq 'Do not edit files, create issues, update PRs, change labels' "$command"
  python3 - "$command" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text()
session = text.index("## Step 2 — Report work open from this session")
repository = text.index("## Step 3 — Report repository next actions")
recommendation = text.index("## Step 4 — Recommend one next action")
assert session < repository < recommendation
PY
}

@test "rig-audit defines session and full scopes with reproduced evidence" {
  local command="$REPO_ROOT/templates/project/.claude/commands/rig-audit.md"
  grep -Fq 'Session scope (default)' "$command"
  grep -Fq 'Full scope (`--full`)' "$command"
  grep -Fq 'open GitHub issues and PRs' "$command"
  grep -Fq 'Claude/Codex parity' "$command"
  grep -Fq 'reproduce the behavior' "$command"
  grep -Fq 'Do not write a dated sprint revision' "$command"
  grep -Fq 'Never change a GitHub issue, PR, label, release, or merge without the existing approval gate' "$command"
}

@test "rig-handoff keeps prompts in chat and requires separate write approval" {
  local command="$REPO_ROOT/templates/project/.claude/commands/rig-handoff.md"
  grep -Fq 'does not authorize tracker writes, post-merge housekeeping, or session finalization' "$command"
  grep -Fq 'Run `/rig-audit --full`' "$command"
  grep -Fq 'ask separately before running `/wrap`' "$command"
  grep -Fq 'create a new issue' "$command"
  grep -Fq 'show the exact tracker, title, body, labels, and repository and wait for approval' "$command"
  grep -Fq 'or write a prompt file by default.' "$command"
  grep -Fq 'overwrite only `$RIG_DIR/memory/NEXT_SESSION_PROMPT.md`' "$command"
  grep -Fq 'Never create dated copies or save the prompt elsewhere.' "$command"
  if grep -E 'one consolidated parent PR|proof-by-revert|worktree policy' "$command"; then return 1; fi
  if test -e "$REPO_ROOT/templates/project/.claude/commands/handoff-checklist.md"; then return 1; fi
}

@test "generated Codex skills contain all three canonical workflows and translated invocations" {
  local generated_dir="$BATS_TEST_TMPDIR/generated"
  run python3 "$REPO_ROOT/installer/generate-codex-skills.py" \
    --output "$generated_dir" --base-branch main \
    --skills-source "$REPO_ROOT/templates/project/.claude/skills" \
    "$REPO_ROOT/templates/project/.claude/commands/rig-next.md" \
    "$REPO_ROOT/templates/project/.claude/commands/rig-audit.md" \
    "$REPO_ROOT/templates/project/.claude/commands/rig-handoff.md"
  [ "$status" -eq 0 ]
  for name in rig-next rig-audit rig-handoff; do
    [ -f "$generated_dir/$name/SKILL.md" ]
    [ -f "$generated_dir/$name/references/command.md" ]
  done
  grep -Fq '$rig-audit --full' "$generated_dir/rig-handoff/references/command.md"
  grep -Fq '$rig-next' "$generated_dir/rig-handoff/references/command.md"
}

@test "help and public docs list the replacement skills" {
  grep -Fq '`/rig-next`' "$REPO_ROOT/templates/project/.claude/commands/rig-help.md"
  grep -Fq '`/rig-audit`' "$REPO_ROOT/templates/project/.claude/commands/rig-help.md"
  grep -Fq '`/rig-handoff`' "$REPO_ROOT/templates/project/.claude/commands/rig-help.md"
  grep -Fq 'Codex `$rig-next`' "$REPO_ROOT/README.md"
  grep -Fq '/rig-handoff' "$REPO_ROOT/README.md"
  grep -Fq '`/rig-next` / `$rig-next`' "$REPO_ROOT/docs/how-it-works.md"
}

@test "upgrade rename table maps the old handoff paths to the new command and skill" {
  grep -Fq 'project|.claude/commands/handoff-checklist.md|.claude/commands/rig-handoff.md|' "$REPO_ROOT/install.sh"
  grep -Fq 'project|.agents/skills/handoff-checklist/SKILL.md|.agents/skills/rig-handoff/SKILL.md|' "$REPO_ROOT/install.sh"
  grep -Fq 'project|.agents/skills/handoff-checklist/references/command.md|.agents/skills/rig-handoff/references/command.md|' "$REPO_ROOT/install.sh"
}
