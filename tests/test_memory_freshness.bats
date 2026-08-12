#!/usr/bin/env bats

setup() {
  export CASE_DIR="$BATS_TEST_TMPDIR/project"
  export RIG_DIR="$CASE_DIR/.rig"
  export HOOK_DIR="$CASE_DIR/hooks"
  mkdir -p "$RIG_DIR/memory/sessions" "$RIG_DIR/tasks/active" "$HOOK_DIR"
  cp "$BATS_TEST_DIRNAME/../templates/project/.claude/hooks/pre-compact.sh" "$HOOK_DIR/"
  cp "$BATS_TEST_DIRNAME/../templates/project/.claude/hooks/post-compact.sh" "$HOOK_DIR/"
  cp "$BATS_TEST_DIRNAME/../templates/project/.claude/hooks/prompt-submit.sh" "$HOOK_DIR/"
  cp "$BATS_TEST_DIRNAME/../templates/project/.claude/hooks/session-start.sh" "$HOOK_DIR/"
  cp "$BATS_TEST_DIRNAME/../templates/project/.husky/post-merge" "$HOOK_DIR/"
  chmod +x "$HOOK_DIR"/*
  git -C "$CASE_DIR" init -q
  git -C "$CASE_DIR" config user.email test@example.com
  git -C "$CASE_DIR" config user.name Test
  git -C "$CASE_DIR" checkout -q -b feat/original
  git -C "$CASE_DIR" commit --allow-empty -q -m 'initial'
  printf '# Snapshot\n\n---\n' > "$RIG_DIR/memory/CONTEXT_SNAPSHOT.md"
  printf '# Progress\n' > "$RIG_DIR/memory/PROGRESS.md"
  touch "$RIG_DIR/memory/.permission-nudge-offered"
}

@test "pre-compact records branch, full HEAD, PR, task, and timestamp" {
  printf '# Task\n' > "$RIG_DIR/tasks/active/feat-352.md"
  run env RIG_SESSION_PID=352352 RIG_PR_NUMBER=352 \
    bash -c 'cd "$1" && exec "$2/pre-compact.sh"' _ "$CASE_DIR" "$HOOK_DIR"
  [ "$status" -eq 0 ]
  checkpoint="$RIG_DIR/memory/.compact-checkpoint-352352.md"
  [ -f "$checkpoint" ]
  head_sha=$(git -C "$CASE_DIR" rev-parse HEAD)
  grep -Fq "**Branch:** feat/original" "$checkpoint"
  grep -Fq "**HEAD SHA:** $head_sha" "$checkpoint"
  grep -Fq "**PR number:** 352" "$checkpoint"
  grep -Fq "**Active task:** feat-352" "$checkpoint"
  grep -Eq '^\*\*Captured at:\*\* [0-9]{4}-[0-9]{2}-[0-9]{2}T' "$checkpoint"
  grep -Fq "Advisory: this compact checkpoint is historical handoff context" "$checkpoint"
}

@test "pre-compact discovers an open PR when the CLI can identify one" {
  mkdir -p "$BATS_TEST_TMPDIR/fakebin"
  cat > "$BATS_TEST_TMPDIR/fakebin/gh" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == "pr view --json number --jq .number" ]] || exit 2
printf '987\n'
EOF
  chmod +x "$BATS_TEST_TMPDIR/fakebin/gh"
  run env PATH="$BATS_TEST_TMPDIR/fakebin:$PATH" RIG_SESSION_PID=987987 \
    bash -c 'cd "$1" && exec "$2/pre-compact.sh"' _ "$CASE_DIR" "$HOOK_DIR"
  [ "$status" -eq 0 ]
  grep -Fq '**PR number:** 987' "$RIG_DIR/memory/.compact-checkpoint-987987.md"
}

@test "post-compact frames a matching checkpoint as historical advisory context" {
  head_sha=$(git -C "$CASE_DIR" rev-parse HEAD)
  cat > "$RIG_DIR/memory/.compact-checkpoint-$$.md" <<EOF
## Compact checkpoint

**Branch:** feat/original
**HEAD SHA:** $head_sha
EOF
  before=$(cksum < "$RIG_DIR/memory/.compact-checkpoint-$$.md")
  run bash -c 'cd "$1" && exec "$2/post-compact.sh"' _ "$CASE_DIR" "$HOOK_DIR"
  [ "$status" -eq 0 ]
  OUTPUT="$output" python3 -c 'import json,os; text=json.loads(os.environ["OUTPUT"])["systemMessage"]; assert "checkpoint is stale" not in text; assert text.startswith("Advisory: this compact checkpoint is historical handoff context")'
  [ "$(cksum < "$RIG_DIR/memory/.compact-checkpoint-$$.md")" = "$before" ]
}

@test "post-compact marks changed branch and HEAD as advisory-stale" {
  old_head=$(git -C "$CASE_DIR" rev-parse HEAD)
  cat > "$RIG_DIR/memory/.compact-checkpoint-$$.md" <<EOF
## Compact checkpoint

**Branch:** feat/original
**HEAD SHA:** $old_head
EOF
  before=$(cksum < "$RIG_DIR/memory/.compact-checkpoint-$$.md")
  git -C "$CASE_DIR" checkout -q -b feat/new-state
  git -C "$CASE_DIR" commit --allow-empty -q -m 'advance state'
  run bash -c 'cd "$1" && exec "$2/post-compact.sh"' _ "$CASE_DIR" "$HOOK_DIR"
  [ "$status" -eq 0 ]
  OUTPUT="$output" python3 -c 'import json,os; text=json.loads(os.environ["OUTPUT"])["systemMessage"]; assert "checkpoint is stale" in text; assert "branch changed" in text; assert "HEAD changed" in text; assert "historical context" in text'
  [ "$(cksum < "$RIG_DIR/memory/.compact-checkpoint-$$.md")" = "$before" ]
}

@test "post-merge records triggering SHA and timestamp atomically" {
  run bash -c 'cd "$1" && exec "$2/post-merge" 0' _ "$CASE_DIR" "$HOOK_DIR"
  [ "$status" -eq 0 ]
  pending="$RIG_DIR/memory/.post-merge-pending"
  [ -f "$pending" ]
  head_sha=$(git -C "$CASE_DIR" rev-parse HEAD)
  grep -Fxq "merge_sha=$head_sha" "$pending"
  grep -Eq '^merged_at=[0-9]{4}-[0-9]{2}-[0-9]{2}T' "$pending"
  if find "$RIG_DIR/memory" -name '.post-merge-pending.tmp.*' | grep -q .; then
    return 1
  fi
}

@test "prompt warning reports merge metadata and preserves consistent skip wording" {
  printf 'merge_sha=abc123\nmerged_at=2026-07-31T10:20:30-07:00\n' \
    > "$RIG_DIR/memory/.post-merge-pending"
  run bash -c 'cd "$1" && exec "$2/prompt-submit.sh"' _ "$CASE_DIR" "$HOOK_DIR"
  [ "$status" -eq 0 ]
  OUTPUT="$output" python3 -c 'import json,os; text=json.loads(os.environ["OUTPUT"])["additionalContext"]; assert "abc123" in text; assert "2026-07-31T10:20:30-07:00" in text; assert "skip for current task" in text; assert "without clearing the reminder" in text'
  [ -f "$RIG_DIR/memory/.post-merge-pending" ]
}

@test "session-start warning matches prompt wording without suppressing contextual tips" {
  cp "$BATS_TEST_DIRNAME/../templates/project/.rig/contextual-tips.sh" "$RIG_DIR/contextual-tips.sh"
  mkdir -p "$CASE_DIR/.claude/commands"
  : > "$CASE_DIR/.claude/commands/session-name.md"
  printf 'merge_sha=abc123\nmerged_at=2026-07-31T10:20:30-07:00\n' \
    > "$RIG_DIR/memory/.post-merge-pending"
  run env RIG_SESSION_PID=352001 bash -c \
    'cd "$1" && exec "$2/session-start.sh"' _ "$CASE_DIR" "$HOOK_DIR" \
    <<<'{"source":"startup"}'
  [ "$status" -eq 0 ]
  OUTPUT="$output" python3 -c 'import json,os; text=json.loads(os.environ["OUTPUT"])["hookSpecificOutput"]["additionalContext"]; assert "Merge: abc123 at 2026-07-31T10:20:30-07:00." in text; assert "skip for current task" in text; assert "without clearing the reminder" in text; assert "Rig tip relay:" in text'
  [ -f "$RIG_DIR/memory/.post-merge-pending" ]
}

@test "legacy and adversarial pending files remain best-effort data" {
  printf 'merge_sha=$(touch /tmp/rig-352-injected)\nmerged_at=`false`\n' \
    > "$RIG_DIR/memory/.post-merge-pending"
  rm -f /tmp/rig-352-injected
  run bash -c 'cd "$1" && exec "$2/prompt-submit.sh"' _ "$CASE_DIR" "$HOOK_DIR"
  [ "$status" -eq 0 ]
  [ ! -e /tmp/rig-352-injected ]
  [[ "$output" == *'$(touch /tmp/rig-352-injected)'* ]] || return 1

  : > "$RIG_DIR/memory/.post-merge-pending"
  run bash -c 'cd "$1" && exec "$2/prompt-submit.sh"' _ "$CASE_DIR" "$HOOK_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skip for current task"* ]] || return 1
}

@test "post-merge command documents metadata-preserving task skip" {
  command_file="$BATS_TEST_DIRNAME/../templates/project/.claude/commands/post-merge.md"
  grep -Fq 'triggering merge SHA and timestamp' "$command_file"
  grep -Fq 'skip for current task' "$command_file"
  grep -Fq 'leaves the reminder and its merge metadata intact' "$command_file"
}
