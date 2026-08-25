#!/usr/bin/env bats
#
# tests/test_install_d.bats — Integration tests for install.sh (shard d)
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
# Run with: bats tests/test_install_d.bats
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
  sha256sum "$1" 2>/dev/null | awk '{print $1}' || shasum -a 256 "$1" | awk '{print $1}'
}

# ── settings.json merge ───────────────────────────────────────────────────────

@test "merge strategy: creates settings.json when absent" {
  run_installer --strategy merge
  [ "$status" -eq 0 ]
  [ -f "$TEST_PROJECT/.claude/settings.json" ]
}

@test "skip strategy: settings.json is created on fresh install" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]
  [ -f "$TEST_PROJECT/.claude/settings.json" ]
}

# ── CLI flag validation ───────────────────────────────────────────────────────

@test "--strategy with invalid value warns and falls back to interactive" {
  # We can't fully drive interactive mode in bats, but we can verify the
  # installer doesn't crash on an unknown strategy value — it should warn
  # and continue (or at least not exit non-zero before the interaction).
  # Instead, check that a valid unknown value produces a warning in output.
  run bash "$INSTALLER" --project-only \
    --target "$TEST_PROJECT" \
    --project-name "TestProject" \
    --strategy "bogus" <<< "2"   # pipe "2" (skip) to answer the strategy prompt
  # The installer should still succeed when given a fallback answer
  [ "$status" -eq 0 ]
}

@test "--target with non-existent path exits non-zero" {
  run bash "$INSTALLER" --project-only \
    --target "/tmp/definitely-does-not-exist-$$" \
    --project-name "Test" \
    --strategy skip
  [ "$status" -ne 0 ]
}

@test "non-interactive: --project-only with empty stdin does not exit 1 on intent menu read" {
  # Simulates Claude Code / CI calling install.sh --project-only without --strategy.
  # Without the || true fix, read exits 1 on EOF and set -euo pipefail kills the script.
  run bash "$INSTALLER" --project-only \
    --target "$TEST_PROJECT" \
    --project-name "TestProject" <<< ""
  [ "$status" -eq 0 ]
}

@test "non-interactive: --project-only --strategy --tracking installs without any prompt" {
  # Full non-interactive form — all menus bypassed via flags.
  run bash "$INSTALLER" --project-only \
    --target "$TEST_PROJECT" \
    --project-name "TestProject" \
    --tracking stealth \
    --strategy merge <<< ""
  [ "$status" -eq 0 ]
  [ -f "$TEST_PROJECT/.claude/settings.json" ]
}

# ── Hook behavior: main-branch commit guard ───────────────────────────────────
# pre-tool.sh blocks git commit on main/master unless CLAUDE.md sets
# housekeeping: direct-push. Tested independently of the sentinel check.

_main_branch_check() {
  # Mirrors the main-branch guard logic in pre-tool.sh.
  # Returns 0 (allow) or 1 (block).
  local current_branch="$1"
  local repo_dir="$2"

  if [[ "$current_branch" == "main" || "$current_branch" == "master" ]]; then
    local housekeeping
    housekeeping=$(grep "^housekeeping:" "$repo_dir/CLAUDE.md" 2>/dev/null \
      | awk '{print $2}' | tr -d '[:space:]' || echo "")
    if [[ "$housekeeping" != "direct-push" ]]; then
      return 1  # blocked
    fi
  fi
  return 0  # allowed
}

@test "main-branch guard: commit to main blocked when housekeeping is not direct-push" {
  local repo_dir="$TEMP_DIR/repo"
  mkdir -p "$repo_dir"
  echo "# CLAUDE.md" > "$repo_dir/CLAUDE.md"

  run _main_branch_check "main" "$repo_dir"
  [ "$status" -ne 0 ]
}

@test "main-branch guard: commit to main allowed when housekeeping is direct-push" {
  local repo_dir="$TEMP_DIR/repo"
  mkdir -p "$repo_dir"
  echo "housekeeping: direct-push" > "$repo_dir/CLAUDE.md"

  run _main_branch_check "main" "$repo_dir"
  [ "$status" -eq 0 ]
}

@test "main-branch guard: commit to non-main branch always passes" {
  local repo_dir="$TEMP_DIR/repo"
  mkdir -p "$repo_dir"

  run _main_branch_check "feat/my-feature" "$repo_dir"
  [ "$status" -eq 0 ]
}

# ── --tracking flag ───────────────────────────────────────────────────────────

