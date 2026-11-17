#!/usr/bin/env bats
# Per-subcommand CLI help and honest continuation output (#617).

setup() {
  export CASE_DIR="$BATS_TEST_TMPDIR/project"
  mkdir -p "$CASE_DIR/bin" "$CASE_DIR/.claude/hooks" "$CASE_DIR/.rig/memory/sessions/done"
  for helper in rig rig-session-resolve.py rig-session-index.py rig-snapshot.py rig-sprint; do
    cp "$BATS_TEST_DIRNAME/../templates/project/bin/$helper" "$CASE_DIR/bin/$helper"
  done
  cp "$BATS_TEST_DIRNAME/../templates/project/.claude/hooks/session-start.sh" "$CASE_DIR/.claude/hooks/session-start.sh"
  chmod +x "$CASE_DIR/bin/rig" "$CASE_DIR/.claude/hooks/session-start.sh"
  git -C "$CASE_DIR" init -q
  git -C "$CASE_DIR" checkout -q -b feat/help
  printf '# Snapshot\n' > "$CASE_DIR/.rig/memory/CONTEXT_SNAPSHOT.md"
  unset RIG_SESSION_FILE RIG_SESSION_ANCHOR RIG_SESSION_PID RIG_AGENT CODEX_THREAD_ID CLAUDE_CODE_SESSION_ID
}

# Print a stable listing of every file under the Rig data directory.
rig_tree() {
  (cd "$CASE_DIR/.rig" && find . -print | sort)
}

@test "every documented subcommand prints its own usage with --help and exits 0" {
  local spec command
  while IFS= read -r spec; do
    [ -n "$spec" ] || continue
    run bash -c 'cd "$1" && bin/rig $2 --help' _ "$CASE_DIR" "$spec"
    [ "$status" -eq 0 ] || { echo "non-zero for: $spec" >&3; return 1; }
    [[ "${lines[0]}" == "Usage: rig $spec"* ]] || { echo "wrong usage for: $spec -> ${lines[0]}" >&3; return 1; }
  done <<'EOF'
session resolve
session current
session list
session index
session doctor
session legacy
session repair
session retrofit
session obligation
session bind
session-name set
memory validate
memory repair-markers
memory append-gap
memory append-progress
memory write-snapshot
memory workflow-lock
sprint audit
sprint plan
sprint status
task inventory
pr review-metadata
upgrade rollback
worktree bootstrap
EOF
}

@test "-h is accepted wherever --help is" {
  run bash -c 'cd "$1" && bin/rig session retrofit -h' _ "$CASE_DIR"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "Usage: rig session retrofit"* ]] || return 1
}

@test "help after other options never runs a writing subcommand" {
  local before
  before=$(rig_tree)
  run bash -c 'cd "$1" && bin/rig session bind --agent claude --native-session-id help-check --help' _ "$CASE_DIR"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "Usage: rig session bind"* ]] || return 1
  run bash -c 'cd "$1" && bin/rig memory append-progress --title t --body b --help' _ "$CASE_DIR"
  [ "$status" -eq 0 ]
  [ "$before" = "$(rig_tree)" ]
}

@test "session resolve --help prints usage instead of resolving" {
  "$CASE_DIR/bin/rig" session bind --agent claude --native-session-id resolvable --source startup >/dev/null
  run env CLAUDE_CODE_SESSION_ID=resolvable bash -c 'cd "$1" && bin/rig session resolve --help' _ "$CASE_DIR"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "Usage: rig session resolve"* ]] || return 1
  [[ "$output" != *"session-"*".json"* ]] || return 1
}

@test "a literal --help after -- is a session name, not a help request" {
  run bash -c 'cd "$1" && bin/rig session-name set -- --help' _ "$CASE_DIR"
  [[ "$output" != "Usage:"* ]] || return 1
}

@test "an unknown subcommand with --help is still a usage error" {
  run bash -c 'cd "$1" && bin/rig session nope --help' _ "$CASE_DIR"
  [ "$status" -eq 64 ]
  [[ "$output" == *"unexpected session subcommand"* ]] || return 1
}

@test "session current text output names the continuation parent" {
  local first first_file first_anchor done_file
  first=$("$CASE_DIR/bin/rig" session bind --agent claude --native-session-id resumed-thread --source startup)
  first_file=$(printf '%s' "$first" | python3 -c 'import json,sys; print(json.load(sys.stdin)["session_file"])')
  first_anchor=$(printf '%s' "$first" | python3 -c 'import json,sys; print(json.load(sys.stdin)["anchor"])')
  RIG_SESSION_FILE="$first_file" "$CASE_DIR/bin/rig" session-name set --final --complete 'completed work' >/dev/null
  done_file=$(find "$CASE_DIR/.rig/memory/sessions/done" -name 'session-*.json' -print | head -1)
  run env RIG_SESSION_FILE="$done_file" RIG_SESSION_PID=6171 bash -c \
    'cd "$1" && printf "%s" "$2" | .claude/hooks/session-start.sh' \
    _ "$CASE_DIR" '{"source":"resume","session_id":"resumed-thread"}'
  [ "$status" -eq 0 ]

  run bash -c 'cd "$1" && bin/rig session current --agent claude --native-session-id resumed-thread' _ "$CASE_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"  continuation of $first_anchor"* ]] || return 1
  [[ "$output" != *"resumed-thread"* ]] || return 1
}

@test "session current text output stays a single plain line for a root session" {
  "$CASE_DIR/bin/rig" session bind --agent claude --native-session-id plain-root --source startup >/dev/null
  run bash -c 'cd "$1" && bin/rig session current --agent claude --native-session-id plain-root' _ "$CASE_DIR"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" != *" of "* ]] || return 1
}
