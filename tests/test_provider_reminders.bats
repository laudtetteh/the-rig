#!/usr/bin/env bats
# Provider-correct housekeeping reminders (#613): Claude sees slash commands,
# Codex sees $skills, unknown providers see a neutral workflow name, and the
# merge detail comes from local Git data only.

setup() {
  CASE_DIR="$BATS_TEST_TMPDIR/project"
  RIG_DIR="$CASE_DIR/.rig"
  HOOKS="$CASE_DIR/.claude/hooks"
  mkdir -p "$RIG_DIR/memory/sessions" "$RIG_DIR/rules" "$HOOKS" "$CASE_DIR/.codex/hooks"
  for hook in prompt-submit.sh session-start.sh pre-tool.sh; do
    cp "$BATS_TEST_DIRNAME/../templates/project/.claude/hooks/$hook" "$HOOKS/$hook"
  done
  cp "$BATS_TEST_DIRNAME/../templates/project/.codex/hooks/rig-adapter.sh" "$CASE_DIR/.codex/hooks/rig-adapter.sh"
  cp "$BATS_TEST_DIRNAME/../templates/project/.rig/rules/protected-paths.txt" "$RIG_DIR/rules/protected-paths.txt"
  git -C "$CASE_DIR" init -q
  git -C "$CASE_DIR" config user.email test@example.com
  git -C "$CASE_DIR" config user.name Test
  git -C "$CASE_DIR" commit --allow-empty -q -m 'initial'
  printf '# Snapshot\n' > "$RIG_DIR/memory/CONTEXT_SNAPSHOT.md"
  # The Codex adapter refuses to run without a project identity manifest.
  printf 'abc123  .rig/rules/protected-paths.txt\n' > "$RIG_DIR/memory/.rig-manifest"
  touch "$RIG_DIR/memory/.permission-nudge-offered" "$RIG_DIR/memory/.handoff-suggested"
}

# Create a GitHub-style merge commit and print its full SHA.
make_pr_merge() {
  git -C "$CASE_DIR" checkout -q -b feature/widget
  git -C "$CASE_DIR" commit --allow-empty -q -m 'feat: add widget'
  git -C "$CASE_DIR" checkout -q -
  git -C "$CASE_DIR" merge -q --no-ff feature/widget \
    -m 'Merge pull request #42 from example/feature/widget' -m 'feat(widget): add the widget [#41]'
  git -C "$CASE_DIR" rev-parse HEAD
}

write_marker() {
  printf 'merge_sha=%s\nmerged_at=%s\n' "$1" "$2" > "$RIG_DIR/memory/.post-merge-pending"
}

prompt_context() {
  run env ${1:+RIG_AGENT="$1"} bash -c 'cd "$1" && bash .claude/hooks/prompt-submit.sh </dev/null' _ "$CASE_DIR"
  [ "$status" -eq 0 ]
  CONTEXT=$(OUTPUT="$output" python3 -c 'import json,os; print(json.loads(os.environ["OUTPUT"])["additionalContext"])')
}

@test "Claude reminders name /post-merge and /wrap" {
  write_marker abc123 2026-07-31T10:20:30-07:00
  touch "$RIG_DIR/memory/.wrap-needed"
  prompt_context
  [[ "$CONTEXT" == *"since /post-merge was last run"* ]] || return 1
  [[ "$CONTEXT" == *"Run /post-merge now"* ]] || return 1
  [[ "$CONTEXT" == *"without running /wrap."* ]] || return 1
  [[ "$CONTEXT" != *'$post-merge'* ]] || return 1
}

@test "Codex reminders name \$post-merge and \$wrap and never a slash command" {
  write_marker abc123 2026-07-31T10:20:30-07:00
  touch "$RIG_DIR/memory/.wrap-needed"
  prompt_context codex
  [[ "$CONTEXT" == *'since $post-merge was last run'* ]] || return 1
  [[ "$CONTEXT" == *'Run $post-merge now'* ]] || return 1
  [[ "$CONTEXT" == *'Run $wrap now'* ]] || return 1
  [[ "$CONTEXT" != *"/post-merge"* && "$CONTEXT" != *"/wrap"* ]] || return 1
}

@test "an unknown provider gets a neutral workflow name" {
  write_marker abc123 2026-07-31T10:20:30-07:00
  prompt_context other-agent
  [[ "$CONTEXT" == *"Run the post-merge workflow now"* ]] || return 1
  [[ "$CONTEXT" != *"/post-merge"* && "$CONTEXT" != *'$post-merge'* ]] || return 1
}

@test "a PR merge shows short SHA, PR number and title, and merge age" {
  sha=$(make_pr_merge)
  short=$(git -C "$CASE_DIR" rev-parse --short "$sha")
  write_marker "$sha" 2026-07-31T10:20:30-07:00
  prompt_context codex
  [[ "$CONTEXT" == *"Merge: $short (PR #42: feat(widget): add the widget [#41]) at 2026-07-31T10:20:30-07:00, "*" days ago."* ]] || return 1
  [[ "$CONTEXT" != *"$sha"* ]] || return 1
}