@test "--tracking stealth: installs without prompting when used with --target" {
  local rig_ext="$TEMP_DIR/rig-external"
  run_installer --strategy skip --tracking stealth --rig-dir "$rig_ext"
  [ "$status" -eq 0 ]
  [ -f "$rig_ext/memory/PROGRESS.md" ]
  [ ! -f "$TEST_PROJECT/.rig/memory/PROGRESS.md" ]
}

@test "--tracking: invalid value exits non-zero with error message" {
  run_installer --strategy skip --tracking bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid --tracking"* ]] || return 1
}

@test "--target without --tracking defaults to stealth tracking" {
  local rig_ext="$TEMP_DIR/rig-stealth-default"
  # Call installer directly (not run_installer) — no --tracking, no prompt stdin
  run bash "$INSTALLER" --project-only \
    --target "$TEST_PROJECT" \
    --project-name "TestProject" \
    --strategy skip \
    --rig-dir "$rig_ext"
  # .rig/ lands in external dir, not inside the project
  [ -f "$rig_ext/memory/PROGRESS.md" ]
  [ ! -f "$TEST_PROJECT/.rig/memory/PROGRESS.md" ]
  [ -f "$TEST_PROJECT/.rigpath" ]
}

@test "upgrade without --tracking auto-detects stealth mode from .rigpath" {
  # Simulate a project previously installed with --tracking stealth:
  # .rigpath exists pointing at an external directory.
  local rig_ext="$TEMP_DIR/rig-external"
  mkdir -p "$rig_ext"
  echo "$rig_ext" > "$TEST_PROJECT/.rigpath"

  # Call installer directly without --tracking so .rigpath auto-detection fires.
  # run_installer() prepends --tracking repo which would override auto-detect.
  run bash "$INSTALLER" --project-only \
    --target "$TEST_PROJECT" \
    --project-name "TestProject" \
    --strategy skip
  [ "$status" -eq 0 ]
  # .rig/ files must land in external dir, not project dir
  [ -f "$rig_ext/memory/PROGRESS.md" ]
  [ ! -f "$TEST_PROJECT/.rig/memory/PROGRESS.md" ]
}

@test "stealth install adds .rig/ to .git/info/exclude" {
  local rig_ext="$TEMP_DIR/rig-external"
  run_installer --strategy skip --tracking stealth --rig-dir "$rig_ext"
  [ "$status" -eq 0 ]
  grep -qF ".rig/" "$TEST_PROJECT/.git/info/exclude"
}

@test "stealth migration: warns about stale in-repo .rig/ and auto-removes in non-interactive mode" {
  # Start with a repo-tracked install so .rig/ exists in the project directory.
  run_installer --strategy skip --tracking repo
  [ "$status" -eq 0 ]
  [ -d "$TEST_PROJECT/.rig" ]

  # Re-install in stealth mode. confirm() is non-interactive (non-TTY in bats),
  # so it uses the default "y" and auto-removes .rig/ without reading stdin.
  local rig_ext="$TEMP_DIR/rig-stealth-migration"
  run bash "$INSTALLER" --project-only \
    --target "$TEST_PROJECT" \
    --project-name "TestProject" \
    --tracking stealth \
    --rig-dir "$rig_ext" \
    --strategy merge
  [ "$status" -eq 0 ]
  # Warning must mention the stale .rig/
  [[ "$output" == *"In-repo .rig/ found"* ]] || [[ "$output" == *"superseded"* ]] || return 1
  # Non-interactive default is "y" — .rig/ is auto-removed
  [ ! -d "$TEST_PROJECT/.rig" ]
}

