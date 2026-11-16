#!/usr/bin/env bats
# Branch drift under an active session (#602): when a shared checkout changes
# branch after a session was bound, UserPromptSubmit warns that exact session
# once per change, names both branches, and suggests a dedicated worktree in
# the active provider's syntax. Other sessions' records never trigger it.

setup() {
  unset CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID RIG_SESSION_FILE RIG_SESSION_ANCHOR RIG_SESSION_PID RIG_AGENT
  CASE_DIR="$BATS_TEST_TMPDIR/project"
  RIG_DIR="$CASE_DIR/.rig"
  HOOKS="$CASE_DIR/.claude/hooks"
  mkdir -p "$RIG_DIR/memory/sessions/done" "$RIG_DIR/rules" "$HOOKS" "$CASE_DIR/.codex/hooks" "$CASE_DIR/bin"
  cp "$BATS_TEST_DIRNAME/../templates/project/.claude/hooks/prompt-submit.sh" "$HOOKS/prompt-submit.sh"
  cp "$BATS_TEST_DIRNAME/../templates/project/.codex/hooks/rig-adapter.sh" "$CASE_DIR/.codex/hooks/rig-adapter.sh"
  cp "$BATS_TEST_DIRNAME/../templates/project/.rig/rules/protected-paths.txt" "$RIG_DIR/rules/protected-paths.txt"
  cp "$BATS_TEST_DIRNAME/../templates/project/bin/rig" "$CASE_DIR/bin/rig"
  cp "$BATS_TEST_DIRNAME/../templates/project/bin/rig-session-resolve.py" "$CASE_DIR/bin/rig-session-resolve.py"
  chmod +x "$CASE_DIR/bin/rig"
  git -C "$CASE_DIR" init -q
  git -C "$CASE_DIR" checkout -q -b feat/alpha
  git -C "$CASE_DIR" config user.email test@example.com
  git -C "$CASE_DIR" config user.name Test
  git -C "$CASE_DIR" commit --allow-empty -q -m 'initial'
  git -C "$CASE_DIR" branch feat/beta
  git -C "$CASE_DIR" branch feat/gamma
  printf '# Snapshot\n' > "$RIG_DIR/memory/CONTEXT_SNAPSHOT.md"
  # The Codex adapter refuses to run without a project identity manifest.
  printf 'abc123  .rig/rules/protected-paths.txt\n' > "$RIG_DIR/memory/.rig-manifest"
  touch "$RIG_DIR/memory/.permission-nudge-offered" "$RIG_DIR/memory/.handoff-suggested"
}

# Bind a session record for a provider and native ID on the current branch.
bind_session() {
  run env RIG_SESSION_PID=602602 bash -c 'cd "$1" && bin/rig session bind --agent "$2" --native-session-id "$3" --source startup --json' _ "$CASE_DIR" "$1" "$2"
  [ "$status" -eq 0 ]
}

switch_to() {
  git -C "$CASE_DIR" checkout -q "$1"
}

