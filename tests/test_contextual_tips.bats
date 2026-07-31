#!/usr/bin/env bats
# Focused contract tests for the shared contextual discovery tip catalog.

setup() {
  TEST_ROOT=$(mktemp -d)
  REPO="$TEST_ROOT/repo"
  RIG_DIR="$REPO/.rig"
  mkdir -p "$REPO/.claude/hooks" "$REPO/.claude/commands" \
    "$RIG_DIR/memory/sessions" "$RIG_DIR/tasks/active"
  cp "$BATS_TEST_DIRNAME/../templates/project/.claude/hooks/session-start.sh" \
    "$REPO/.claude/hooks/session-start.sh"
  cp "$BATS_TEST_DIRNAME/../templates/project/.rig/contextual-tips.sh" \
    "$RIG_DIR/contextual-tips.sh"
  for command in debug rig-gaps code-review sprint task session-name; do
    : > "$REPO/.claude/commands/$command.md"
  done
  cat > "$RIG_DIR/memory/CONTEXT_SNAPSHOT.md" <<'EOF'
# Context Snapshot
**Last updated:** 2026-07-31 — test
EOF
  git -C "$REPO" init -q -b main
  git -C "$REPO" -c user.name=Test -c user.email=test@example.com \
    commit --allow-empty -m initial -q
  OUTPUT="$TEST_ROOT/output.json"
}

teardown() {
  rm -rf "$TEST_ROOT"
  rm -f "/tmp/.rig-session-$$.uuid"
}

run_start() {
  (cd "$REPO" && RIG_SESSION_PID="$$" bash .claude/hooks/session-start.sh \
    > "$OUTPUT" 2>/dev/null <<<'{"source":"startup"}')
}

context() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["hookSpecificOutput"]["additionalContext"])' "$OUTPUT"
}

tip_count() {
  context | grep -c 'Tip:' || true
}

@test "priority: one highest-priority tip emits and lower candidates remain unspent" {
  cat > "$RIG_DIR/memory/ERRORS.md" <<'EOF'
## [2026-07-31] — observed parser failure
EOF
  cat > "$RIG_DIR/memory/RIG_GAPS.md" <<'EOF'
## [2026-07-31] — observed workflow gap
EOF
  printf '[#1] [#2] [#3]\n' > "$RIG_DIR/memory/PROGRESS.md"

  run_start

  [ "$(tip_count)" -eq 1 ]
  context | grep -Fq '/debug'
  [ -f "$RIG_DIR/memory/tips/.tip-debug-errors-shown" ]
  [ ! -e "$RIG_DIR/memory/tips/.tip-rig-gaps-shown" ]
  [ ! -e "$RIG_DIR/memory/tips/.tip-sprint-shown" ]
}

@test "throttling: selected tip is one-time and next eligible tip follows later" {
  cat > "$RIG_DIR/memory/ERRORS.md" <<'EOF'
## [2026-07-31] — observed parser failure
EOF
  cat > "$RIG_DIR/memory/RIG_GAPS.md" <<'EOF'
## [2026-07-31] — observed workflow gap
EOF
  run_start
  context | grep -Fq '/debug'

  run_start

  [ "$(tip_count)" -eq 1 ]
  context | grep -Fq '/rig-gaps'
}

@test "opt-out suppresses all applicable tips without spending sentinels" {
  cat > "$RIG_DIR/memory/ERRORS.md" <<'EOF'
## [2026-07-31] — observed parser failure
EOF
  touch "$RIG_DIR/memory/.rig-tips-disabled"

  run_start

  [ "$(tip_count)" -eq 0 ]
  [ ! -d "$RIG_DIR/memory/tips" ]
}

@test "suppression: unavailable and already-used commands do not emit" {
  cat > "$RIG_DIR/memory/ERRORS.md" <<'EOF'
## [2026-07-31] — observed parser failure
EOF
  cat > "$RIG_DIR/memory/RIG_GAPS.md" <<'EOF'
## [2026-07-31] — observed workflow gap
EOF
  rm "$REPO/.claude/commands/debug.md"
  printf 'Previously ran /rig-gaps for this project.\n' > "$RIG_DIR/memory/PROGRESS.md"

  run_start

  ! context | grep -Eq '/debug|/rig-gaps'
  [ ! -e "$RIG_DIR/memory/tips/.tip-debug-errors-shown" ]
  [ ! -e "$RIG_DIR/memory/tips/.tip-rig-gaps-shown" ]
}

@test "new context: logged error names evidence and concrete debug action" {
  cat > "$RIG_DIR/memory/ERRORS.md" <<'EOF'
## [2026-07-31] — observed parser failure
EOF
  run_start
  context | grep -Fq 'ERRORS.md contains a recorded failure'
  context | grep -Fq 'Run /debug'
}

@test "new context: logged workflow gap names evidence and concrete gaps action" {
  cat > "$RIG_DIR/memory/RIG_GAPS.md" <<'EOF'
## [2026-07-31] — observed workflow gap
EOF
  run_start
  context | grep -Fq 'RIG_GAPS.md contains workflow friction'
  context | grep -Fq 'Run /rig-gaps'
}

@test "new context: reviewable feature branch suggests code review" {
  git -C "$REPO" checkout -q -b feature/review-me
  git -C "$REPO" -c user.name=Test -c user.email=test@example.com commit --allow-empty -m one -q
  git -C "$REPO" -c user.name=Test -c user.email=test@example.com commit --allow-empty -m two -q

  run_start

  context | grep -Fq 'at least two commits ahead'
  context | grep -Fq 'Run /code-review'
}

@test "#317 regression: sprint outranks session-name and fires once" {
  printf '[#1] [#2] [#3]\n' > "$RIG_DIR/memory/PROGRESS.md"
  run_start
  [ "$(tip_count)" -eq 1 ]
  context | grep -Fq '/sprint'
  [ -f "$RIG_DIR/memory/tips/.tip-sprint-shown" ]

  run_start
  ! context | grep -Fq '/sprint'
}

@test "#317 regression: enabled fewer-prompts feature stays suppressed" {
  touch "$RIG_DIR/memory/.fewer-prompts-enabled"
  mkdir -p "$RIG_DIR/memory/tips"
  touch "$RIG_DIR/memory/tips/.tip-session-name-shown"
  run_start
  ! context | grep -Fq '.fewer-prompts-enabled'
  [ ! -e "$RIG_DIR/memory/tips/.tip-fewer-prompts-shown" ]
}

@test "mode relevance: catalog emits nothing outside startup and resume" {
  run bash -c 'source "$1"; REPO="$2" RIG_DIR="$3" RIG_TIP_SOURCE=compact collect_contextual_tip' \
    _ "$RIG_DIR/contextual-tips.sh" "$REPO" "$RIG_DIR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -d "$RIG_DIR/memory/tips" ]
}

@test "adversarial local text remains inert and ambiguity stays deterministic" {
  marker="$TEST_ROOT/must-not-exist"
  cat > "$RIG_DIR/memory/ERRORS.md" <<EOF
## [2026-07-31] — \$(touch $marker) | suspicious text
EOF
  cat > "$RIG_DIR/memory/RIG_GAPS.md" <<'EOF'
## [2026-07-31] — another equally applicable signal
EOF

  run_start

  [ ! -e "$marker" ]
  [ "$(tip_count)" -eq 1 ]
  context | grep -Fq '/debug'
  ! context | grep -Fq 'touch'
}