@test "stealth migration under agent-upgrade leaves stale in-repo .rig for manual cleanup" {
  # Start with a repo-tracked install so .rig/ exists in the project directory.
  run_installer --strategy merge --tracking repo
  [ "$status" -eq 0 ]
  [ -d "$TEST_PROJECT/.rig" ]

  local rig_ext="$TEMP_DIR/rig-stealth-agent-upgrade"
  run bash "$INSTALLER" --project-only \
    --target "$TEST_PROJECT" \
    --project-name "TestProject" \
    --tracking stealth \
    --rig-dir "$rig_ext" \
    --strategy agent-upgrade
  [ "$status" -eq 0 ]
  [ -d "$TEST_PROJECT/.rig" ]
  [ -f "$rig_ext/memory/.rig-manifest" ]
  run python3 -c "
import json, pathlib, sys
d = json.loads(sys.stdin.read())
report = pathlib.Path(d['report_path'])
assert d['rollback_id'], d
assert report.is_file(), report
assert report.parent == pathlib.Path(sys.argv[1]) / 'upgrade-reports', report
print('ok')
" "$rig_ext" <<< "$output"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "upgrade auto-detects repo mode when .rig/ is git-committed" {
  # Simulate a project previously installed in repo mode: .rig/ files committed.
  run_installer --strategy skip --tracking repo
  git -C "$TEST_PROJECT" add "$TEST_PROJECT/.rig/VERSION"
  git -C "$TEST_PROJECT" commit -m "chore: initial rig install" --allow-empty-message 2>/dev/null || true

  # Run upgrade directly (not via run_installer) so auto-detect fires.
  run bash "$INSTALLER" --project-only \
    --target "$TEST_PROJECT" \
    --project-name "TestProject" \
    --strategy upgrade
  [ "$status" -eq 0 ]
  # Must stay in repo mode: no .rigpath, .rig/VERSION still in project dir
  [ ! -f "$TEST_PROJECT/.rigpath" ]
  [ -f "$TEST_PROJECT/.rig/VERSION" ]
  [[ "$output" == *"Auto-detected existing tracking mode: repo"* ]] || return 1
}

@test "upgrade auto-detects local mode when .rig/ is in .git/info/exclude" {
  # Simulate a project previously installed in local mode.
  run_installer --strategy skip --tracking local
  # Confirm .rig/ is in .git/info/exclude (installed by --tracking local)
  grep -qF ".rig/" "$TEST_PROJECT/.git/info/exclude"

  # Run upgrade directly so auto-detect fires.
  run bash "$INSTALLER" --project-only \
    --target "$TEST_PROJECT" \
    --project-name "TestProject" \
    --strategy upgrade
  [ "$status" -eq 0 ]
  # Must stay in local mode: no .rigpath, .rig/ still in project dir
  [ ! -f "$TEST_PROJECT/.rigpath" ]
  [ -f "$TEST_PROJECT/.rig/VERSION" ]
  [[ "$output" == *"Auto-detected existing tracking mode: local"* ]] || return 1
}

@test "upgrade auto-detects local mode when .rig/ is in .gitignore" {
  # Simulate a project where .rig/ was manually added to .gitignore (not via installer).
  run_installer --strategy skip --tracking repo
  echo ".rig/" >> "$TEST_PROJECT/.gitignore"

  # .rig/ files are NOT in the git index (run_installer --tracking repo commits nothing).
  run bash "$INSTALLER" --project-only \
    --target "$TEST_PROJECT" \
    --project-name "TestProject" \
    --strategy upgrade
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_PROJECT/.rigpath" ]
  [[ "$output" == *"Auto-detected existing tracking mode: local"* ]] || return 1
}

@test "fresh install: .rig/VERSION matches installer VERSION" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]
  local installed; installed=$(cat "$TEST_PROJECT/.rig/VERSION")
  local expected; expected=$(cat "$BATS_TEST_DIRNAME/../VERSION")
  [ "$installed" = "$expected" ]
}

@test "upgrade: .rig/VERSION updated to installer VERSION even when template is stale" {
  # Simulate an installed project whose .rig/VERSION is behind the installer.
  run_installer --strategy skip
  [ "$status" -eq 0 ]
  echo "0.0.0" > "$TEST_PROJECT/.rig/VERSION"

  run_installer --strategy upgrade
  [ "$status" -eq 0 ]
  local installed; installed=$(cat "$TEST_PROJECT/.rig/VERSION")
  local expected; expected=$(cat "$BATS_TEST_DIRNAME/../VERSION")
  [ "$installed" = "$expected" ]
}

# ── Gap 4: stop.sh (SessionEnd) writes .wrap-needed on 2+ commits ────────────
# SessionEnd logic (logout/prompt_input_exit/clear) is now in stop.sh, which
# handles both Stop (per-turn) and SessionEnd (true termination) events.

@test "stop.sh (SessionEnd): writes .wrap-needed when session log has 2+ commits" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]

  local rig_dir="$TEST_PROJECT/.rig"
  local stop_hook="$TEST_PROJECT/.claude/hooks/stop.sh"
  local session_log="$TEMP_DIR/test-session.log"
  local wrap_needed="$rig_dir/memory/.wrap-needed"

  # Provide a snapshot so the "no snapshot" trigger doesn't fire first,
  # and ensure PROGRESS.md has no stubs (skip install creates none).
  # Together these isolate to the 2+ commits path.
  printf '**Last updated:** 2026-01-01 — test snapshot\n' \
    > "$rig_dir/memory/CONTEXT_SNAPSHOT.md"

  # Simulate two commits having been logged this session
  printf '[10:00:00] PROGRESS stub: abc1234 feat(x): first commit [#1]\n' >> "$session_log"
  printf '[10:01:00] PROGRESS stub: def5678 feat(x): second commit [#1]\n' >> "$session_log"

  rm -f "$wrap_needed"

  # Run stop.sh with source=logout (SessionEnd payload); cd into project so git rev-parse resolves
  echo '{"source": "logout"}' \
    | ( cd "$TEST_PROJECT" && RIG_SESSION_LOG="$session_log" bash "$stop_hook" )

  [ -f "$wrap_needed" ]
}

