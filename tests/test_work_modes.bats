#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CONTRACT="$REPO_ROOT/templates/project/.rig/processes/WORK_MODES.md"
  COMMAND_DIR="$REPO_ROOT/templates/project/.claude/commands"
  TASK_TEMPLATE="$REPO_ROOT/templates/project/.rig/tasks/backlog/TASK_example.md"
  CLAUDE_GUIDE="$REPO_ROOT/templates/project/CLAUDE.md"
}

@test "work modes define the canonical ordered lifecycle" {
  [ -f "$CONTRACT" ]
  grep -Fq '`inspect -> plan -> approve -> execute -> validate -> ship -> closeout`' "$CONTRACT"

  for phase in inspect plan approve execute validate ship closeout; do
    grep -Eq "^\| $phase \|" "$CONTRACT"
  done
}

@test "work modes define public statuses and all supported transitions" {
  for status in proposed ready active blocked partial complete cancelled; do
    grep -Fq "\`$status\`" "$CONTRACT"
  done

  for transition in 'project | task' 'project | sprint' 'task | sprint' 'sprint | task' 'task | embedded task'; do
    grep -Fq "| $transition |" "$CONTRACT"
  done
}

@test "all orchestration commands are adapters to the canonical contract" {
  for command in kickoff task run sprint; do
    grep -Fq '.rig/processes/WORK_MODES.md' "$COMMAND_DIR/$command.md"
    grep -Fq 'Work-mode adapter' "$COMMAND_DIR/$command.md"
  done
}

@test "task schema persists resumable phase and status without parallel state" {
  grep -Fq '## Work checkpoint' "$TASK_TEMPLATE"
  grep -Fq '**Phase**:' "$TASK_TEMPLATE"
  grep -Fq '**Last completed**:' "$TASK_TEMPLATE"
  grep -Fq '**Next action**:' "$TASK_TEMPLATE"
  grep -Fq '**Blocker/unblock condition**:' "$TASK_TEMPLATE"
  grep -Fq '**Approved scope changes**:' "$TASK_TEMPLATE"
  grep -Fq '**Execution identity**:' "$TASK_TEMPLATE"
  grep -Fq 'Do not create a second global work-state database.' "$CONTRACT"
}

@test "approval boundaries cover repairs launch scope and external mutations" {
  grep -Fq 'launching a project-derived task or sprint plan' "$CONTRACT"
  grep -Fq 'repairing task metadata, dependency edges, or declared file scope' "$CONTRACT"
  grep -Fq 'accepting a scope change after launch' "$CONTRACT"
  grep -Fq 'external mutations' "$CONTRACT"
  grep -Fq 'irreversible or materially destructive work' "$CONTRACT"
}

@test "CLAUDE routes intent and rejects implicit transition approval" {
  grep -Fq '## Work-mode routing' "$CLAUDE_GUIDE"
  grep -Fq 'project -> task' "$CLAUDE_GUIDE"
  grep -Fq 'project -> sprint' "$CLAUDE_GUIDE"
  grep -Fq 'task -> sprint' "$CLAUDE_GUIDE"
  grep -Fq 'sprint -> isolated task' "$CLAUDE_GUIDE"
  grep -Fq 'Never treat a mode' "$CLAUDE_GUIDE"
  grep -Fq 'transition as execution approval' "$CLAUDE_GUIDE"
}