@test "a non-PR merge shows its local subject" {
  git -C "$CASE_DIR" commit --allow-empty -q -m 'chore: local merge result'
  sha=$(git -C "$CASE_DIR" rev-parse HEAD)
  write_marker "$sha" ""
  prompt_context
  [[ "$CONTEXT" == *"Merge: ${sha:0:7}"*"(chore: local merge result)."* ]] || return 1
}

@test "a non-hexadecimal marker SHA is shown verbatim and never reaches Git" {
  sentinel="$BATS_TEST_TMPDIR/injected"
  write_marker "--output=$sentinel" "not-a-time"
  prompt_context
  [ ! -e "$sentinel" ]
  [[ "$CONTEXT" == *"Merge: --output=$sentinel at not-a-time."* ]] || return 1
}

@test "session-start and prompt-submit render the same Codex merge reminder" {
  sha=$(make_pr_merge)
  write_marker "$sha" 2026-07-31T10:20:30-07:00
  prompt_context codex
  prompt_reminder=$(printf '%s\n' "$CONTEXT" | grep -F 'A merge landed')
  run env RIG_AGENT=codex RIG_SESSION_PID=613613 bash -c 'cd "$1" && printf "%s" "{\"source\":\"startup\"}" | bash .claude/hooks/session-start.sh' _ "$CASE_DIR"
  [ "$status" -eq 0 ]
  start_reminder=$(OUTPUT="$output" python3 -c 'import json,os; print(json.loads(os.environ["OUTPUT"])["hookSpecificOutput"]["additionalContext"])' | grep -F 'A merge landed')
  [ -n "$prompt_reminder" ]
  [ "$prompt_reminder" = "$start_reminder" ]
}

@test "the reminder helper block is identical in both hooks" {
  extract() {
    sed -n '/^# ── Provider-correct housekeeping reminders/,/^# ── End provider-correct housekeeping reminders/p' "$1"
  }
  hooks="$BATS_TEST_DIRNAME/../templates/project/.claude/hooks"
  [ -n "$(extract "$hooks/prompt-submit.sh")" ]
  [ "$(extract "$hooks/prompt-submit.sh")" = "$(extract "$hooks/session-start.sh")" ]
}

@test "the installed Codex adapter relays the \$post-merge reminder on UserPromptSubmit" {
  write_marker abc123 2026-07-31T10:20:30-07:00
  run bash -c 'cd "$1" && printf "%s" "{\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"hi\"}" | bash .codex/hooks/rig-adapter.sh' _ "$CASE_DIR"
  [ "$status" -eq 0 ]
  context=$(OUTPUT="$output" python3 -c 'import json,os; print(json.loads(os.environ["OUTPUT"])["hookSpecificOutput"]["additionalContext"])')
  [[ "$context" == *'Run $post-merge now'* ]] || return 1
  [[ "$context" != *"/post-merge"* ]] || return 1
}

@test "Codex never sees or consumes the Claude-only permission nudge" {
  rm "$RIG_DIR/memory/.permission-nudge-offered"
  printf '{"permissions":{"allow":[]}}\n' > "$CASE_DIR/.claude/settings.json"
  run env RIG_AGENT=codex bash -c 'cd "$1" && bash .claude/hooks/prompt-submit.sh </dev/null' _ "$CASE_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" != *"fewer-permission-prompts"* ]] || return 1
  [ ! -e "$RIG_DIR/memory/.permission-nudge-offered" ]

  prompt_context
  [[ "$CONTEXT" == *"/fewer-permission-prompts"* ]] || return 1
  [ -e "$RIG_DIR/memory/.permission-nudge-offered" ]
}

@test "Codex handoff suggestion and governance denial name Codex skills" {
  rm "$RIG_DIR/memory/.handoff-suggested"
  RIG_SESSION_FILE="$RIG_DIR/memory/sessions/session-613.json"
  python3 -c 'import json,sys,datetime; json.dump({"status":"active","started_at":(datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(hours=3)).isoformat()},open(sys.argv[1],"w"))' "$RIG_SESSION_FILE"
  run env RIG_AGENT=codex RIG_HANDOFF_ELAPSED_SECONDS=60 \
    bash -c 'cd "$1" && bash .claude/hooks/prompt-submit.sh </dev/null' _ "$CASE_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"handoff suggestion"* ]] || return 1
  [[ "$output" == *'$handoff-checklist'* && "$output" != *"/handoff-checklist"* ]] || return 1

  patch=$'*** Begin Patch\n*** Add File: CLAUDE.md\n+unsafe\n*** End Patch'
  payload=$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"apply_patch","cwd":sys.argv[1],"tool_input":{"command":sys.argv[2]}}))' "$CASE_DIR" "$patch")
  run bash -c 'cd "$1" && printf "%s" "$2" | bash .codex/hooks/rig-adapter.sh' _ "$CASE_DIR" "$payload"
  [ "$status" -eq 2 ]
  [[ "$output" == *'$rig-propose'* && "$output" != *"/rig-propose"* ]] || return 1
}