@test "stop.sh (SessionEnd): does not write .wrap-needed when session has fewer than 2 commits" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]

  local rig_dir="$TEST_PROJECT/.rig"
  local stop_hook="$TEST_PROJECT/.claude/hooks/stop.sh"
  local session_log="$TEMP_DIR/test-session.log"
  local wrap_needed="$rig_dir/memory/.wrap-needed"

  # Same isolation: snapshot present, no stubs, only 1 commit in session log
  printf '**Last updated:** 2026-01-01 — test snapshot\n' \
    > "$rig_dir/memory/CONTEXT_SNAPSHOT.md"

  printf '[10:00:00] PROGRESS stub: abc1234 feat(x): first commit [#1]\n' >> "$session_log"

  rm -f "$wrap_needed"

  echo '{"source": "logout"}' \
    | ( cd "$TEST_PROJECT" && RIG_SESSION_LOG="$session_log" bash "$stop_hook" )

  [ ! -f "$wrap_needed" ]
}

# ── Session log path is per-project ──────────────────────────────────────────
# stop.sh must write to /tmp/the-rig-session-<project>.log, not a global path.
# This prevents cross-project commit count contamination.

@test "session log path: stop.sh uses per-project log filename" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]

  local stop_hook="$TEST_PROJECT/.claude/hooks/stop.sh"

  # Must reference the per-project pattern, not the global path
  run grep "the-rig-session\.log" "$stop_hook"
  [ "$status" -ne 0 ]  # global path must NOT appear

  run grep 'the-rig-session-.*\.log\|the-rig-session-\$(basename' "$stop_hook"
  [ "$status" -eq 0 ]  # per-project pattern must appear
}

@test "stop.sh (SessionEnd): commit count not inflated by stubs from a different project" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]

  local rig_dir="$TEST_PROJECT/.rig"
  local stop_hook="$TEST_PROJECT/.claude/hooks/stop.sh"
  local wrap_needed="$rig_dir/memory/.wrap-needed"

  printf '**Last updated:** 2026-01-01 — test snapshot\n' \
    > "$rig_dir/memory/CONTEXT_SNAPSHOT.md"

  # Simulate a different project's log with 2 commits written to a separate path
  local other_project_log="$TEMP_DIR/the-rig-session-other-project.log"
  printf '[10:00:00] PROGRESS stub: abc1234 feat(x): first commit [#1]\n' >> "$other_project_log"
  printf '[10:01:00] PROGRESS stub: def5678 feat(x): second commit [#1]\n' >> "$other_project_log"

  # This project's log is empty — injected via RIG_SESSION_LOG pointing to
  # a per-project path with zero stubs
  local this_project_log="$TEMP_DIR/the-rig-session-test-project.log"

  rm -f "$wrap_needed"

  echo '{"source": "logout"}' \
    | ( cd "$TEST_PROJECT" && RIG_SESSION_LOG="$this_project_log" bash "$stop_hook" )

  # .wrap-needed must NOT be set — the other project's stubs must not be visible
  [ ! -f "$wrap_needed" ]
}

@test "upgrade: retires an unchanged manifest-tracked session-end hook" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]

  # Simulate an old install that has session-end.sh present
  local legacy="$TEST_PROJECT/.claude/hooks/session-end.sh"
  printf '# legacy Rig hook\n' > "$legacy"
  printf '%s  .claude/hooks/session-end.sh\n' "$(_sha256 "$legacy")" \
    >> "$TEST_PROJECT/.rig/memory/.rig-manifest"

  run_installer --strategy upgrade
  [ "$status" -eq 0 ]

  [ ! -e "$legacy" ]
  [[ "$output" == *"Removed obsolete legacy hook: .claude/hooks/session-end.sh"* ]] || return 1
  [[ "$output" == *"Removed obsolete: 1"* ]] || return 1
  [ "$(find "$TEST_PROJECT/.rig-backup" -name session-end.sh -type f | wc -l | tr -d ' ')" -ge 1 ]
}

