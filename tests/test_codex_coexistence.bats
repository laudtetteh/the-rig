#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  INSTALLER="$REPO_ROOT/install.sh"
  TEST_ROOT="$(mktemp -d)"
  TEST_HOME="$TEST_ROOT/home"
  TEST_PROJECT="$TEST_ROOT/project"
  mkdir -p "$TEST_HOME" "$TEST_PROJECT"
  git -C "$TEST_PROJECT" init -q
}

teardown() { rm -rf "$TEST_ROOT"; }

install_adapter_fixture() {
  mkdir -p "$TEST_PROJECT/.codex/hooks" "$TEST_PROJECT/.claude/hooks" \
    "$TEST_PROJECT/.rig/memory" "$TEST_PROJECT/.rig/rules"
  cp "$REPO_ROOT/templates/project/.codex/hooks/rig-adapter.sh" \
    "$TEST_PROJECT/.codex/hooks/rig-adapter.sh"
  cp "$REPO_ROOT/templates/project/.claude/hooks/"*.sh "$TEST_PROJECT/.claude/hooks/"
  cp "$REPO_ROOT/templates/project/.rig/rules/protected-paths.txt" \
    "$TEST_PROJECT/.rig/rules/protected-paths.txt"
  printf 'abc123  .rig/rules/protected-paths.txt\n' > "$TEST_PROJECT/.rig/memory/.rig-manifest"
}

run_adapter() {
  run bash -c 'cd "$1" && printf "%s" "$2" | bash .codex/hooks/rig-adapter.sh' \
    _ "$TEST_PROJECT" "$1"
}

run_install() {
  local agent="$1" strategy="${2:-merge}"
  shift 2 || true
  run env HOME="$TEST_HOME" bash "$INSTALLER" --project-only \
    --project-agent "$agent" --target "$TEST_PROJECT" --tracking repo \
    --strategy "$strategy" "$@"
}

@test "Codex-only install mirrors every selected command as a repository skill" {
  run_install codex
  [ "$status" -eq 0 ]
  [ ! -d "$TEST_PROJECT/.claude/commands" ]

  expected="$(find "$REPO_ROOT/templates/project/.claude/commands" -maxdepth 1 -name '*.md' ! -name 'doc-feature.md' ! -name 'doc-list.md' ! -name 'feature-context.md' ! -name 'refresh-feature-doc.md' ! -name 'rig-gaps.md' ! -name 'rig-propose.md' | wc -l | tr -d ' ')"
  actual="$(find "$TEST_PROJECT/.agents/skills" -mindepth 2 -maxdepth 2 -name SKILL.md | wc -l | tr -d ' ')"
  [ "$actual" -eq "$expected" ]
  [ -f "$TEST_PROJECT/.agents/skills/status/references/command.md" ]
  grep -Fq 'name: status' "$TEST_PROJECT/.agents/skills/status/SKILL.md"
  [ -f "$TEST_PROJECT/.agents/skills/connector-preflight/references/command.md" ]
  grep -Fq 'CONNECTOR_PREFLIGHT.md' "$TEST_PROJECT/.agents/skills/connector-preflight/references/command.md"
  grep -Fq 'exact #409 root session' "$TEST_PROJECT/.agents/skills/connector-preflight/references/command.md"
  ! grep -Fq 'SQLite' "$TEST_PROJECT/.agents/skills/connector-preflight/references/command.md"
}

@test "optional command selection is reflected in Codex skills" {
  run_install codex merge --feature-docs --contribute
  [ "$status" -eq 0 ]
  [ -f "$TEST_PROJECT/.agents/skills/doc-feature/SKILL.md" ]
  [ -f "$TEST_PROJECT/.agents/skills/rig-propose/SKILL.md" ]
}

@test "known Rig invocations are rewritten without changing paths or unknown commands" {
  source_dir="$TEST_ROOT/commands"
  output_dir="$TEST_ROOT/output"
  mkdir -p "$source_dir"
  printf 'Run /status then /ship. Keep /unknown, /tmp/status, //server/status, https://host/status, and ./.claude/commands/status.md.\n' > "$source_dir/status.md"
  printf 'Ship via /status.\n' > "$source_dir/ship.md"

  run python3 "$REPO_ROOT/installer/generate-codex-skills.py" \
    --output "$output_dir" --base-branch main "$source_dir/status.md" "$source_dir/ship.md"
  [ "$status" -eq 0 ]
  reference="$output_dir/status/references/command.md"
  grep -Fq 'Run $status then $ship.' "$reference"
  grep -Fq 'Keep /unknown, /tmp/status, //server/status, https://host/status, and ./.claude/commands/status.md.' "$reference"
}

