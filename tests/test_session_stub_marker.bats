#!/usr/bin/env bats
# Session commit counting (#665): post-tool's fallback PROGRESS stub log line
# uses the same marker stop.sh counts, and a log without stubs counts as a
# single 0 rather than grep's "0" plus a fallback "0".

HOOKS="$BATS_TEST_DIRNAME/../templates/project/.claude/hooks"

@test "post-tool logs fallback stubs with the marker stop.sh counts" {
  grep -Fq 'grep -c "PROGRESS stub:" "$SESSION_LOG"' "$HOOKS/stop.sh"
  grep -Fq '] PROGRESS stub: $COMMIT_HASH' "$HOOKS/post-tool.sh"
  if grep -Fq 'PROGRESS fallback stub:' "$HOOKS/post-tool.sh"; then return 1; fi
}

@test "stop.sh counts a stub-free session log as a single 0" {
  local line
  line=$(grep -F 'SESSION_COMMIT_COUNT=$(grep -c "PROGRESS stub:"' "$HOOKS/stop.sh")
  SESSION_LOG="$BATS_TEST_TMPDIR/session.log"
  printf '[10:00:00] unrelated line\n' > "$SESSION_LOG"
  eval "$line"
  [ "$SESSION_COMMIT_COUNT" = "0" ]

  SESSION_LOG="$BATS_TEST_TMPDIR/missing.log"
  eval "$line"
  [ "$SESSION_COMMIT_COUNT" = "0" ]

  SESSION_LOG="$BATS_TEST_TMPDIR/two.log"
  printf '[10:00:00] PROGRESS stub: abc feat: a\n[10:01:00] PROGRESS stub: def feat: b\n' > "$SESSION_LOG"
  eval "$line"
  [ "$SESSION_COMMIT_COUNT" = "2" ]
}
