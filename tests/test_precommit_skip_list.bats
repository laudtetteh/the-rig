#!/usr/bin/env bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HOOK_TEMPLATE="$REPO_ROOT/templates/project/.husky/pre-commit"

setup() {
  TEST_REPO="$(mktemp -d)"
  git -C "$TEST_REPO" init -q
  git -C "$TEST_REPO" config user.email "test@example.com"
  git -C "$TEST_REPO" config user.name "Test"

  mkdir -p "$TEST_REPO/.husky" "$TEST_REPO/test-bin"
  cp "$HOOK_TEMPLATE" "$TEST_REPO/.husky/pre-commit"
  chmod +x "$TEST_REPO/.husky/pre-commit"

  # Keep this suite focused on debug scanning, independent of local gitleaks.
  printf '#!/bin/sh\nexit 0\n' > "$TEST_REPO/test-bin/gitleaks"
  chmod +x "$TEST_REPO/test-bin/gitleaks"
}

teardown() {
  rm -rf "$TEST_REPO"
}

run_hook() {
  run env PATH="$TEST_REPO/test-bin:$PATH" sh -c 'cd "$1" && .husky/pre-commit' _ "$TEST_REPO"
}

@test "Rig-owned command, agent, and process markdown skips debug scanning" {
  mkdir -p \
    "$TEST_REPO/.claude/commands" \
    "$TEST_REPO/.claude/agents" \
    "$TEST_REPO/.rig/processes"
  printf 'Remove console.log(value) before shipping.\n' > "$TEST_REPO/.claude/commands/debug.md" # rig-debug-ok
  printf 'Look for debugger; statements.\n' > "$TEST_REPO/.claude/agents/reviewer.md" # rig-debug-ok
  printf 'Python debugging may use breakpoint().\n' > "$TEST_REPO/.rig/processes/DEBUGGING.md" # rig-debug-ok
  git -C "$TEST_REPO" add -f .claude/commands/debug.md .claude/agents/reviewer.md .rig/processes/DEBUGGING.md

  run_hook

  [ "$status" -eq 0 ]
}

@test "ordinary source files containing debug artifacts still fail" {
  mkdir -p "$TEST_REPO/src"
  printf 'console.log("left behind");\n' > "$TEST_REPO/src/app.js" # rig-debug-ok
  git -C "$TEST_REPO" add src/app.js

  run_hook

  [ "$status" -eq 1 ]
  [[ "$output" == *"Debug artifact check blocked this commit."* ]] || return 1
  [[ "$output" == *"src/app.js"* ]] || return 1
}

@test "project-specific debug scan exclusions remain effective" {
  mkdir -p "$TEST_REPO/generated"
  printf 'generated/**\n' > "$TEST_REPO/.rig-debug-scan-exclude"
  printf 'console.log("generated fixture");\n' > "$TEST_REPO/generated/fixture.js" # rig-debug-ok
  git -C "$TEST_REPO" add .rig-debug-scan-exclude generated/fixture.js

  run_hook

  [ "$status" -eq 0 ]
}