@test "project Claude skill trees are copied intact into Codex skills" {
  command_dir="$TEST_ROOT/commands"
  skill_dir="$TEST_ROOT/claude-skills/release/references"
  output_dir="$TEST_ROOT/output"
  mkdir -p "$command_dir" "$skill_dir"
  printf '# Command: /status\n' > "$command_dir/status.md"
  printf '%s\n' '---' 'name: release' 'description: Release safely.' '---' > "$TEST_ROOT/claude-skills/release/SKILL.md"
  printf 'nested reference\n' > "$skill_dir/checklist.md"

  run python3 "$REPO_ROOT/installer/generate-codex-skills.py" \
    --output "$output_dir" --base-branch main \
    --skills-source "$TEST_ROOT/claude-skills" "$command_dir/status.md"
  [ "$status" -eq 0 ]
  cmp "$TEST_ROOT/claude-skills/release/SKILL.md" "$output_dir/release/SKILL.md"
  cmp "$skill_dir/checklist.md" "$output_dir/release/references/checklist.md"
}

@test "generated references receive the selected base branch" {
  run_install codex merge --base-branch trunk
  [ "$status" -eq 0 ]
  ! grep -R -Fq '[BASE_BRANCH]' "$TEST_PROJECT/.agents/skills"
  grep -Fq 'trunk' "$TEST_PROJECT/.agents/skills/ship/references/command.md"
}

@test "Claude-only install has no Codex skill side effects" {
  run_install claude
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_PROJECT/.agents" ]
  [ ! -e "$TEST_PROJECT/.codex" ]
}

@test "Claude-only install does not mutate pre-existing Codex hooks" {
  hook="$TEST_PROJECT/.codex/hooks/user.sh"
  mkdir -p "$(dirname "$hook")"
  printf '#!/bin/sh\nprintf user-owned\n' > "$hook"
  chmod 600 "$hook"
  before_mode="$(python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "$hook")"
  before_sum="$(cksum "$hook")"

  run_install claude
  [ "$status" -eq 0 ]
  [ "$(python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "$hook")" = "$before_mode" ]
  [ "$(cksum "$hook")" = "$before_sum" ]
  [[ "$output" != *"Codex hook"* ]]
  [[ "$output" != *"open /hooks"* ]]
}

@test "Codex skill upgrade preserves a customized generated reference" {
  run_install codex
  [ "$status" -eq 0 ]
  printf '\nuser customization\n' >> "$TEST_PROJECT/.agents/skills/status/references/command.md"

  run_install codex upgrade
  [ "$status" -eq 0 ]
  grep -Fq 'user customization' "$TEST_PROJECT/.agents/skills/status/references/command.md"
  grep -Fq '.agents/skills/status/references/command.md' "$TEST_PROJECT/.rig/memory/.rig-manifest"
  [[ "$output" == *'Non-interactive mode — skipping customized file: .agents/skills/status/references/command.md'* ]]
}

@test "global Codex target installs valid personal skills without Claude assets" {
  run env HOME="$TEST_HOME" bash "$INSTALLER" --global-only \
    --global-agent codex --strategy merge
  [ "$status" -eq 0 ]
  [ -f "$TEST_HOME/.agents/skills/code-review/SKILL.md" ]
  grep -Fq 'name: code-review' "$TEST_HOME/.agents/skills/code-review/SKILL.md"
  grep -Fq '~/.agents/skills/code-review/SKILL.md' "$TEST_HOME/.agents/skills/code-review/SKILL.md"
  ! grep -Fq '~/.claude/skills/code-review.md' "$TEST_HOME/.agents/skills/code-review/SKILL.md"
  [ ! -e "$TEST_HOME/.claude" ]
}