# Submit one prompt as the given provider and native session ID; sets CONTEXT
# to the injected additional context, or empty when nothing was injected.
submit_prompt() {
  local agent="$1" native="$2" payload
  payload=$(python3 -c 'import json,sys; d={"hook_event_name":"UserPromptSubmit","prompt":"hi"}; d.update({"session_id":sys.argv[1]} if sys.argv[1] else {}); print(json.dumps(d))' "$native")
  if [[ "$agent" == codex ]]; then
    run bash -c 'cd "$1" && printf "%s" "$2" | bash .codex/hooks/rig-adapter.sh' _ "$CASE_DIR" "$payload"
  else
    run env RIG_AGENT=claude bash -c 'cd "$1" && printf "%s" "$2" | bash .claude/hooks/prompt-submit.sh' _ "$CASE_DIR" "$payload"
  fi
  [ "$status" -eq 0 ]
  CONTEXT=$(OUTPUT="$output" python3 -c '
import json, os
raw = os.environ["OUTPUT"].strip()
if raw:
    d = json.loads(raw)
    print(d.get("additionalContext") or d.get("hookSpecificOutput", {}).get("additionalContext", ""))
')
}

@test "Claude: a branch change under the session warns with both branches and a worktree suggestion" {
  bind_session claude claude-one
  switch_to feat/beta
  submit_prompt claude claude-one
  [[ "$CONTEXT" == *"Branch changed under this session"* ]] || return 1
  [[ "$CONTEXT" == *"feat/alpha"* && "$CONTEXT" == *"feat/beta"* ]] || return 1
  [[ "$CONTEXT" == *"git worktree add"* ]] || return 1
  [[ "$CONTEXT" == *"bin/rig claude"* ]] || return 1
  [[ "$CONTEXT" != *"bin/rig codex"* ]] || return 1
}

@test "Codex: the adapter relays the branch-change warning with the Codex launcher" {
  bind_session codex thread-one
  switch_to feat/beta
  submit_prompt codex thread-one
  [[ "$CONTEXT" == *"Branch changed under this session"* ]] || return 1
  [[ "$CONTEXT" == *"feat/alpha"* && "$CONTEXT" == *"feat/beta"* ]] || return 1
  [[ "$CONTEXT" == *"bin/rig codex"* ]] || return 1
  [[ "$CONTEXT" != *"bin/rig claude"* ]] || return 1
}

@test "no warning while the session stays on its recorded branch" {
  bind_session claude claude-same
  submit_prompt claude claude-same
  [[ "$CONTEXT" != *"Branch changed"* ]] || return 1
  [ -z "$CONTEXT" ]
}

@test "repeated prompts after one branch change warn exactly once" {
  bind_session claude claude-repeat
  switch_to feat/beta
  submit_prompt claude claude-repeat
  [[ "$CONTEXT" == *"Branch changed under this session"* ]] || return 1
  submit_prompt claude claude-repeat
  [[ "$CONTEXT" != *"Branch changed"* ]] || return 1
  submit_prompt claude claude-repeat
  [[ "$CONTEXT" != *"Branch changed"* ]] || return 1
}

@test "a further branch change warns again, and returning home re-arms the warning" {
  bind_session codex thread-further
  switch_to feat/beta
  submit_prompt codex thread-further
  [[ "$CONTEXT" == *"feat/beta"* ]] || return 1
  switch_to feat/gamma
  submit_prompt codex thread-further
  [[ "$CONTEXT" == *"Branch changed under this session"* ]] || return 1
  [[ "$CONTEXT" == *"feat/alpha"* && "$CONTEXT" == *"feat/gamma"* ]] || return 1
  switch_to feat/alpha
  submit_prompt codex thread-further
  [[ "$CONTEXT" != *"Branch changed"* ]] || return 1
  switch_to feat/beta
  submit_prompt codex thread-further
  [[ "$CONTEXT" == *"feat/beta"* ]] || return 1
}

@test "a detached HEAD is named as detached with its short commit" {
  bind_session claude claude-detached
  short=$(git -C "$CASE_DIR" rev-parse --short HEAD)
  git -C "$CASE_DIR" checkout -q --detach
  submit_prompt claude claude-detached
  [[ "$CONTEXT" == *"Branch changed under this session"* ]] || return 1
  [[ "$CONTEXT" == *"detached HEAD at $short"* ]] || return 1
}

@test "worktree suggestion shell-quotes a branch with command substitution syntax" {
  local unusual='feat/$(echo${IFS}X)'
  git -C "$CASE_DIR" checkout -q -b "$unusual"
  bind_session claude claude-unusual
  switch_to feat/beta
  submit_prompt claude claude-unusual
  local quoted
  quoted="$(printf '%q' "$unusual")"
  [[ "$CONTEXT" == *"git worktree add <path> $quoted"* ]] || return 1
}

@test "no warning when the payload carries no session ID" {
  bind_session claude claude-other
  switch_to feat/beta
  submit_prompt claude ""
  [[ "$CONTEXT" != *"Branch changed"* ]] || return 1
  [ -z "$(find "$RIG_DIR/memory/sessions" -name '.branch-ack-*' -print)" ]
}

@test "no warning when the session cannot be resolved exactly" {
  bind_session claude claude-ambiguous
  switch_to feat/beta
  printf 'not json\n' > "$RIG_DIR/memory/sessions/session-broken.json"
  submit_prompt claude claude-ambiguous
  [[ "$CONTEXT" == *"session identity is unresolved"* ]] || return 1
  [[ "$CONTEXT" != *"Branch changed"* ]] || return 1
}

@test "another session's record on a different branch never warns this session" {
  bind_session claude claude-elsewhere
  switch_to feat/beta
  bind_session claude claude-here
  submit_prompt claude claude-here
  [[ "$CONTEXT" != *"Branch changed"* ]] || return 1
  [[ "$CONTEXT" != *"feat/alpha"* ]] || return 1
  # A brand-new native ID binds on the current branch and is not warned either.
  submit_prompt codex thread-new
  [[ "$CONTEXT" != *"Branch changed"* ]] || return 1
  [[ "$CONTEXT" != *"feat/alpha"* ]] || return 1
}

@test "acknowledging a branch leaves the session record valid for session doctor" {
  bind_session claude claude-doctor
  before=$(find "$RIG_DIR/memory/sessions" -name 'session-*.json' -exec cat {} +)
  switch_to feat/beta
  submit_prompt claude claude-doctor
  [[ "$CONTEXT" == *"Branch changed under this session"* ]] || return 1
  [ "$before" = "$(find "$RIG_DIR/memory/sessions" -name 'session-*.json' -exec cat {} +)" ]
  run bash -c 'cd "$1" && bin/rig session doctor --json' _ "$CASE_DIR"
  [ "$status" -eq 0 ]
}
