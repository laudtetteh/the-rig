#!/usr/bin/env bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  TEST_ROOT="$(mktemp -d)"
  REPO="$TEST_ROOT/repo"
  RIG_DIR="$REPO/.rig"
  mkdir -p "$REPO/.claude/hooks" "$RIG_DIR/memory/sessions" "$REPO/bin"
  cp "$REPO_ROOT/templates/project/.claude/hooks/prompt-submit.sh" "$REPO/.claude/hooks/prompt-submit.sh"
  cp "$REPO_ROOT/templates/project/bin/rig" "$REPO/bin/rig"
  cp "$REPO_ROOT/templates/project/bin/rig-path.py" "$REPO/bin/rig-path.py"
  cp "$REPO_ROOT/templates/project/bin/rig-session-resolve.py" "$REPO/bin/rig-session-resolve.py"
  chmod +x "$REPO/bin/rig"
  git -C "$REPO" init -q
  git -C "$REPO" config user.email test@example.com
  git -C "$REPO" config user.name Test
  touch "$RIG_DIR/memory/.permission-nudge-offered"
}

teardown() {
  rm -rf "$TEST_ROOT"
}

run_prompt_submit() {
  local session_id="$1"
  local payload
  payload=$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"UserPromptSubmit","prompt":"hi","session_id":sys.argv[1]}))' "$session_id")
  (cd "$REPO" && printf '%s' "$payload" | RIG_AGENT=claude RIG_SESSION_PID=665665 RIG_HANDOFF_ELAPSED_SECONDS=1 bash .claude/hooks/prompt-submit.sh)
}

bind_session() {
  run env RIG_SESSION_PID=665665 bash -c 'cd "$1" && bin/rig session bind --agent claude --native-session-id "$2" --source startup --json' _ "$REPO" "$1"
  [ "$status" -eq 0 ]
  BOUND_FILE=$(OUTPUT="$output" python3 -c 'import json,os; print(json.loads(os.environ["OUTPUT"])["session_file"])')
}

@test "handoff detector suggests only and never runs wrap or post-merge" {
  bind_session old
  python3 -c 'import datetime,json,sys; p=sys.argv[1]; d=json.load(open(p)); d["created_at"]=(datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(hours=3)).isoformat(); json.dump(d,open(p,"w"))' "$BOUND_FILE"

  run run_prompt_submit old
  [ "$status" -eq 0 ]
  grep -Fq 'Rig handoff suggestion:' <<< "$output"
  grep -Fq 'Reply explicitly before I run /handoff-checklist' <<< "$output"
  [ -f "$RIG_DIR/memory/.handoff-suggested" ]
  [ ! -f "$RIG_DIR/memory/.wrap-needed" ]
  [ ! -f "$RIG_DIR/memory/.post-merge-pending" ]
}

@test "handoff detector does not suggest below benchmark" {
  bind_session new
  python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["created_at"]="2999-01-01T00:00:00+00:00"; json.dump(d,open(p,"w"))' "$BOUND_FILE"

  run run_prompt_submit new
  [ "$status" -eq 0 ]
  run grep -F 'Rig handoff suggestion:' <<< "$output"
  [ "$status" -ne 0 ]
  [ ! -f "$RIG_DIR/memory/.handoff-suggested" ]
}

# ── Display-only handoff prompts (#717) ──────────────────────────────────────

handoff_surfaces() {
  printf '%s\n' \
    "$REPO_ROOT/templates/project/.claude/commands/rig-handoff.md" \
    "$REPO_ROOT/templates/project/.claude/commands/wrap.md" \
    "$REPO_ROOT/templates/global/CLAUDE.md"
}

# Each surface's own wording for "point at the snapshot instead of restating it".
# These phrases are new with #717, so the check cannot pass on older text.
snapshot_pointer_phrase() {
  case "$1" in
    */rig-handoff.md) printf '%s' 'Do not restate the full snapshot' ;;
    */wrap.md) printf '%s' 'instead of restating their contents' ;;
    */CLAUDE.md) printf '%s' 'point the next agent at `CONTEXT_SNAPSHOT.md`' ;;
  esac
}

@test "handoff guidance: every shipped surface makes handoff prompts display-only" {
  while IFS= read -r surface; do
    grep -Fq 'display-only' "$surface" || { echo "missing display-only: $surface"; return 1; }
    grep -Fq '$RIG_DIR/memory/NEXT_SESSION_PROMPT.md' "$surface" || { echo "missing fixed path: $surface"; return 1; }
    case "$surface" in
      */rig-handoff.md) grep -Fq 'Never create dated copies' "$surface" || { echo "missing dated-file ban: $surface"; return 1; } ;;
      *) grep -Fq 'Never create a' "$surface" || { echo "missing dated-file ban: $surface"; return 1; } ;;
    esac
    grep -Fq "$(snapshot_pointer_phrase "$surface")" "$surface" || { echo "missing snapshot pointer: $surface"; return 1; }
  done < <(handoff_surfaces)
}

@test "handoff guidance: saving a prompt requires an explicit user request" {
  while IFS= read -r surface; do
    case "$surface" in
      */rig-handoff.md) grep -Fq 'If the user explicitly asks to save the prompt' "$surface" ;;
      *) grep -Fq 'only when the user explicitly asks' "$surface" ;;
    esac \
      || { echo "missing explicit-request gate: $surface"; return 1; }
  done < <(handoff_surfaces)
}

@test "handoff guidance: generated Codex skills carry the display-only rule" {
  out="$TEST_ROOT/codex-skills"
  python3 "$REPO_ROOT/installer/generate-codex-skills.py" --output "$out" --base-branch main \
    "$REPO_ROOT/templates/project/.claude/commands/rig-handoff.md" \
    "$REPO_ROOT/templates/project/.claude/commands/wrap.md"
  for name in rig-handoff wrap; do
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

@test "handoff guidance: the saved handoff prompt file is gitignored like the snapshot" {
  repo="$TEST_ROOT/ignore-check"
  mkdir -p "$repo/.rig/memory"
  git -C "$repo" init -q
  cp "$REPO_ROOT/templates/project/.rig/memory/.gitignore" "$repo/.rig/memory/.gitignore"
  touch "$repo/.rig/memory/NEXT_SESSION_PROMPT.md" "$repo/.rig/memory/CONTEXT_SNAPSHOT.md"
  git -C "$repo" check-ignore -q .rig/memory/NEXT_SESSION_PROMPT.md
  git -C "$repo" check-ignore -q .rig/memory/CONTEXT_SNAPSHOT.md
}