@test "global Codex target preserves an existing personal skill" {
  mkdir -p "$TEST_HOME/.agents/skills/code-review"
  printf 'personal customization\n' > "$TEST_HOME/.agents/skills/code-review/SKILL.md"
  run env HOME="$TEST_HOME" bash "$INSTALLER" --global-only \
    --global-agent codex --strategy overwrite
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_HOME/.agents/skills/code-review/SKILL.md")" = 'personal customization' ]
}

@test "global Codex target preserves a dangling personal-skill symlink" {
  skill_dir="$TEST_HOME/.agents/skills/code-review"
  missing_target="$TEST_ROOT/user-owned-missing-target"
  mkdir -p "$skill_dir"
  ln -s "$missing_target" "$skill_dir/SKILL.md"
  run env HOME="$TEST_HOME" bash "$INSTALLER" --global-only \
    --global-agent codex --strategy overwrite
  [ "$status" -eq 0 ]
  [ -L "$skill_dir/SKILL.md" ]
  [ "$(readlink "$skill_dir/SKILL.md")" = "$missing_target" ]
  [ ! -e "$missing_target" ]
}

@test "Codex hook manifest parses and keeps stop events distinct" {
  run python3 - "$REPO_ROOT/templates/project/.codex/hooks.json" <<'PY'
import json, pathlib, sys
hooks = json.loads(pathlib.Path(sys.argv[1]).read_text())["hooks"]
required = {"SessionStart", "SessionEnd", "SubagentStart", "SubagentStop",
            "PreToolUse", "PermissionRequest", "PostToolUse", "PreCompact",
            "PostCompact", "UserPromptSubmit", "Stop"}
assert set(hooks) == required
assert all(len(hooks[event]) == 1 for event in ("SessionEnd", "Stop", "SubagentStop"))
PY
  [ "$status" -eq 0 ]
}

@test "Codex adapter has valid Bash syntax" {
  run bash -n "$REPO_ROOT/templates/project/.codex/hooks/rig-adapter.sh"
  [ "$status" -eq 0 ]
}

@test "Codex apply_patch blocks shared-policy targets with exit 2" {
  install_adapter_fixture
  patch='*** Begin Patch
*** Update File: CLAUDE.md
@@
-old
+new
*** End Patch'
  payload="$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"apply_patch","tool_input":{"command":sys.argv[1]}}))' "$patch")"
  run_adapter "$payload"
  [ "$status" -eq 2 ]
  [[ "$output" == *"governance file"* ]]

  patch='*** Begin Patch
*** Update File: src/../CLAUDE.md
*** End Patch'
  payload="$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"apply_patch","tool_input":{"command":sys.argv[1]}}))' "$patch")"
  run_adapter "$payload"
  [ "$status" -eq 2 ]
}

@test "Codex apply_patch permits an unprotected project target" {
  install_adapter_fixture
  payload='{"hook_event_name":"PreToolUse","tool_name":"apply_patch","tool_input":{"command":"*** Begin Patch\n*** Add File: src/app.sh\n+safe\n*** End Patch"}}'
  run_adapter "$payload"
  [ "$status" -eq 0 ]
}

@test "Codex apply_patch blocks a move destination covered by policy" {
  install_adapter_fixture
  payload='{"hook_event_name":"PreToolUse","tool_name":"apply_patch","tool_input":{"command":"*** Begin Patch\n*** Update File: src/app.sh\n*** Move to: .husky/pre-commit\n*** End Patch"}}'
  run_adapter "$payload"
  [ "$status" -eq 2 ]
  [[ "$output" == *"governance file"* ]]
}

@test "Codex apply_patch fails closed for missing empty and malformed policy" {
  install_adapter_fixture
  payload='{"hook_event_name":"PreToolUse","tool_name":"apply_patch","tool_input":{"command":"*** Begin Patch\n*** Update File: src/app.sh\n*** End Patch"}}'
  rm "$TEST_PROJECT/.rig/rules/protected-paths.txt"
  run_adapter "$payload"; [ "$status" -eq 2 ]; [[ "$output" == *"missing or unreadable"* ]]
  : > "$TEST_PROJECT/.rig/rules/protected-paths.txt"
  run_adapter "$payload"; [ "$status" -eq 2 ]; [[ "$output" == *"contains no paths"* ]]
  printf 'relative/path\n' > "$TEST_PROJECT/.rig/rules/protected-paths.txt"
  run_adapter "$payload"; [ "$status" -eq 2 ]; [[ "$output" == *"malformed"* ]]
}