@test "upgrade: preserves a customized session-end hook and reports conflict" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]

  local legacy="$TEST_PROJECT/.claude/hooks/session-end.sh"
  printf '# legacy Rig hook\n' > "$legacy"
  printf '%s  .claude/hooks/session-end.sh\n' "$(_sha256 "$legacy")" \
    >> "$TEST_PROJECT/.rig/memory/.rig-manifest"
  printf '# user customization\n' >> "$legacy"

  run_installer --strategy upgrade
  [ "$status" -eq 0 ]
  [ -f "$legacy" ]
  grep -q '# user customization' "$legacy"
  [[ "$output" == *"Skipped conflicts: 1"* ]] || return 1
  [[ "$output" == *"Conflicting legacy artifacts requiring explicit repair:"* ]] || return 1
  [[ "$output" == *"RIG_UPGRADE_REVIEW_REQUIRED=1"* ]] || return 1
}

@test "upgrade: preserves a symlinked session-end hook without touching its target" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]

  local legacy="$TEST_PROJECT/.claude/hooks/session-end.sh"
  local outside="$TEMP_DIR/outside-session-end.sh"
  printf '# outside sentinel\n' > "$outside"
  ln -s "$outside" "$legacy"

  run_installer --strategy upgrade
  [ "$status" -eq 0 ]
  [ -L "$legacy" ]
  grep -q '# outside sentinel' "$outside"
  [[ "$output" == *"Skipped conflicts: 1"* ]] || return 1
  [[ "$output" == *"Preserved legacy hook symlink"* ]] || return 1
}

@test "upgrade: preserves a dangling session-end hook" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]

  local legacy="$TEST_PROJECT/.claude/hooks/session-end.sh"
  ln -s "$TEMP_DIR/missing-session-end.sh" "$legacy"

  run_installer --strategy upgrade
  [ "$status" -eq 0 ]
  [ -L "$legacy" ]
  [[ "$output" == *"Skipped conflicts: 1"* ]] || return 1
}

@test "upgrade: preserves an untracked session-end hook" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]

  local legacy="$TEST_PROJECT/.claude/hooks/session-end.sh"
  printf '# legacy untracked hook\n' > "$legacy"

  run_installer --strategy upgrade
  [ "$status" -eq 0 ]
  [ -f "$legacy" ]
  [[ "$output" == *"Skipped conflicts: 1"* ]] || return 1
}

@test "upgrade: preserves a wrong-type session-end path" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]

  local legacy="$TEST_PROJECT/.claude/hooks/session-end.sh"
  mkdir "$legacy"

  run_installer --strategy upgrade
  [ "$status" -eq 0 ]
  [ -d "$legacy" ]
  [[ "$output" == *"Skipped conflicts: 1"* ]] || return 1
  [[ "$output" == *"unsupported file type"* ]] || return 1
}

@test "upgrade: settings.json SessionEnd hook updated from session-end.sh to stop.sh" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]

  local settings="$TEST_PROJECT/.claude/settings.json"

  # Manually insert a stale SessionEnd → session-end.sh entry
  python3 -c "
import json
with open('$settings') as f:
    d = json.load(f)
d.setdefault('hooks', {})['SessionEnd'] = [
    {'hooks': [{'type': 'command', 'command': 'bash /repo/.claude/hooks/session-end.sh'}]}
]
with open('$settings', 'w') as f:
    json.dump(d, f, indent=2)
"

  run_installer --strategy upgrade
  [ "$status" -eq 0 ]

  # session-end.sh entry must be gone
  run python3 -c "
import json, sys
with open('$settings') as f:
    d = json.load(f)
for entry in d.get('hooks', {}).get('SessionEnd', []):
    for h in entry.get('hooks', []):
        if 'session-end.sh' in h.get('command', ''):
            sys.exit(1)
"
  [ "$status" -eq 0 ]

  # stop.sh entry must be present
  run python3 -c "
import json, sys
with open('$settings') as f:
    d = json.load(f)
for entry in d.get('hooks', {}).get('SessionEnd', []):
    for h in entry.get('hooks', []):
        if 'stop.sh' in h.get('command', ''):
            sys.exit(0)
sys.exit(1)
"
  [ "$status" -eq 0 ]
}

# ── commit-msg: # no-issue trailer ───────────────────────────────────────────

