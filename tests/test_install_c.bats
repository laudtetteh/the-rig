#!/usr/bin/env bats
#
# tests/test_install_c.bats — Integration tests for install.sh (shard c)
#
# One of five files (test_install_a.bats .. test_install_e.bats) mechanically
# split from the original tests/test_install.bats (259 tests in one file,
# ~39% of the whole suite) for CI parallelism -- see
# .rig/memory/CI_PERFORMANCE_AUDIT_2026-08-09.md and issue #505. Each file is
# a pure move of complete, unmodified @test blocks along the original file's
# own "# ── section ───" boundaries -- no test content changed. setup(),
# teardown(), run_installer(), and two helpers that were called from outside
# their originally-defining section (_sentinel_check, _sha256) are
# duplicated identically into every file's header so each remains fully
# self-contained and independently runnable.
#
# Run with: bats tests/test_install_c.bats
# Install bats: brew install bats-core  (macOS)
#               apt-get install bats    (Debian/Ubuntu)
#
# These tests call install.sh with --strategy, --target, and --project-name
# flags to drive non-interactive installation into temporary directories.
# Each test is fully isolated — temp dirs are created and destroyed per test.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
INSTALLER="$REPO_ROOT/install.sh"

# ── Helpers ───────────────────────────────────────────────────────────────────

setup() {
  # Create an isolated temp dir and a bare git repo inside it for each test.
  TEMP_DIR="$(mktemp -d)"
  TEST_PROJECT="$TEMP_DIR/test-project"
  mkdir -p "$TEST_PROJECT"
  git -C "$TEST_PROJECT" init -q
  git -C "$TEST_PROJECT" config user.email "test@test.com"
  git -C "$TEST_PROJECT" config user.name "Test"
}

teardown() {
  rm -rf "$TEMP_DIR"
}

run_installer() {
  # Convenience wrapper: always project-only, into TEST_PROJECT, with a fixed name.
  # Defaults to --tracking repo so tests remain isolated in TEMP_DIR.
  # Tests that need stealth/external tracking pass --tracking explicitly (overrides).
  run bash "$INSTALLER" --project-only \
    --target "$TEST_PROJECT" \
    --project-name "TestProject" \
    --tracking repo \
    "$@"
}


# Hoisted into every split file's shared header -- _sentinel_check() is called
# from outside the section that originally defined it in test_install.bats.
_sentinel_check() {
  # Mirrors the sentinel logic in pre-tool.sh.
  # Returns 0 (allow) or 1 (block).
  local tool_name="$1"
  local rig_dir="$2"
  local sentinel="$rig_dir/memory/.rig-commit-ok"

  if [[ "$tool_name" == "Bash" ]]; then
    # Simulate checking stdin for a git commit command
    local input="$3"
    if echo "$input" | grep -q "git commit"; then
      if [[ ! -f "$sentinel" ]]; then
        return 1  # blocked
      fi
    fi
  fi
  return 0  # allowed
}

# Hoisted into every split file's shared header -- _sha256() is called
# from outside the section that originally defined it in test_install.bats.
_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# ── is_rig_owned classification ───────────────────────────────────────────────
# These tests source a minimal stub that re-implements is_rig_owned() exactly
# as install.sh defines it, letting us unit-test the classification logic without
# running the full installer.