@test "Codex adapter fails closed when project identity is absent or mismatched" {
  install_adapter_fixture
  payload='{"hook_event_name":"SubagentStop","agent_type":"reviewer"}'
  rm "$TEST_PROJECT/.rig/memory/.rig-manifest"
  run_adapter "$payload"; [ "$status" -eq 2 ]; [[ "$output" == *"identity manifest"* ]]
  printf 'abc123  .rig/rules/other.txt\n' > "$TEST_PROJECT/.rig/memory/.rig-manifest"
  run_adapter "$payload"; [ "$status" -eq 2 ]; [[ "$output" == *"does not own"* ]]
}

@test "Codex adapter resolves an external rig directory containing spaces" {
  install_adapter_fixture
  external="$TEST_ROOT/external rig"
  mkdir -p "$external/memory" "$external/rules"
  cp "$TEST_PROJECT/.rig/memory/.rig-manifest" "$external/memory/.rig-manifest"
  cp "$TEST_PROJECT/.rig/rules/protected-paths.txt" "$external/rules/protected-paths.txt"
  printf '%s\n' "$external" > "$TEST_PROJECT/.rigpath"
  run_adapter '{"hook_event_name":"SubagentStop","agent_type":"reviewer"}'
  [ "$status" -eq 0 ]; [ "$output" = '{}' ]
}

@test "Codex compact prompt and subagent-stop shapes are normalized" {
  install_adapter_fixture
  mkdir -p "$TEST_PROJECT/.rig/memory"
  printf 'warning context\n' > "$TEST_PROJECT/.rig/memory/.wrap-needed"

  run_adapter '{"hookEventName":"PreCompact","trigger":"manual"}'
  [ "$status" -eq 0 ]
  run_adapter '{"hook_event_name":"UserPromptSubmit","prompt":"continue"}'
  [ "$status" -eq 0 ]
  python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["hookSpecificOutput"]["hookEventName"] == "UserPromptSubmit" and d["hookSpecificOutput"]["additionalContext"]' "$output"
  run_adapter '{"hook_event_name":"SubagentStop","agent_type":"reviewer","stop_hook_active":false}'
  [ "$status" -eq 0 ]; [ "$output" = '{}' ]
}

@test "installed Codex target includes executable hooks and accepts real apply_patch input shape" {
  run_install codex
  [ "$status" -eq 0 ]
  [ -f "$TEST_PROJECT/.codex/hooks.json" ]
  [ -x "$TEST_PROJECT/.codex/hooks/rig-adapter.sh" ]
  [ -x "$TEST_PROJECT/.claude/hooks/pre-tool.sh" ]
  [ ! -f "$TEST_PROJECT/.claude/settings.json" ]
  ! grep -Fq '.codex/' "$TEST_PROJECT/.rig/memory/.rig-manifest"
  ! grep -Fq '.agents/skills/' "$TEST_PROJECT/.rig/memory/.rig-manifest"
  [[ "$output" == *"open /hooks"* ]]

  payload='{"session_id":"test","cwd":"'$TEST_PROJECT'","hook_event_name":"PreToolUse","tool_name":"apply_patch","tool_use_id":"call-1","tool_input":{"command":"*** Begin Patch\n*** Update File: CLAUDE.md\n*** End Patch"}}'
  run_adapter "$payload"
  [ "$status" -eq 2 ]
}

@test "stealth Codex install excludes all Codex coexistence artifacts" {
  run env HOME="$TEST_HOME" bash "$INSTALLER" --project-only \
    --project-agent codex --target "$TEST_PROJECT" --tracking stealth --strategy merge
  [ "$status" -eq 0 ]
  exclude="$TEST_PROJECT/.git/info/exclude"
  for entry in .agents/ .codex/ .mcp.json .playwright-mcp/; do
    grep -Fxq "$entry" "$exclude"
  done
  [ -z "$(git -C "$TEST_PROJECT" status --porcelain -- .agents .codex .mcp.json .playwright-mcp)" ]
}