@test "fresh install keeps install completion distinct and omits upgrade summary" {
  local fake_home="$TEMP_DIR/fake-home"
  mkdir -p "$fake_home"

  run bash -c "echo '' | HOME='$fake_home' bash '$INSTALLER' --global-only --strategy skip"
  [ "$status" -eq 0 ]
  [[ "$output" == *"The Rig is installed. Next steps:"* ]] || return 1
  [[ "$output" != *"── Upgrade summary ──"* ]] || return 1
  [[ "$output" != *"RIG_UPGRADE_REVIEW_REQUIRED="* ]] || return 1
}

@test "upgrade summary counts an untracked user-owned file separately" {
  run_installer --strategy overwrite
  [ "$status" -eq 0 ]
  printf 'MY UNTRACKED PROJECT CONTEXT\n' > "$TEST_PROJECT/CLAUDE.md"
  grep -v '  CLAUDE.md$' "$TEST_PROJECT/.rig/memory/.rig-manifest" > "$TEMP_DIR/manifest"
  mv "$TEMP_DIR/manifest" "$TEST_PROJECT/.rig/memory/.rig-manifest"

  run_installer --strategy upgrade
  [ "$status" -eq 0 ]
  [[ "$output" == *"Skipped untracked user-owned: 1"* ]] || return 1
  grep -q 'MY UNTRACKED PROJECT CONTEXT' "$TEST_PROJECT/CLAUDE.md"
}

@test "upgrade summary reports resolved targets smoke checks and no-review signal" {
  local fake_home="$TEMP_DIR/fake-home"
  mkdir -p "$fake_home"
  run bash -c "echo '' | HOME='$fake_home' bash '$INSTALLER' --global-only --strategy skip"
  [ "$status" -eq 0 ]

  run bash -c "echo '' | HOME='$fake_home' bash '$INSTALLER' --global-only --strategy upgrade"
  [ "$status" -eq 0 ]
  [[ "$output" == *"── Upgrade summary ──"* ]] || return 1
  [[ "$output" == *"Skipped customized: 0"* ]] || return 1
  [[ "$output" == *"Selected agents: global=claude project=claude"* ]] || return 1
  [[ "$output" == *"Missing prerequisites: none"* ]] || return 1
  [[ "$output" == *"Degraded/skipped capabilities:"* ]] || return 1
  [[ "$output" == *"Exact next steps:"* ]] || return 1
  [[ "$output" == *"Global smoke tests (expected signal: passed):"* ]] || return 1
  [[ "$output" == *"The Rig upgrade is complete. Next steps:"* ]] || return 1
  [[ "${lines[$((${#lines[@]} - 1))]}" == "RIG_UPGRADE_REVIEW_REQUIRED=0" ]] || return 1
}

@test "upgrade summary lists customized skips and sets manual-review signal" {
  local fake_home="$TEMP_DIR/fake-home"
  mkdir -p "$fake_home"
  run bash -c "echo '' | HOME='$fake_home' bash '$INSTALLER' --global-only --strategy skip"
  [ "$status" -eq 0 ]
  printf '\n# retained customization\n' >> "$fake_home/.claude/skills/code-review.md"

  run bash -c "echo '' | HOME='$fake_home' bash '$INSTALLER' --global-only --strategy upgrade"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Skipped customized: 1"* ]] || return 1
  [[ "$output" == *"Customized files requiring manual review:"* ]] || return 1
  [[ "$output" == *"  - skills/code-review.md"* ]] || return 1
  grep -q '# retained customization' "$fake_home/.claude/skills/code-review.md"
  [[ "${lines[$((${#lines[@]} - 1))]}" == "RIG_UPGRADE_REVIEW_REQUIRED=1" ]] || return 1
}

@test "commit-msg: # no-issue trailer skips issue ref check for github tracker" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]

  local hook="$TEST_PROJECT/.husky/commit-msg"
  local msg_file="$TEMP_DIR/COMMIT_EDITMSG"

  printf 'issue-tracking: github\n' > "$TEST_PROJECT/CLAUDE.md"

  # Conventional commit but no issue ref — would normally fail
  # Body contains # no-issue → should pass
  printf 'chore(deps): bump library version\n\n# no-issue\n' > "$msg_file"
  run bash -c "cd '$TEST_PROJECT' && sh '$hook' '$msg_file'"
  [ "$status" -eq 0 ]
}

