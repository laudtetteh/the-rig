#!/usr/bin/env bats
# The /clear branch of session-start must point at the renamed status
# workflow (#714 renamed /status to /rig-status; regression tracked in #727).

setup() {
  TEST_ROOT=$(mktemp -d)
  REPO="$TEST_ROOT/repo"
  RIG_DIR="$REPO/.rig"
  mkdir -p "$REPO/.claude/hooks" "$REPO/bin" "$RIG_DIR/memory/sessions"
  cp "$BATS_TEST_DIRNAME/../templates/project/.claude/hooks/session-start.sh" \
    "$REPO/.claude/hooks/session-start.sh"
  cp "$BATS_TEST_DIRNAME/../templates/project/bin/rig-path.py" "$REPO/bin/rig-path.py"
  git -C "$REPO" init -q -b main
  git -C "$REPO" -c user.name=Test -c user.email=test@example.com \
    commit --allow-empty -m initial -q
  OUTPUT="$TEST_ROOT/output.json"
}

teardown() {
  rm -rf "$TEST_ROOT"
  rm -f "/tmp/.rig-session-$$.uuid"
}

run_clear() {
  (cd "$REPO" && RIG_SESSION_PID="$$" RIG_AGENT="$1" bash .claude/hooks/session-start.sh \
    > "$OUTPUT" 2>/dev/null <<<'{"source":"clear"}')
}

context() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["hookSpecificOutput"]["additionalContext"])' "$OUTPUT"
}

@test "clear: Claude is told to run /rig-status, not the built-in /status" {
  run_clear claude
  context | grep -Fq 'Session cleared — run /rig-status for current state.'
}

@test "clear: Codex is told to run \$rig-status, not the retired \$status" {
  run_clear codex
  context | grep -Fq 'Session cleared — run $rig-status for current state.'
}
