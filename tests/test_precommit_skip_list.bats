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
  printf '# test config\n' > "$TEST_REPO/.gitleaks.toml"

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

run_hook_without_stubbed_gitleaks() {
  run env PATH="/usr/bin:/bin" RIG_GITLEAKS_PATH_ONLY=1 sh -c 'cd "$1" && .husky/pre-commit' _ "$TEST_REPO"
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

@test "gitleaks missing config is reported as configuration error" {
  rm -f "$TEST_REPO/.gitleaks.toml"
  printf 'safe\n' > "$TEST_REPO/file.txt"
  git -C "$TEST_REPO" add file.txt

  run_hook

  [ "$status" -eq 1 ]
  [[ "$output" == *"gitleaks configuration error"* ]] || return 1
  [[ "$output" == *".gitleaks.toml is missing"* ]] || return 1
  [[ "$output" != *"secrets detected"* ]] || return 1
}

@test "gitleaks scanner config failure is not reported as detected secrets" {
  cat > "$TEST_REPO/test-bin/gitleaks" <<'EOF'
#!/bin/sh
echo "failed to load config: bad toml" >&2
exit 2
EOF
  chmod +x "$TEST_REPO/test-bin/gitleaks"
  printf 'safe\n' > "$TEST_REPO/file.txt"
  git -C "$TEST_REPO" add file.txt

  run_hook

  [ "$status" -eq 1 ]
  [[ "$output" == *"failed to load config"* ]] || return 1
  [[ "$output" == *"gitleaks configuration error"* ]] || return 1
  [[ "$output" != *"secrets detected"* ]] || return 1
}

@test "gitleaks leak finding preserves secrets detected wording" {
  cat > "$TEST_REPO/test-bin/gitleaks" <<'EOF'
#!/bin/sh
echo "Finding: generic-api-key"
exit 1
EOF
  chmod +x "$TEST_REPO/test-bin/gitleaks"
  printf 'token\n' > "$TEST_REPO/file.txt"
  git -C "$TEST_REPO" add file.txt

  run_hook

  [ "$status" -eq 1 ]
  [[ "$output" == *"Finding: generic-api-key"* ]] || return 1
  [[ "$output" == *"secrets detected in staged files"* ]] || return 1
}

@test "gitleaks leak finding mentioning config path is still reported as secret" {
  cat > "$TEST_REPO/test-bin/gitleaks" <<'EOF'
#!/bin/sh
echo "Finding: generic-api-key in config/settings.env"
exit 1
EOF
  chmod +x "$TEST_REPO/test-bin/gitleaks"
  mkdir -p "$TEST_REPO/config"
  printf 'token\n' > "$TEST_REPO/config/settings.env"
  git -C "$TEST_REPO" add config/settings.env

  run_hook

  [ "$status" -eq 1 ]
  [[ "$output" == *"Finding: generic-api-key in config/settings.env"* ]] || return 1
  [[ "$output" == *"secrets detected in staged files"* ]] || return 1
  [[ "$output" != *"gitleaks configuration error"* ]] || return 1
}

@test "missing gitleaks binary still warns and continues to debug scan" {
  rm -f "$TEST_REPO/test-bin/gitleaks"
  printf 'safe\n' > "$TEST_REPO/file.txt"
  git -C "$TEST_REPO" add file.txt

  run_hook_without_stubbed_gitleaks

  [ "$status" -eq 0 ]
  [[ "$output" == *"gitleaks not installed"* ]] || return 1
}

# A gitleaks stub that always reports a finding, so a run is observable.
stub_gitleaks_finding() {
  cat > "$TEST_REPO/test-bin/gitleaks" <<'STUB'
#!/bin/sh
echo "Finding: stub-secret"
exit 1
STUB
  chmod +x "$TEST_REPO/test-bin/gitleaks"
  printf 'clean\n' > "$TEST_REPO/clean.txt"
  git -C "$TEST_REPO" add clean.txt
}

@test "secret-scanner: none in CLAUDE.md skips gitleaks" {
  stub_gitleaks_finding
  printf 'secret-scanner: none # intentional opt-out\n' > "$TEST_REPO/CLAUDE.md"
  run_hook
  [ "$status" -eq 0 ]
  [[ "$output" == *"Secret scanning disabled (CLAUDE.md secret-scanner: none)"* ]] || return 1
  [[ "$output" != *"gitleaks blocked this commit"* ]] || return 1
}

@test "secret-scanner: none with an extra value keeps gitleaks enabled" {
  stub_gitleaks_finding
  printf 'secret-scanner: none accidental\n' > "$TEST_REPO/CLAUDE.md"
  run_hook
  [ "$status" -eq 1 ]
  [[ "$output" == *"not exactly one well-formed"* ]] || return 1
  [[ "$output" == *"gitleaks blocked this commit"* ]] || return 1
  [[ "$output" != *"Secret scanning disabled"* ]] || return 1
}

@test "secret-scanner: duplicate none settings keep gitleaks enabled" {
  stub_gitleaks_finding
  printf 'secret-scanner: none\nsecret-scanner: none\n' > "$TEST_REPO/CLAUDE.md"
  run_hook
  [ "$status" -eq 1 ]
  [[ "$output" == *"not exactly one well-formed"* ]] || return 1
  [[ "$output" == *"gitleaks blocked this commit"* ]] || return 1
  [[ "$output" != *"Secret scanning disabled"* ]] || return 1
}

@test "secret-scanner: gitleaks and a missing setting both keep gitleaks" {
  stub_gitleaks_finding
  printf 'secret-scanner: gitleaks\n' > "$TEST_REPO/CLAUDE.md"
  run_hook
  [ "$status" -eq 1 ]
  [[ "$output" == *"gitleaks blocked this commit"* ]] || return 1

  printf '# no setting\n' > "$TEST_REPO/CLAUDE.md"
  run_hook
  [ "$status" -eq 1 ]
  [[ "$output" == *"gitleaks blocked this commit"* ]] || return 1
}

@test "secret-scanner: an unknown or conflicting value fails safe to gitleaks" {
  stub_gitleaks_finding
  printf 'secret-scanner: nope\n' > "$TEST_REPO/CLAUDE.md"
  run_hook
  [ "$status" -eq 1 ]
  [[ "$output" == *"not exactly one well-formed 'gitleaks' or 'none' value"* ]] || return 1
  [[ "$output" == *"gitleaks blocked this commit"* ]] || return 1

  printf 'secret-scanner: none\nsecret-scanner: gitleaks\n' > "$TEST_REPO/CLAUDE.md"
  run_hook
  [ "$status" -eq 1 ]
  [[ "$output" == *"gitleaks blocked this commit"* ]] || return 1
}