@test "commit-msg: # no-issue trailer skips issue ref check for linear tracker" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]

  local hook="$TEST_PROJECT/.husky/commit-msg"
  local msg_file="$TEMP_DIR/COMMIT_EDITMSG"

  printf 'issue-tracking: linear\n' > "$TEST_PROJECT/CLAUDE.md"

  printf 'chore(deps): bump library version\n\n# no-issue\n' > "$msg_file"
  run bash -c "cd '$TEST_PROJECT' && sh '$hook' '$msg_file'"
  [ "$status" -eq 0 ]
}

@test "commit-msg: without # no-issue, github tracker still requires ref" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]

  local hook="$TEST_PROJECT/.husky/commit-msg"
  local msg_file="$TEMP_DIR/COMMIT_EDITMSG"

  printf 'issue-tracking: github\n' > "$TEST_PROJECT/CLAUDE.md"

  # No # no-issue, no ref → must still fail
  printf 'chore(deps): bump library version\n\nSome body text.\n' > "$msg_file"
  run bash -c "cd '$TEST_PROJECT' && sh '$hook' '$msg_file'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"issue reference"* ]] || return 1
}

# ── permission-request.sh: RIG_DIR write auto-approval ───────────────────────

_perm_invoke() {
  # Run permission-request.sh with given tool_name and file_path.
  # Uses _RIG_TEST_RIG_DIR to inject rig_dir without being overwritten by the hook.
  local tool_name="$1" file_path="$2" rig_dir="$3"
  local input
  input=$(printf '{"tool_name":"%s","tool_input":{"file_path":"%s"}}' "$tool_name" "$file_path")
  printf '%s' "$input" | \
    _RIG_TEST_RIG_DIR="$rig_dir" \
    bash "$REPO_ROOT/templates/project/.claude/hooks/permission-request.sh" 2>/dev/null
}

_perm_bash_invoke() {
  local command="$1"
  python3 -c 'import json, sys; print(json.dumps({"tool_name": "Bash", "tool_input": {"command": sys.argv[1]}}))' "$command" | \
    bash "$REPO_ROOT/templates/project/.claude/hooks/permission-request.sh" 2>/dev/null
}

@test "permission-request: read-only assignment preamble and file inspection are auto-approved" {
  local command result
  command='REPO=$(git rev-parse --show-toplevel);
RIG_DIR="$REPO/.rig";
cat "$RIG_DIR/memory/PROGRESS.md"'
  result=$(_perm_bash_invoke "$command")
  [[ "$result" == *'"behavior": "allow"'* ]] || [[ "$result" == *'"behavior":"allow"'* ]] || return 1
}

@test "permission-request: every command in a read-only chain is validated" {
  local result
  result=$(_perm_bash_invoke 'git status; grep -n TODO README.md; wc -l README.md')
  [[ "$result" == *'"behavior": "allow"'* ]] || [[ "$result" == *'"behavior":"allow"'* ]] || return 1
}

@test "permission-request: unsafe suffix after safe prefix is not auto-approved" {
  local result
  result=$(_perm_bash_invoke 'git status; touch /tmp/x')
  [[ -z "$result" ]] || return 1
}

@test "permission-request: ambiguous shell syntax is not auto-approved" {
  local result
  result=$(_perm_bash_invoke 'git status && cat README.md')
  [[ -z "$result" ]] || return 1
}

@test "permission-request: mutating forms of read commands are not auto-approved" {
  local result
  result=$(_perm_bash_invoke 'find . -delete')
  [[ -z "$result" ]] || return 1

  result=$(_perm_bash_invoke 'git branch -D feature')
  [[ -z "$result" ]] || return 1

  result=$(_perm_bash_invoke 'git branch feature')
  [[ -z "$result" ]] || return 1
}

@test "permission-request: Edit to \$RIG_DIR is auto-approved" {
  local rig_dir
  rig_dir=$(mktemp -d)
  mkdir -p "$rig_dir/memory"
  local result
  result=$(_perm_invoke "Edit" "$rig_dir/memory/PROGRESS.md" "$rig_dir")
  [[ "$result" == *'"behavior": "allow"'* ]] || [[ "$result" == *'"behavior":"allow"'* ]] || return 1
}

@test "permission-request: Write to \$RIG_DIR is auto-approved" {
  local rig_dir
  rig_dir=$(mktemp -d)
  mkdir -p "$rig_dir/memory"
  local result
  result=$(_perm_invoke "Write" "$rig_dir/memory/CONTEXT_SNAPSHOT.md" "$rig_dir")
  [[ "$result" == *'"behavior": "allow"'* ]] || [[ "$result" == *'"behavior":"allow"'* ]] || return 1
}