is_rig_owned_stub() {
  local rel="$1"
  case "$rel" in
    bin/rig|\
    .claude/hooks/*|\
    .claude/commands/*|\
    .claude/agents/*|\
    .agents/skills/*|\
    .codex/hooks.json|\
    .codex/hooks/*|\
    .rig/processes/*|\
    .rig/rules/protected-paths.txt|\
    .husky/*|\
    .gitleaks.toml)
      return 0 ;;
    *)
      return 1 ;;
  esac
}

@test "is_rig_owned: dispatcher is Rig-owned" {
  is_rig_owned_stub "bin/rig"
}

@test "is_rig_owned: hook script is Rig-owned" {
  is_rig_owned_stub ".claude/hooks/pre-tool.sh"
  [ "$?" -eq 0 ]
}

@test "is_rig_owned: slash command is Rig-owned" {
  is_rig_owned_stub ".claude/commands/ship.md"
  [ "$?" -eq 0 ]
}

@test "is_rig_owned: process file is Rig-owned" {
  is_rig_owned_stub ".rig/processes/SHIP_WORKFLOW.md"
  [ "$?" -eq 0 ]
}

@test "is_rig_owned: protected-path policy is Rig-owned" {
  is_rig_owned_stub ".rig/rules/protected-paths.txt"
  [ "$?" -eq 0 ]
}

@test "is_rig_owned: husky hook is Rig-owned" {
  is_rig_owned_stub ".husky/pre-commit"
  [ "$?" -eq 0 ]
}

@test "is_rig_owned: gitleaks config is Rig-owned" {
  is_rig_owned_stub ".gitleaks.toml"
  [ "$?" -eq 0 ]
}

@test "is_rig_owned: generated Codex skill is Rig-owned" {
  is_rig_owned_stub ".agents/skills/ship/SKILL.md"
}

@test "is_rig_owned: Codex hook registry is Rig-owned" {
  is_rig_owned_stub ".codex/hooks.json"
}

@test "is_rig_owned: Codex hook adapter is Rig-owned" {
  is_rig_owned_stub ".codex/hooks/rig-adapter.sh"
}

@test "is_rig_owned: CLAUDE.md is user-owned" {
  run is_rig_owned_stub "CLAUDE.md"
  [ "$status" -ne 0 ]
}

@test "is_rig_owned: rules file is user-owned" {
  run is_rig_owned_stub ".rig/rules/coding-standards.md"
  [ "$status" -ne 0 ]
}

@test "is_rig_owned: memory file is user-owned" {
  run is_rig_owned_stub ".rig/memory/PROGRESS.md"
  [ "$status" -ne 0 ]
}

@test "is_rig_owned: RIG_GAPS.md is user-owned (never overwritten)" {
  run is_rig_owned_stub ".rig/memory/RIG_GAPS.md"
  [ "$status" -ne 0 ]
}

@test "is_rig_owned: task file is user-owned" {
  run is_rig_owned_stub ".rig/tasks/backlog/TASK_example.md"
  [ "$status" -ne 0 ]
}

@test "is_rig_owned: GitHub template is user-owned" {
  run is_rig_owned_stub ".github/PULL_REQUEST_TEMPLATE.md"
  [ "$status" -ne 0 ]
}

# ── CLAUDE.md substitution ────────────────────────────────────────────────────

@test "project name is substituted into CLAUDE.md" {
  run_installer --strategy skip --project-name "MyAwesomeApp"
  [ "$status" -eq 0 ]
  grep -q "MyAwesomeApp" "$TEST_PROJECT/CLAUDE.md"
}

@test "REPO_ROOT placeholder is substituted in settings.json" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]
  # [REPO_ROOT] should not appear anywhere in settings.json
  run grep -q "\[REPO_ROOT\]" "$TEST_PROJECT/.claude/settings.json"
  [ "$status" -ne 0 ]
}

@test "merge strategy: does not duplicate hooks when settings.json already has Rig hooks" {
  # First install populates settings.json with the Rig hooks.
  run_installer --strategy skip
  [ "$status" -eq 0 ]
  local count_after_first
  count_after_first=$(python3 -c "
import json
with open('$TEST_PROJECT/.claude/settings.json') as f:
    s = json.load(f)
print(sum(len(v) for v in s.get('hooks', {}).values()))
")
  # Second install via merge should not add duplicate entries.
  run_installer --strategy merge
  [ "$status" -eq 0 ]
  local count_after_second
  count_after_second=$(python3 -c "
import json
with open('$TEST_PROJECT/.claude/settings.json') as f:
    s = json.load(f)
print(sum(len(v) for v in s.get('hooks', {}).values()))
")
  # Count must not grow — no duplicates added
  [ "$count_after_second" -eq "$count_after_first" ]
}

@test "merge strategy: backs up settings.json before merging into an existing one (issue #470)" {
  # First install populates settings.json.
  run_installer --strategy skip
  [ "$status" -eq 0 ]
  local before_hash
  before_hash="$(_sha256 "$TEST_PROJECT/.claude/settings.json")"

  # Second install via merge hits the merge branch against an existing
  # settings.json. Before issue #470's fix, this specific branch's backup
  # call was gated on `$COLLISION_STRATEGY == upgrade`, which is never true
  # inside the `merge)` case — so no backup was ever taken here, regardless
  # of how the merge itself turned out.
  run_installer --strategy merge
  [ "$status" -eq 0 ]

  run find "$TEST_PROJECT/.rig-backup" -name settings.json
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  local backup_hash
  backup_hash="$(_sha256 "$output")"
  [ "$backup_hash" = "$before_hash" ]
}

@test "upgrade strategy: does not duplicate hooks when settings.json already has Rig hooks" {
  # First install populates settings.json with the Rig hooks.
  run_installer --strategy skip
  [ "$status" -eq 0 ]
  local count_after_first
  count_after_first=$(python3 -c "
import json
with open('$TEST_PROJECT/.claude/settings.json') as f:
    s = json.load(f)
print(sum(len(v) for v in s.get('hooks', {}).values()))
")
  # Upgrade should not add duplicate entries.
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]
  local count_after_second
  count_after_second=$(python3 -c "
import json
with open('$TEST_PROJECT/.claude/settings.json') as f:
    s = json.load(f)
print(sum(len(v) for v in s.get('hooks', {}).values()))
")
  # Count must not grow — no duplicates added
  [ "$count_after_second" -eq "$count_after_first" ]
}

@test "fresh install: settings.json includes baseline permissions.allow entries" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]
  local allow_count
  allow_count=$(python3 -c "
import json
with open('$TEST_PROJECT/.claude/settings.json') as f:
    s = json.load(f)
print(len(s.get('permissions', {}).get('allow', [])))
")
  # Baseline has 5 read-only git patterns
  [ "$allow_count" -ge 5 ]
  grep -q '"Bash(git status\*)"' "$TEST_PROJECT/.claude/settings.json"
  grep -q '"Bash(git log\*)"' "$TEST_PROJECT/.claude/settings.json"
  grep -q '"Bash(git rev-parse\*)"' "$TEST_PROJECT/.claude/settings.json"
}

@test "merge strategy: does not duplicate permissions.allow on re-install" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]
  local count_after_first
  count_after_first=$(python3 -c "
import json
with open('$TEST_PROJECT/.claude/settings.json') as f:
    s = json.load(f)
print(len(s.get('permissions', {}).get('allow', [])))
")
  run_installer --strategy merge
  [ "$status" -eq 0 ]
  local count_after_second
  count_after_second=$(python3 -c "
import json
with open('$TEST_PROJECT/.claude/settings.json') as f:
    s = json.load(f)
print(len(s.get('permissions', {}).get('allow', [])))
")
  # Allow list count must not grow — no duplicates added
  [ "$count_after_second" -eq "$count_after_first" ]
}

@test "upgrade strategy: does not duplicate permissions.allow on upgrade" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]
  local count_after_first
  count_after_first=$(python3 -c "
import json
with open('$TEST_PROJECT/.claude/settings.json') as f:
    s = json.load(f)
print(len(s.get('permissions', {}).get('allow', [])))
")
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]
  local count_after_second
  count_after_second=$(python3 -c "
import json
with open('$TEST_PROJECT/.claude/settings.json') as f:
    s = json.load(f)
print(len(s.get('permissions', {}).get('allow', [])))
")
  [ "$count_after_second" -eq "$count_after_first" ]
}

@test "merge strategy: permissions.deny entries are preserved and not duplicated" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]
  # Baseline deny entries must be present after fresh install
  local deny_count
  deny_count=$(python3 -c "
import json
with open('$TEST_PROJECT/.claude/settings.json') as f:
    s = json.load(f)
print(len(s.get('permissions', {}).get('deny', [])))
")
  [ "$deny_count" -ge 1 ]
  grep -q '"Bash(rm -rf \*)' "$TEST_PROJECT/.claude/settings.json"
  # Add a user-custom deny entry to verify it is preserved on re-install
  python3 -c "
import json
with open('$TEST_PROJECT/.claude/settings.json') as f:
    s = json.load(f)
s.setdefault('permissions', {}).setdefault('deny', []).append('Bash(curl *)')
with open('$TEST_PROJECT/.claude/settings.json', 'w') as f:
    json.dump(s, f, indent=2)
    f.write('\n')
"
  run_installer --strategy merge
  [ "$status" -eq 0 ]
  local deny_count_after
  deny_count_after=$(python3 -c "
import json
with open('$TEST_PROJECT/.claude/settings.json') as f:
    s = json.load(f)
print(len(s.get('permissions', {}).get('deny', [])))
")
  # Count must equal original + 1 (sentinel preserved, no duplication)
  [ "$deny_count_after" -eq "$((deny_count + 1))" ]
  grep -q '"Bash(curl \*)' "$TEST_PROJECT/.claude/settings.json"
}

@test "upgrade strategy: does not duplicate permissions.deny on upgrade" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]
  local count_after_first
  count_after_first=$(python3 -c "
import json
with open('$TEST_PROJECT/.claude/settings.json') as f:
    s = json.load(f)
print(len(s.get('permissions', {}).get('deny', [])))
")
  [ "$count_after_first" -ge 1 ]
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]
  local count_after_second
  count_after_second=$(python3 -c "
import json
with open('$TEST_PROJECT/.claude/settings.json') as f:
    s = json.load(f)
print(len(s.get('permissions', {}).get('deny', [])))
")
  [ "$count_after_second" -eq "$count_after_first" ]
}

# ── Stealth mode: Husky conflict detection ────────────────────────────────────

@test "stealth mode: warns when .husky/ exists in target project" {
  local rig_external="$TEMP_DIR/rig-ext"
  mkdir -p "$rig_external" "$TEST_PROJECT/.husky"
  touch "$TEST_PROJECT/.husky/pre-commit"

  run bash "$INSTALLER" --project-only --strategy skip \
    <<< "$(printf '%s\n4\n%s\n' "$TEST_PROJECT" "$rig_external")"

  [ "$status" -eq 0 ]
  [[ "$output" == *".husky/ detected"* ]] || return 1
}

@test "--skip-git-hooks: skips .git/hooks/ writes in stealth mode" {
  local rig_external="$TEMP_DIR/rig-ext"
  mkdir -p "$rig_external"

  run bash "$INSTALLER" --project-only --strategy skip --skip-git-hooks \
    <<< "$(printf '%s\n4\n%s\n' "$TEST_PROJECT" "$rig_external")"

  [ "$status" -eq 0 ]
  [ ! -f "$TEST_PROJECT/.git/hooks/commit-msg" ]
  [[ "$output" == *"--skip-git-hooks set"* ]] || return 1
}

# ── pre-commit: .rig-debug-scan-exclude path exclusions ──────────────────────

@test "pre-commit: .rig-debug-scan-exclude skips matched paths" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]

  local hook="$TEST_PROJECT/.husky/pre-commit"

  # Stage a file containing a debug artifact
  mkdir -p "$TEST_PROJECT/vendor"
  printf 'console.log("test");\n' > "$TEST_PROJECT/vendor/debug.js" # rig-debug-ok
  git -C "$TEST_PROJECT" add vendor/debug.js

  # Without exclusion the hook blocks
  run bash -c "cd '$TEST_PROJECT' && sh '$hook'"
  [ "$status" -ne 0 ]

  # Add the path to .rig-debug-scan-exclude
  printf 'vendor/*\n' > "$TEST_PROJECT/.rig-debug-scan-exclude"

  # With exclusion the hook passes
  run bash -c "cd '$TEST_PROJECT' && sh '$hook'"
  [ "$status" -eq 0 ]
}

# ── Global layer upgrade ──────────────────────────────────────────────────────

@test "notifications opt-in installs helper and merges Claude settings" {
  local fake_home="$TEMP_DIR/fake-home"
  mkdir -p "$fake_home"
  run env HOME="$fake_home" TERM_PROGRAM=iTerm.app TERM=xterm bash "$INSTALLER" \
    --global-only --global-agent claude --strategy skip --notifications
  [ "$status" -eq 0 ]
  [ -x "$fake_home/.claude/bin/rig-notify" ]
  run jq -e '.preferredNotifChannel == "iterm2" and (.hooks.Notification|length == 1) and (.hooks.Stop|length == 1) and (.hooks.SubagentStop|length == 1) and (.hooks.PermissionRequest|length == 1)' "$fake_home/.claude/settings.json"
  [ "$status" -eq 0 ]
}

@test "global Claude target installs rig-upgrade bootstrap command" {
  local fake_home="$TEMP_DIR/fake-home"
  mkdir -p "$fake_home"
  run env HOME="$fake_home" bash "$INSTALLER" \
    --global-only --global-agent claude --strategy merge
  [ "$status" -eq 0 ]
  [ -f "$fake_home/.claude/commands/rig-upgrade.md" ]
  grep -Fq 'Global-first bootstrap' "$fake_home/.claude/commands/rig-upgrade.md"
  grep -q '  commands/rig-upgrade.md$' "$fake_home/.claude/.rig-global-manifest"
}

@test "rig-notify fails open for CI dumb and unknown events" {
  local helper="$REPO_ROOT/templates/global/bin/rig-notify"
  run env CI=1 TERM=xterm bash "$helper" stop
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run env -u CI TERM=dumb bash "$helper" permission-request
  [ "$status" -eq 0 ]
  run env -u CI TERM=xterm bash "$helper" adversarial-secret
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

_make_failing_sha_tools() {
  FAKE_SHA_BIN="$TEMP_DIR/fake-sha-bin"
  mkdir -p "$FAKE_SHA_BIN"
  printf '#!/usr/bin/env bash\nexit 127\n' > "$FAKE_SHA_BIN/sha256sum"
  printf '#!/usr/bin/env bash\nexit 127\n' > "$FAKE_SHA_BIN/shasum"
  chmod +x "$FAKE_SHA_BIN/sha256sum" "$FAKE_SHA_BIN/shasum"
}

@test "upgrade strategy: global Codex skills are manifest tracked and customization safe" {
  local fake_home="$TEMP_DIR/fake-home"
  mkdir -p "$fake_home"

  run env HOME="$fake_home" bash "$INSTALLER" --global-only \
    --global-agent codex --strategy upgrade
  [ "$status" -eq 0 ]
  local skill
  skill="$(find "$fake_home/.agents/skills" -name SKILL.md -print -quit)"
  [ -n "$skill" ]
  local skill_rel="${skill#$fake_home/}"
  grep -q "  $skill_rel$" "$fake_home/.agents/.rig-global-manifest"

  printf '\n<!-- personal customization -->\n' >> "$skill"
  run env HOME="$fake_home" bash "$INSTALLER" --global-only \
    --global-agent codex --strategy upgrade
  [ "$status" -eq 0 ]
  [[ "$output" == *"Non-interactive mode — skipping customized file: $skill_rel"* ]] || return 1
  grep -q 'personal customization' "$skill"
}

@test "upgrade strategy: clean global Claude skills still auto-update with legacy user-owned metadata" {
  local fake_home="$TEMP_DIR/fake-home"
  mkdir -p "$fake_home"

  run env HOME="$fake_home" bash "$INSTALLER" --global-only \
    --global-agent claude --strategy upgrade
  [ "$status" -eq 0 ]

  local skill="$fake_home/.claude/skills/code-review.md"
  [ -f "$skill" ]
  printf '# old global skill\n' > "$skill"
  local old_hash
  old_hash="$(_sha256 "$skill")"
  awk -v hash="$old_hash" '
    $2 == "skills/code-review.md" { print hash "  skills/code-review.md"; next }
    { print }
  ' "$fake_home/.claude/.rig-global-manifest" > "$TEMP_DIR/global-manifest"
  mv "$TEMP_DIR/global-manifest" "$fake_home/.claude/.rig-global-manifest"
  jq --arg hash "$old_hash" '.entries["skills/code-review.md"].sha256 = $hash | .entries["skills/code-review.md"].owner = "user"' \
    "$fake_home/.claude/.rig-global-manifest.json" > "$TEMP_DIR/global-manifest.json"
  mv "$TEMP_DIR/global-manifest.json" "$fake_home/.claude/.rig-global-manifest.json"

  run env HOME="$fake_home" bash "$INSTALLER" --global-only \
    --global-agent claude --strategy upgrade
  [ "$status" -eq 0 ]
  [[ "$output" == *"Updated: skills/code-review.md"* ]] || return 1
  run grep -q '# old global skill' "$skill"
  [ "$status" -ne 0 ]
}

@test "upgrade strategy: preserves a symlinked global Claude root" {
  local fake_home="$TEMP_DIR/fake-home"
  local outside_claude="$TEMP_DIR/outside-claude"
  mkdir -p "$fake_home"

  run bash -c "echo '' | HOME='$fake_home' bash '$INSTALLER' --global-only --strategy skip"
  [ "$status" -eq 0 ]
  printf 'outside-global-sentinel\n' > "$fake_home/.claude/sentinel.txt"
  mv "$fake_home/.claude" "$outside_claude"
  ln -s "$outside_claude" "$fake_home/.claude"

  run bash -c "echo '' | HOME='$fake_home' bash '$INSTALLER' --global-only --strategy upgrade"
  [ "$status" -eq 0 ]
  [ -L "$fake_home/.claude" ]
  [ "$(cat "$outside_claude/sentinel.txt")" = "outside-global-sentinel" ]
  [[ "$output" == *"Preserved conflicting upgrade destination: .claude (symlink)"* ]] || return 1
}

@test "upgrade strategy: global CLAUDE.md is preserved when hash matches user-owned manifest" {
  local fake_home="$TEMP_DIR/fake-home"
  mkdir -p "$fake_home"

  # First install global layer into fake home (non-interactive: pipe empty input for prompts)
  run bash -c "echo '' | HOME='$fake_home' bash '$INSTALLER' --global-only --strategy skip"
  [ "$status" -eq 0 ]
  [ -f "$fake_home/.claude/CLAUDE.md" ]

  # Simulate an older installed version and record its hash in the global manifest
  printf '# old version\n' > "$fake_home/.claude/CLAUDE.md"
  local old_hash
  old_hash=$(_sha256 "$fake_home/.claude/CLAUDE.md")
  printf '%s  CLAUDE.md\n' "$old_hash" > "$fake_home/.claude/.rig-global-manifest"

  # Run upgrade — CLAUDE.md hash matches a user-owned manifest entry, so it
  # remains protected even though its hash matches the baseline.
  run bash -c "echo '' | HOME='$fake_home' bash '$INSTALLER' --global-only --strategy upgrade"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Skipped (user-owned): CLAUDE.md"* ]] || return 1

  grep -q '# old version' "$fake_home/.claude/CLAUDE.md"
}

@test "upgrade strategy: customized global file not overwritten in non-interactive" {
  local fake_home="$TEMP_DIR/fake-home"
  mkdir -p "$fake_home"

  # First install global layer
  run bash -c "echo '' | HOME='$fake_home' bash '$INSTALLER' --global-only --strategy skip"
  [ "$status" -eq 0 ]

  # Record original hash in manifest
  local orig_hash
  orig_hash=$(_sha256 "$fake_home/.claude/CLAUDE.md")
  printf '%s  CLAUDE.md\n' "$orig_hash" > "$fake_home/.claude/.rig-global-manifest"

  # Simulate user customization (hash now differs from manifest)
  printf '\n# user customization\n' >> "$fake_home/.claude/CLAUDE.md"

  # Upgrade in non-interactive mode — must NOT overwrite the customized file
  run bash -c "echo '' | HOME='$fake_home' bash '$INSTALLER' --global-only --strategy upgrade"
  [ "$status" -eq 0 ]
  grep -q '# user customization' "$fake_home/.claude/CLAUDE.md"
}

@test "upgrade strategy: global CLAUDE.md never overwritten with no manifest entry (issue #470/#471 review)" {
  # The actual #140 precondition, at the global layer: a real, hand-written
  # ~/.claude/CLAUDE.md and zero manifest of any kind — no prior installer
  # run at all. _copy_global_file_upgrade() previously hardcoded
  # rig_owned_default=true for every file it handled (CLAUDE.md included),
  # so a missing manifest entry took the unconditional-overwrite branch
  # regardless of is_rig_owned("CLAUDE.md") already correctly saying
  # user-owned. Found during independent review of PR #471, before merge.
  local fake_home="$TEMP_DIR/fake-home"
  mkdir -p "$fake_home/.claude"
  printf 'MY REAL HAND-WRITTEN GLOBAL CLAUDE.MD CONTENT\n' > "$fake_home/.claude/CLAUDE.md"

  run bash -c "echo '' | HOME='$fake_home' bash '$INSTALLER' --global-only --strategy upgrade"
  [ "$status" -eq 0 ]
  grep -q 'MY REAL HAND-WRITTEN GLOBAL CLAUDE.MD CONTENT' "$fake_home/.claude/CLAUDE.md"
}

@test "upgrade strategy: global file prompts and updates when SHA256 tools fail" {
  local fake_home="$TEMP_DIR/fake-home"
  mkdir -p "$fake_home"
  run bash -c "echo '' | HOME='$fake_home' bash '$INSTALLER' --global-only --strategy skip"
  [ "$status" -eq 0 ]

  printf '# stale global version\n' > "$fake_home/.claude/CLAUDE.md"
  _make_failing_sha_tools
  run env HOME="$fake_home" PATH="$FAKE_SHA_BIN:$PATH" \
    bash -c "echo '' | bash '$INSTALLER' --global-only --strategy upgrade"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sha256 unavailable — cannot detect customizations in: CLAUDE.md"* ]] || return 1
  [[ "$output" == *"Updated: CLAUDE.md"* ]] || return 1
  if grep -q '# stale global version' "$fake_home/.claude/CLAUDE.md"; then return 1; fi
}

@test "upgrade strategy: identical global file stays quiet when SHA256 tools fail" {
  local fake_home="$TEMP_DIR/fake-home"
  mkdir -p "$fake_home"
  run bash -c "echo '' | HOME='$fake_home' bash '$INSTALLER' --global-only --strategy skip"
  [ "$status" -eq 0 ]

  _make_failing_sha_tools
  run env HOME="$fake_home" PATH="$FAKE_SHA_BIN:$PATH" \
    bash -c "echo '' | bash '$INSTALLER' --global-only --strategy upgrade"
  [ "$status" -eq 0 ]
  [[ "$output" != *"sha256 unavailable"* ]] || return 1
  [[ "$output" == *"Up to date: CLAUDE.md"* ]] || return 1
}

# ── install.sh: branch drift warning ─────────────────────────────────────────

@test "installer drift check: warns when installer repo is behind remote" {
  # Create a bare remote repo and a local clone that's 1 commit behind
  local remote_repo="$TEMP_DIR/rig-remote"
  local local_repo="$TEMP_DIR/rig-local"

  git init -q "$remote_repo"
  git -C "$remote_repo" config user.email "test@test.com"
  git -C "$remote_repo" config user.name "Test"
  touch "$remote_repo/placeholder"
  git -C "$remote_repo" add placeholder
  git -C "$remote_repo" commit -q -m "initial commit"

  git clone -q "$remote_repo" "$local_repo"
  git -C "$local_repo" config user.email "test@test.com"
  git -C "$local_repo" config user.name "Test"

  # Add a commit to the remote that the local doesn't have
  touch "$remote_repo/newfile"
  git -C "$remote_repo" add newfile
  git -C "$remote_repo" commit -q -m "new commit on remote"

  # Run installer with _RIG_DRIFT_DIR pointing to the local (stale) repo
  run bash -c "_RIG_DRIFT_DIR='$local_repo' bash '$INSTALLER' --project-only \
    --target '$TEST_PROJECT' --project-name 'TestProject' --tracking repo --strategy skip"
  [ "$status" -eq 0 ]
  [[ "$output" == *"behind"* ]] || return 1
}

@test "installer drift check: no warning when installer repo is up to date" {
  # A git repo with a remote that matches HEAD — no warning expected
  local remote_repo="$TEMP_DIR/rig-remote"
  local local_repo="$TEMP_DIR/rig-local"

  git init -q "$remote_repo"
  git -C "$remote_repo" config user.email "test@test.com"
  git -C "$remote_repo" config user.name "Test"
  touch "$remote_repo/placeholder"
  git -C "$remote_repo" add placeholder
  git -C "$remote_repo" commit -q -m "initial commit"

  git clone -q "$remote_repo" "$local_repo"
  git -C "$local_repo" config user.email "test@test.com"
  git -C "$local_repo" config user.name "Test"

  # Local and remote are in sync
  run bash -c "_RIG_DRIFT_DIR='$local_repo' bash '$INSTALLER' --project-only \
    --target '$TEST_PROJECT' --project-name 'TestProject' --tracking repo --strategy skip"
  [ "$status" -eq 0 ]
  [[ "$output" != *"behind"* ]] || return 1
}

@test "installer drift check: non-interactive mode warns and continues without blocking" {
  # stdin is not a TTY in bats — this verifies the non-interactive path does not
  # hang waiting for user input and exits 0 (not 3/exit-on-default).
  local remote_repo="$TEMP_DIR/rig-remote-ni"
  local local_repo="$TEMP_DIR/rig-local-ni"

  git init -q "$remote_repo"
  git -C "$remote_repo" config user.email "test@test.com"
  git -C "$remote_repo" config user.name "Test"
  touch "$remote_repo/placeholder"
  git -C "$remote_repo" add placeholder
  git -C "$remote_repo" commit -q -m "initial commit"

  git clone -q "$remote_repo" "$local_repo"
  git -C "$local_repo" config user.email "test@test.com"
  git -C "$local_repo" config user.name "Test"

  touch "$remote_repo/newfile"
  git -C "$remote_repo" add newfile
  git -C "$remote_repo" commit -q -m "new commit on remote"

  run bash -c "_RIG_DRIFT_DIR='$local_repo' bash '$INSTALLER' --project-only \
    --target '$TEST_PROJECT' --project-name 'TestProject' --tracking repo --strategy skip"
  [ "$status" -eq 0 ]
  [[ "$output" == *"behind"* ]] || return 1
  # Installer must have continued past the warning — pre-tool.sh is a reliable install marker
  [ -f "$TEST_PROJECT/.claude/hooks/pre-tool.sh" ]
}

# ── Command behavior: /status ─────────────────────────────────────────────────
# /status reads RIG_DIR, counts backlog tasks, and checks pending flag files.
# We test the extractable shell logic in isolation.

_status_resolve_rig_dir() {
  # Mirrors RIG_DIR resolution in /status (and all other commands).
  # Prints the resolved RIG_DIR path.
  local repo="$1"
  if [[ -f "$repo/.rigpath" ]]; then
    tr -d '[:space:]' < "$repo/.rigpath"
  else
    echo "$repo/.rig"
  fi
}

_status_pending_flags() {
  # Returns a space-separated list of active flag names, or nothing.
  local rig_dir="$1"
  local flags=""
  [[ -f "$rig_dir/memory/.wrap-needed" ]] && flags="$flags wrap-needed"
  [[ -f "$rig_dir/memory/.post-merge-pending" ]] && flags="$flags post-merge-pending"
  echo "${flags# }"
}

_status_backlog_count() {
  # Returns the number of task files in the backlog directory.
  ls "$1/tasks/backlog/" 2>/dev/null | wc -l | tr -d '[:space:]'
}

@test "status: RIG_DIR resolves to repo/.rig when .rigpath absent" {
  local repo="$TEMP_DIR/repo"
  mkdir -p "$repo"

  result=$(_status_resolve_rig_dir "$repo")
  [ "$result" = "$repo/.rig" ]
}

@test "status: RIG_DIR resolves to external path when .rigpath present" {
  local repo="$TEMP_DIR/repo"
  local external="$TEMP_DIR/external-rig"
  mkdir -p "$repo"
  echo "$external" > "$repo/.rigpath"

  result=$(_status_resolve_rig_dir "$repo")
  [ "$result" = "$external" ]
}

@test "status: no pending flags when neither sentinel exists" {
  local rig_dir="$TEMP_DIR/rig"
  mkdir -p "$rig_dir/memory"

  result=$(_status_pending_flags "$rig_dir")
  [ "$result" = "" ]
}

@test "status: wrap-needed flag detected when sentinel present" {
  local rig_dir="$TEMP_DIR/rig"
  mkdir -p "$rig_dir/memory"
  touch "$rig_dir/memory/.wrap-needed"

  result=$(_status_pending_flags "$rig_dir")
  [[ "$result" == *"wrap-needed"* ]] || return 1
}

@test "status: both flags detected when both sentinels present" {
  local rig_dir="$TEMP_DIR/rig"
  mkdir -p "$rig_dir/memory"
  touch "$rig_dir/memory/.wrap-needed"
  touch "$rig_dir/memory/.post-merge-pending"

  result=$(_status_pending_flags "$rig_dir")
  [[ "$result" == *"wrap-needed"* ]] || return 1
  [[ "$result" == *"post-merge-pending"* ]] || return 1
}

@test "status: backlog count returns correct number of task files" {
  local rig_dir="$TEMP_DIR/rig"
  mkdir -p "$rig_dir/tasks/backlog"
  touch "$rig_dir/tasks/backlog/TASK_alpha.md"
  touch "$rig_dir/tasks/backlog/TASK_beta.md"
  touch "$rig_dir/tasks/backlog/TASK_gamma.md"

  result=$(_status_backlog_count "$rig_dir")
  [ "$result" = "3" ]
}

@test "status: backlog count is zero when backlog directory is empty" {
  local rig_dir="$TEMP_DIR/rig"
  mkdir -p "$rig_dir/tasks/backlog"

  result=$(_status_backlog_count "$rig_dir")
  [ "$result" = "0" ]
}

# ── Command behavior: /wrap concurrent session guard ──────────────────────────
# /wrap checks for .wrap-in-progress before doing anything, then creates it.
# We test the acquire/release cycle in isolation.

_wrap_acquire_lock() {
  # Mirrors the concurrent session guard in /wrap and /post-merge.
  # Returns 0 (lock acquired + sentinel created) or 1 (active lock present).
  local wrap_lock="$1"
  if [[ -f "$wrap_lock" ]]; then
    local lock_age
    lock_age=$(( $(date +%s) - $(stat -c %Y "$wrap_lock" 2>/dev/null || stat -f %m "$wrap_lock" 2>/dev/null || echo 0) ))
    if [[ "$lock_age" -gt 1800 ]]; then
      rm -f "$wrap_lock"  # stale — auto-expire
    else
      return 1  # active lock, block
    fi
  fi
  touch "$wrap_lock"
  return 0
}

_wrap_release_lock() {
  # Mirrors the cleanup at the end of /wrap (step 11).
  local wrap_lock="$1"
  rm -f "$wrap_lock"
}

@test "wrap guard: lock acquisition blocked when sentinel already exists" {
  local rig_dir="$TEMP_DIR/rig"
  mkdir -p "$rig_dir/memory"
  local lock="$rig_dir/memory/.wrap-in-progress"
  touch "$lock"  # fresh mtime — under 1800s, must block

  run _wrap_acquire_lock "$lock"
  [ "$status" -ne 0 ]
}

@test "wrap guard: stale lock (>1800s) is auto-removed and acquisition proceeds" {
  local rig_dir="$TEMP_DIR/rig"
  mkdir -p "$rig_dir/memory"
  local lock="$rig_dir/memory/.wrap-in-progress"
  touch "$lock"
  # Set mtime to 2025-01-01 00:00 — guaranteed older than 30 minutes
  touch -t 202501010000 "$lock"

  run _wrap_acquire_lock "$lock"
  [ "$status" -eq 0 ]
  [ -f "$lock" ]  # new lock written
  # Verify the new lock has a recent mtime (within 60s of now)
  local new_age
  new_age=$(( $(date +%s) - $(stat -c %Y "$lock" 2>/dev/null || stat -f %m "$lock" 2>/dev/null || echo 0) ))
  [ "$new_age" -lt 60 ]
}

@test "wrap guard: lock acquired and sentinel created when none exists" {
  local rig_dir="$TEMP_DIR/rig"
  mkdir -p "$rig_dir/memory"
  local lock="$rig_dir/memory/.wrap-in-progress"

  run _wrap_acquire_lock "$lock"
  [ "$status" -eq 0 ]
  [[ -f "$lock" ]] || return 1
}

@test "wrap guard: sentinel removed after lock release" {
  local rig_dir="$TEMP_DIR/rig"
  mkdir -p "$rig_dir/memory"
  local lock="$rig_dir/memory/.wrap-in-progress"
  touch "$lock"

  _wrap_release_lock "$lock"
  [[ ! -f "$lock" ]] || return 1
}
