#!/usr/bin/env bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  TEST_ROOT="$(mktemp -d)"
  REPO="$TEST_ROOT/repo"
  RIG_DIR="$REPO/.rig"
  mkdir -p "$REPO/.claude/hooks" "$RIG_DIR/memory/sessions"
  cp "$REPO_ROOT/templates/project/.claude/hooks/prompt-submit.sh" "$REPO/.claude/hooks/prompt-submit.sh"
  mkdir -p "$REPO/bin"
  cp "$REPO_ROOT/templates/project/bin/rig-path.py" "$REPO/bin/rig-path.py"
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

# ── Display-only handoff prompts (#717) ──────────────────────────────────────

handoff_surfaces() {
  printf '%s\n' \
    "$REPO_ROOT/templates/project/.claude/commands/handoff-checklist.md" \
    "$REPO_ROOT/templates/project/.claude/commands/wrap.md" \
    "$REPO_ROOT/templates/global/CLAUDE.md"
}

@test "handoff guidance: every shipped surface makes handoff prompts display-only" {
  while IFS= read -r surface; do
    grep -Fq 'display-only' "$surface" || { echo "missing display-only: $surface"; return 1; }
    grep -Fq '$RIG_DIR/memory/NEXT_SESSION_PROMPT.md' "$surface" || { echo "missing fixed path: $surface"; return 1; }
    grep -Fq 'Never create a' "$surface" || { echo "missing dated-file ban: $surface"; return 1; }
    grep -Fq 'CONTEXT_SNAPSHOT.md' "$surface" || { echo "missing snapshot pointer: $surface"; return 1; }
  done < <(handoff_surfaces)
}

@test "handoff guidance: saving a prompt requires an explicit user request" {
  while IFS= read -r surface; do
    grep -Eq 'only when the user explicitly asks|only when the user explicitly asks for a file' "$surface" \
      || { echo "missing explicit-request gate: $surface"; return 1; }
  done < <(handoff_surfaces)
}

@test "handoff guidance: generated Codex skills carry the display-only rule" {
  out="$TEST_ROOT/codex-skills"
  python3 "$REPO_ROOT/installer/generate-codex-skills.py" --output "$out" --base-branch main \
    "$REPO_ROOT/templates/project/.claude/commands/handoff-checklist.md" \
    "$REPO_ROOT/templates/project/.claude/commands/wrap.md"
  for name in handoff-checklist wrap; do
    grep -Fq 'display-only' "$out/$name/references/command.md"
    grep -Fq '$RIG_DIR/memory/NEXT_SESSION_PROMPT.md' "$out/$name/references/command.md"
  done
}

@test "handoff guidance: no shipped template tells agents to write a dated handoff file" {
  run grep -rEn -i \
    'next-session-prompt-[0-9]|handoff-prompt-[0-9]|(handoff|next-session)[^`]*\$\(date|(handoff|next-session)[^`]*YYYY-MM-DD' \
    "$REPO_ROOT/templates"
  [ "$status" -ne 0 ]
}