@test "permission-request: Edit outside \$RIG_DIR is not auto-approved" {
  local rig_dir
  rig_dir=$(mktemp -d)
  mkdir -p "$rig_dir/memory"
  local result
  result=$(_perm_invoke "Edit" "/some/other/project/src/main.py" "$rig_dir")
  [[ -z "$result" ]] || return 1
}

@test "permission-request: .rig-strict-permissions sentinel disables RIG_DIR approval" {
  local rig_dir
  rig_dir=$(mktemp -d)
  mkdir -p "$rig_dir/memory"
  touch "$rig_dir/memory/.rig-strict-permissions"
  local result
  result=$(_perm_invoke "Edit" "$rig_dir/memory/PROGRESS.md" "$rig_dir")
  [[ -z "$result" ]] || return 1
}

@test "fresh install: settings.json includes /tmp/ Edit patterns only" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]
  grep -q '"Edit(/tmp/\*.md)"' "$TEST_PROJECT/.claude/settings.json"
  grep -q '"Edit(/tmp/\*.txt)"' "$TEST_PROJECT/.claude/settings.json"
  run grep -q '"Write(/tmp/\*\.\(md\|txt\))"' "$TEST_PROJECT/.claude/settings.json"
  [ "$status" -ne 0 ]
}

@test "merge: migrates only exact legacy /tmp Write permissions and is idempotent" {
  mkdir -p "$TEST_PROJECT/.claude"
  cat > "$TEST_PROJECT/.claude/settings.json" <<'EOF'
{
  "permissions": {
    "allow": [
      "Write(/tmp/*.md)",
      "Write(/tmp/*.txt)",
      "Write(/tmp/*.markdown)",
      "Write(/tmp/subdir/*.md)",
      "Write(/private/tmp/*.txt)",
      "Write(/tmp/*.MD)",
      "Edit(/tmp/*.md)",
      "Bash(custom command*)"
    ]
  }
}
EOF

  run_installer --strategy merge
  [ "$status" -eq 0 ]
  run_installer --strategy merge
  [ "$status" -eq 0 ]

  run python3 - "$TEST_PROJECT/.claude/settings.json" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    allow = json.load(f)["permissions"]["allow"]
assert allow.count("Edit(/tmp/*.md)") == 1
assert allow.count("Edit(/tmp/*.txt)") == 1
assert "Write(/tmp/*.md)" not in allow
assert "Write(/tmp/*.txt)" not in allow
for unchanged in (
    "Write(/tmp/*.markdown)",
    "Write(/tmp/subdir/*.md)",
    "Write(/private/tmp/*.txt)",
    "Write(/tmp/*.MD)",
    "Bash(custom command*)",
):
    assert unchanged in allow
PYEOF
  [ "$status" -eq 0 ]
}

@test "upgrade: migrates exact legacy /tmp Write permissions and preserves other settings" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]
  python3 - "$TEST_PROJECT/.claude/settings.json" <<'PYEOF'
import json, sys
path = sys.argv[1]
with open(path) as f:
    settings = json.load(f)
allow = settings["permissions"]["allow"]
allow.remove("Edit(/tmp/*.md)")
allow.remove("Edit(/tmp/*.txt)")
allow.extend(["Write(/tmp/*.md)", "Write(/tmp/*.txt)", "Write(src/*.md)"])
settings["permissions"]["deny"].append("Write(secrets/**)")
settings["userSetting"] = {"preserve": True}
with open(path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
PYEOF

  run_installer --strategy upgrade
  [ "$status" -eq 0 ]
  run python3 - "$TEST_PROJECT/.claude/settings.json" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    settings = json.load(f)
allow = settings["permissions"]["allow"]
assert "Write(/tmp/*.md)" not in allow
assert "Write(/tmp/*.txt)" not in allow
assert allow.count("Edit(/tmp/*.md)") == 1
assert allow.count("Edit(/tmp/*.txt)") == 1
assert "Write(src/*.md)" in allow
assert "Write(secrets/**)" in settings["permissions"]["deny"]
assert settings["userSetting"] == {"preserve": True}
PYEOF
  [ "$status" -eq 0 ]
}

@test "merge: malformed settings fail without overwriting the existing file" {
  mkdir -p "$TEST_PROJECT/.claude"
  printf '%s\n' '{ not valid json' > "$TEST_PROJECT/.claude/settings.json"

  run_installer --strategy merge
  [ "$status" -eq 0 ]
  [[ "$output" == *"Skipped settings.json (merge failed"* ]] || return 1
  [ "$(cat "$TEST_PROJECT/.claude/settings.json")" = "{ not valid json" ]
}
