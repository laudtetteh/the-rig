#!/usr/bin/env bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  TEST_ROOT="$(mktemp -d)"
  REPO="$TEST_ROOT/repo"
  RIG_DIR="$REPO/.rig"
  mkdir -p "$REPO/.claude/hooks" "$RIG_DIR/memory/sessions"
  cp "$REPO_ROOT/templates/project/.claude/hooks/prompt-submit.sh" "$REPO/.claude/hooks/prompt-submit.sh"
  git -C "$REPO" init -q
}

teardown() {
  rm -rf "$TEST_ROOT"
}

run_prompt_submit() {
  (cd "$REPO" && RIG_HANDOFF_ELAPSED_SECONDS=1 bash .claude/hooks/prompt-submit.sh <<<'{}')
}

@test "handoff detector suggests only and never runs wrap or post-merge" {
  cat > "$RIG_DIR/memory/sessions/session-old.json" <<'EOF'
{
  "anchor": "old",
  "started_at": "2020-01-01T00:00:00+00:00",
  "status": "active"
}
EOF

  run run_prompt_submit
  [ "$status" -eq 0 ]
  grep -Fq 'Rig handoff suggestion:' <<< "$output"
  grep -Fq 'Reply explicitly before I run /handoff-checklist' <<< "$output"
  [ -f "$RIG_DIR/memory/.handoff-suggested" ]
  [ ! -f "$RIG_DIR/memory/.wrap-needed" ]
  [ ! -f "$RIG_DIR/memory/.post-merge-pending" ]
}

@test "handoff detector does not suggest below benchmark" {
  cat > "$RIG_DIR/memory/sessions/session-new.json" <<EOF
{
  "anchor": "new",
  "started_at": "2999-01-01T00:00:00+00:00",
  "status": "active"
}
EOF

  run run_prompt_submit
  [ "$status" -eq 0 ]
  run grep -F 'Rig handoff suggestion:' <<< "$output"
  [ "$status" -ne 0 ]
  [ ! -f "$RIG_DIR/memory/.handoff-suggested" ]
}
