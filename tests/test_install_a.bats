#!/usr/bin/env bats
#
# tests/test_install_a.bats — Integration tests for install.sh (shard a)
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
# Run with: bats tests/test_install_a.bats
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

# ── Overwrite strategy ────────────────────────────────────────────────────────

@test "overwrite strategy: creates files on fresh install" {
  run_installer --strategy overwrite
  [ "$status" -eq 0 ]
  [ -f "$TEST_PROJECT/.rig/processes/SHIP_WORKFLOW.md" ]
  [ -f "$TEST_PROJECT/.claude/hooks/pre-tool.sh" ]
}

@test "overwrite strategy: replaces existing files" {
  mkdir -p "$TEST_PROJECT/.claude/hooks"
  echo "STALE" > "$TEST_PROJECT/.claude/hooks/pre-tool.sh"

  run_installer --strategy overwrite
  [ "$status" -eq 0 ]

  # Should no longer contain the stale content
  run grep -q "STALE" "$TEST_PROJECT/.claude/hooks/pre-tool.sh"
  [ "$status" -ne 0 ]
}

@test "overwrite strategy: backs up replaced files to .rig-backup/" {
  mkdir -p "$TEST_PROJECT/.claude/hooks"
  echo "STALE" > "$TEST_PROJECT/.claude/hooks/pre-tool.sh"

  run_installer --strategy overwrite
  [ "$status" -eq 0 ]

  # A backup directory should exist
  [ -d "$TEST_PROJECT/.rig-backup" ]
  # The backup directory should contain the old hook
  local backup_count
  backup_count="$(find "$TEST_PROJECT/.rig-backup" -name "pre-tool.sh" | wc -l | tr -d ' ')"
  [ "$backup_count" -gt 0 ]
}

@test "overwrite strategy in stealth mode: backs up to external rig dir, not project" {
  local rig_ext="$TEMP_DIR/rig-external"
  mkdir -p "$TEST_PROJECT/.claude/hooks"
  echo "STALE" > "$TEST_PROJECT/.claude/hooks/pre-tool.sh"

  run_installer --strategy overwrite --tracking stealth --rig-dir "$rig_ext"
  [ "$status" -eq 0 ]

  # Backup must land in the external rig dir
  local backup_count
  backup_count="$(find "$rig_ext/backups" -name "pre-tool.sh" 2>/dev/null | wc -l | tr -d ' ')"
  [ "$backup_count" -gt 0 ]

  # No backup traces in the project repo
  [ ! -d "$TEST_PROJECT/.rig-backup" ]
}

# ── Upgrade strategy ──────────────────────────────────────────────────────────

@test "upgrade strategy: creates manifest on fresh install" {
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]
  [ -f "$TEST_PROJECT/.rig/memory/.rig-manifest" ]
}

@test "upgrade strategy: manifest contains Rig-owned file entries" {
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]

  # Manifest should have an entry for a known Rig-owned file
  grep -q ".claude/hooks/pre-tool.sh" "$TEST_PROJECT/.rig/memory/.rig-manifest"
}

@test "upgrade strategy: manifest tracks generated Codex hooks and skills" {
  run_installer --strategy upgrade --project-agent codex
  [ "$status" -eq 0 ]

  local manifest="$TEST_PROJECT/.rig/memory/.rig-manifest"
  grep -q '  .codex/hooks.json$' "$manifest"
  grep -q '  .codex/hooks/rig-adapter.sh$' "$manifest"
  grep -q '  .agents/skills/.*/SKILL.md$' "$manifest"
}

@test "upgrade strategy: writes versioned artifact metadata beside the legacy manifest" {
  run_installer --strategy upgrade --project-agent codex
  [ "$status" -eq 0 ]

  local metadata="$TEST_PROJECT/.rig/memory/.rig-manifest.json"
  [ -f "$metadata" ]
  jq -e '.schema_version == 1 and .entries[".codex/hooks.json"].owner == "rig" and .entries[".codex/hooks.json"].source == "codex-native" and .entries[".codex/hooks.json"].type == "file" and (.entries[".codex/hooks.json"].mode | type == "string")' "$metadata" >/dev/null
  jq -e '.entries[".claude/hooks/pre-tool.sh"].source == "claude-native" and .entries[".rig/VERSION"].source == "shared-rig" and .entries["CLAUDE.md"].owner == "user"' "$metadata" >/dev/null

  rm "$metadata"
  run_installer --strategy upgrade --project-agent codex
  [ "$status" -eq 0 ]
  [ -f "$metadata" ]
  jq -e '.schema_version == 1 and (.entries | length) > 0' "$metadata" >/dev/null
}

@test "upgrade strategy: manifest entries record base_revision, generator, and provider" {
  run_installer --strategy upgrade --project-agent codex
  [ "$status" -eq 0 ]

  local metadata="$TEST_PROJECT/.rig/memory/.rig-manifest.json"
  [ -f "$metadata" ]

  # generated-codex artifact: mirrored by installer/generate-codex-skills.py.
  jq -e '.entries[".agents/skills/debug/SKILL.md"].generator == "codex-mirror"
    and .entries[".agents/skills/debug/SKILL.md"].provider == "codex"
    and (.entries[".agents/skills/debug/SKILL.md"].base_revision | type == "string")' "$metadata" >/dev/null

  # hand-authored template, Claude-specific: unambiguous provider regardless
  # of the project agent selection that drove this run.
  jq -e '.entries[".claude/hooks/pre-tool.sh"].generator == "install.sh"
    and .entries[".claude/hooks/pre-tool.sh"].provider == "claude"' "$metadata" >/dev/null

  # hand-authored template, Codex-specific.
  jq -e '.entries[".codex/hooks.json"].generator == "install.sh"
    and .entries[".codex/hooks.json"].provider == "codex"' "$metadata" >/dev/null

  # shared/project-user artifact: takes on this run's active project agent
  # selection since the file itself is not provider-specific.
  jq -e '.entries["CLAUDE.md"].generator == "install.sh"
    and .entries["CLAUDE.md"].provider == "codex"' "$metadata" >/dev/null

  # base_revision mirrors installer_version (the only trustworthy per-file
  # revision signal available today).
  jq -e '.entries["CLAUDE.md"].base_revision == .entries["CLAUDE.md"].installer_version' "$metadata" >/dev/null
}

@test "manifest provenance validator: accepts a legacy manifest lacking provenance fields" {
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]

  local metadata="$TEST_PROJECT/.rig/memory/.rig-manifest.json"
  jq 'del(.entries["CLAUDE.md"].base_revision, .entries["CLAUDE.md"].generator, .entries["CLAUDE.md"].provider)' \
    "$metadata" > "$TEMP_DIR/legacy-metadata.json"
  mv "$TEMP_DIR/legacy-metadata.json" "$metadata"

  run python3 "$REPO_ROOT/installer/validate-manifest-provenance.py" "$metadata"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"ok":true'* ]]
  [[ "$output" == *'"legacy_provenance":["CLAUDE.md"]'* ]]
}

@test "manifest provenance validator: reports a deliberately malformed provenance entry" {
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]

  local metadata="$TEST_PROJECT/.rig/memory/.rig-manifest.json"
  jq '.entries["CLAUDE.md"].generator = "not-a-real-generator"' "$metadata" > "$TEMP_DIR/malformed-metadata.json"
  mv "$TEMP_DIR/malformed-metadata.json" "$metadata"

  run python3 "$REPO_ROOT/installer/validate-manifest-provenance.py" "$metadata"
  [ "$status" -eq 1 ]
  [[ "$output" == *'"ok":false'* ]]
  [[ "$output" == *'"path":"CLAUDE.md"'* ]]
  [[ "$output" == *"not-a-real-generator"* ]]
}

@test "manifest provenance validator: base_revision older than the running installer is unaffected" {
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]

  local metadata="$TEST_PROJECT/.rig/memory/.rig-manifest.json"
  jq '.entries["CLAUDE.md"].base_revision = "0.0.1"' "$metadata" > "$TEMP_DIR/older-metadata.json"
  mv "$TEMP_DIR/older-metadata.json" "$metadata"

  run python3 "$REPO_ROOT/installer/validate-manifest-provenance.py" "$metadata" --running-version "$(cat "$REPO_ROOT/VERSION")"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"ok":true'* ]]
  [[ "$output" == *'"future_revision":[]'* ]]
}

@test "manifest provenance validator: base_revision equal to the running installer is unaffected" {
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]

  local metadata="$TEST_PROJECT/.rig/memory/.rig-manifest.json"
  local running_version; running_version="$(cat "$REPO_ROOT/VERSION")"
  jq --arg v "$running_version" '.entries["CLAUDE.md"].base_revision = $v' "$metadata" > "$TEMP_DIR/equal-metadata.json"
  mv "$TEMP_DIR/equal-metadata.json" "$metadata"

  run python3 "$REPO_ROOT/installer/validate-manifest-provenance.py" "$metadata" --running-version "$running_version"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"ok":true'* ]]
  [[ "$output" == *'"future_revision":[]'* ]]
}

@test "manifest provenance validator: reports a base_revision newer than the running installer as future_revision" {
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]

  local metadata="$TEST_PROJECT/.rig/memory/.rig-manifest.json"
  jq '.entries["CLAUDE.md"].base_revision = "99.0.0"' "$metadata" > "$TEMP_DIR/future-metadata.json"
  mv "$TEMP_DIR/future-metadata.json" "$metadata"

  run python3 "$REPO_ROOT/installer/validate-manifest-provenance.py" "$metadata" --running-version "$(cat "$REPO_ROOT/VERSION")"
  [ "$status" -eq 1 ]
  [[ "$output" == *'"ok":false'* ]]
  [[ "$output" == *'"path":"CLAUDE.md"'* ]]
  [[ "$output" == *'"base_revision":"99.0.0"'* ]]
  # malformed/legacy stay empty — future_revision is its own distinct category.
  [[ "$output" == *'"malformed":[]'* ]]
}

@test "manifest provenance validator: omitting --running-version disables the future_revision check" {
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]

  local metadata="$TEST_PROJECT/.rig/memory/.rig-manifest.json"
  jq '.entries["CLAUDE.md"].base_revision = "99.0.0"' "$metadata" > "$TEMP_DIR/future-metadata.json"
  mv "$TEMP_DIR/future-metadata.json" "$metadata"

  run python3 "$REPO_ROOT/installer/validate-manifest-provenance.py" "$metadata"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"ok":true'* ]]
  [[ "$output" == *'"future_revision":[]'* ]]
}

@test "upgrade strategy: a pre-provenance manifest entry survives a real upgrade run" {
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]

  local metadata="$TEST_PROJECT/.rig/memory/.rig-manifest.json"
  # Simulate a manifest written before 444-B: strip the new fields from an
  # unmodified Rig-owned file's entry, same as an old installer would have
  # left it.
  jq 'del(.entries[".claude/hooks/pre-tool.sh"].base_revision,
          .entries[".claude/hooks/pre-tool.sh"].generator,
          .entries[".claude/hooks/pre-tool.sh"].provider)' \
    "$metadata" > "$TEMP_DIR/legacy-metadata.json"
  mv "$TEMP_DIR/legacy-metadata.json" "$metadata"

  # Reading it back must not crash the validator...
  run python3 "$REPO_ROOT/installer/validate-manifest-provenance.py" "$metadata"
  [ "$status" -eq 0 ]

  # ...nor a real upgrade run against the now-legacy entry. The file is
  # unmodified, so this hits the same-hash fast path that does not rewrite
  # the manifest entry — the point of this test is that this is safe, not
  # that it forces a migration.
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]
  [ -f "$TEST_PROJECT/.claude/hooks/pre-tool.sh" ]

  run python3 "$REPO_ROOT/installer/validate-manifest-provenance.py" "$metadata"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"ok":true'* ]]
}

@test "manifest provenance: real writer and real validator agree end-to-end (project layer)" {
  # Fresh install with a Codex project agent so the codex-mirror generator
  # path (installer/generate-codex-skills.py) is exercised for real, not
  # just the hand-authored install.sh copy path.
  run_installer --strategy skip --project-agent codex
  [ "$status" -eq 0 ]

  local manifest="$TEST_PROJECT/.rig/memory/.rig-manifest"
  local metadata="$TEST_PROJECT/.rig/memory/.rig-manifest.json"
  [ -f "$metadata" ]

  # Force a genuine upgrade-time rewrite of a Rig-owned file rather than
  # relying on the initial-install write alone: simulate a previously
  # installed older revision whose recorded manifest hash agrees with the
  # (stale) on-disk content but disagrees with the current template. This
  # is the real "hash matches manifest -> safe to overwrite" path, so
  # write_manifest_metadata() runs a second time, for real, mid-upgrade.
  printf '# simulated older revision\n' > "$TEST_PROJECT/.claude/hooks/pre-tool.sh"
  local old_hash
  old_hash=$(_sha256 "$TEST_PROJECT/.claude/hooks/pre-tool.sh")
  grep -v '  \.claude/hooks/pre-tool\.sh$' "$manifest" > "$TEMP_DIR/manifest-stripped"
  printf '%s  .claude/hooks/pre-tool.sh\n' "$old_hash" >> "$TEMP_DIR/manifest-stripped"
  mv "$TEMP_DIR/manifest-stripped" "$manifest"
  jq 'del(.entries[".claude/hooks/pre-tool.sh"])' "$metadata" > "$TEMP_DIR/metadata-stripped.json"
  mv "$TEMP_DIR/metadata-stripped.json" "$metadata"

  run_installer --strategy upgrade --project-agent codex
  [ "$status" -eq 0 ]
  [[ "$output" == *"Updated: .claude/hooks/pre-tool.sh"* ]]

  # The real writer must have re-recorded this entry with fresh, correct
  # provenance as part of that real upgrade-time rewrite.
  jq -e '.entries[".claude/hooks/pre-tool.sh"].generator == "install.sh"
    and .entries[".claude/hooks/pre-tool.sh"].provider == "claude"
    and .entries[".claude/hooks/pre-tool.sh"].base_revision == .entries[".claude/hooks/pre-tool.sh"].installer_version' "$metadata" >/dev/null

  # Run the REAL validator against the REAL manifest this run produced —
  # not a hand-built fixture standing in for it.
  run python3 "$REPO_ROOT/installer/validate-manifest-provenance.py" "$metadata"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"ok":true'* ]]
  [[ "$output" == *'"malformed":[]'* ]]

  # Spot-check the generated Codex artifact path agrees with the
  # validator's vocabulary too.
  jq -e '.entries[".agents/skills/debug/SKILL.md"].generator == "codex-mirror"
    and .entries[".agents/skills/debug/SKILL.md"].provider == "codex"' "$metadata" >/dev/null

  # And a shared/project-user artifact, which takes on the active project
  # agent selection rather than an unambiguous provider-specific one.
  jq -e '.entries["CLAUDE.md"].generator == "install.sh"
    and .entries["CLAUDE.md"].provider == "codex"' "$metadata" >/dev/null
}

@test "manifest provenance: real writer and real validator agree end-to-end (global layer)" {
  local fake_home="$TEMP_DIR/fake-home"
  mkdir -p "$fake_home"

  # Fresh global install with both agents so the global Codex-mirror
  # manifest (a separate file from the Claude global manifest) is
  # exercised for real too.
  run bash -c "echo '' | HOME='$fake_home' bash '$INSTALLER' --global-only --global-agent both --strategy skip"
  [ "$status" -eq 0 ]

  local claude_manifest="$fake_home/.claude/.rig-global-manifest"
  local claude_metadata="$claude_manifest.json"
  local codex_metadata="$fake_home/.agents/.rig-global-manifest.json"
  [ -f "$claude_metadata" ]
  [ -f "$codex_metadata" ]

  # Force a genuine upgrade-time rewrite of the global CLAUDE.md, same
  # technique as the project-layer test above: an on-disk/manifest hash
  # match that disagrees with the current template.
  printf '# simulated older revision\n' > "$fake_home/.claude/CLAUDE.md"
  local old_hash
  old_hash=$(_sha256 "$fake_home/.claude/CLAUDE.md")
  grep -v '  CLAUDE\.md$' "$claude_manifest" > "$TEMP_DIR/claude-manifest-stripped"
  printf '%s  CLAUDE.md\n' "$old_hash" >> "$TEMP_DIR/claude-manifest-stripped"
  mv "$TEMP_DIR/claude-manifest-stripped" "$claude_manifest"
  jq 'del(.entries["CLAUDE.md"])' "$claude_metadata" > "$TEMP_DIR/claude-metadata-stripped.json"
  mv "$TEMP_DIR/claude-metadata-stripped.json" "$claude_metadata"

  run bash -c "echo '' | HOME='$fake_home' bash '$INSTALLER' --global-only --global-agent both --strategy upgrade"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Updated: CLAUDE.md"* ]]

  # Real writer, real rewrite: fresh provenance recorded for real, mid-upgrade.
  # provider must be "claude", not the layer's --global-agent selection
  # ("both") — the global CLAUDE.md has no Codex-side equivalent anywhere
  # in install.sh (unlike the project-layer CLAUDE.md, which really is
  # Codex-shared via the .codex/config.toml fallback merge). This
  # previously asserted "both" as correct, codifying a real bug
  # (retro-audit finding, PR #448) where manifest_artifact_source()'s
  # generic project-user fallback let the layer's agent selection leak
  # into a provider-specific artifact's provenance.
  jq -e '.entries["CLAUDE.md"].generator == "install.sh"
    and .entries["CLAUDE.md"].provider == "claude"
    and .entries["CLAUDE.md"].base_revision == .entries["CLAUDE.md"].installer_version' "$claude_metadata" >/dev/null

  # Real validator against the real global Claude-layer manifest.
  run python3 "$REPO_ROOT/installer/validate-manifest-provenance.py" "$claude_metadata"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"ok":true'* ]]
  [[ "$output" == *'"malformed":[]'* ]]

  # Real validator against the real global Codex-mirror manifest — a
  # separate manifest file from the Claude one, produced by the same run.
  jq -e '[.entries[] | select(.generator == "codex-mirror" and .provider == "codex")] | length > 0' "$codex_metadata" >/dev/null
  run python3 "$REPO_ROOT/installer/validate-manifest-provenance.py" "$codex_metadata"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"ok":true'* ]]
  [[ "$output" == *'"malformed":[]'* ]]
}

@test "upgrade strategy: reports missing metadata artifacts without deleting anything" {
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]

  local metadata="$TEST_PROJECT/.rig/memory/.rig-manifest.json"
  local sentinel="$TEST_PROJECT/.rig/legacy-user-file.md"
  printf 'user data\n' > "$sentinel"
  jq '.entries[".rig/legacy-user-file.md"] = {"sha256":"deadbeef","owner":"user","source":"shared-rig","type":"file","mode":"644","installer_version":"legacy"}' "$metadata" > "$TEMP_DIR/metadata.json"
  mv "$TEMP_DIR/metadata.json" "$metadata"
  rm "$sentinel"

  run_installer --strategy upgrade
  [ "$status" -eq 0 ]
  [[ "$output" == *"Stale/missing tracked artifacts: 1"* ]]
  [[ "$output" == *"project:missing:.rig/legacy-user-file.md"* ]]
  [ ! -e "$sentinel" ]
}

@test "repair-stale removes only confirmed-missing manifest entries" {
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]

  local metadata="$TEST_PROJECT/.rig/memory/.rig-manifest.json"
  local manifest="$TEST_PROJECT/.rig/memory/.rig-manifest"
  jq '.entries[".rig/removed-by-user.md"] = {"sha256":"deadbeef","owner":"user","source":"shared-rig","type":"file","mode":"644","installer_version":"legacy"}' "$metadata" > "$TEMP_DIR/metadata.json"
  mv "$TEMP_DIR/metadata.json" "$metadata"
  printf 'deadbeef  .rig/removed-by-user.md\n' >> "$manifest"

  run_installer --repair-stale
  [ "$status" -eq 0 ]
  [[ "$output" == *"Repaired stale manifest entry: project:.rig/removed-by-user.md"* ]]
  ! jq -e '.entries[".rig/removed-by-user.md"]' "$metadata" >/dev/null
  ! grep -q '  .rig/removed-by-user.md$' "$manifest"
}

@test "upgrade strategy: preserves customized generated Codex artifacts" {
  run_installer --strategy upgrade --project-agent codex
  [ "$status" -eq 0 ]

  local hook="$TEST_PROJECT/.codex/hooks/rig-adapter.sh"
  local skill
  skill="$(find "$TEST_PROJECT/.agents/skills" -name SKILL.md -print -quit)"
  printf '\n# user hook customization\n' >> "$hook"
  printf '\n<!-- user skill customization -->\n' >> "$skill"

  run_installer --strategy upgrade --project-agent codex
  [ "$status" -eq 0 ]
  [[ "$output" == *"Non-interactive mode — skipping customized file: .codex/hooks/rig-adapter.sh"* ]]
  [[ "$output" == *"Non-interactive mode — skipping customized file: .agents/skills/"* ]]
  [[ "$output" == *"Skipped customized:"* ]]
  grep -q 'user hook customization' "$hook"
  grep -q 'user skill customization' "$skill"
}

@test "upgrade strategy: regenerates unmodified stale Codex artifacts" {
  run_installer --strategy upgrade --project-agent codex
  [ "$status" -eq 0 ]

  local manifest="$TEST_PROJECT/.rig/memory/.rig-manifest"
  local hook="$TEST_PROJECT/.codex/hooks/rig-adapter.sh"
  local hook_rel=".codex/hooks/rig-adapter.sh"
  local skill
  skill="$(find "$TEST_PROJECT/.agents/skills" -name SKILL.md -print -quit)"
  local skill_rel="${skill#$TEST_PROJECT/}"
  printf '# stale generated hook\n' > "$hook"
  printf '# stale generated skill\n' > "$skill"

  local hook_hash skill_hash
  hook_hash="$(_sha256 "$hook")"
  skill_hash="$(_sha256 "$skill")"
  awk -v hook_hash="$hook_hash" -v hook_rel="$hook_rel" \
      -v skill_hash="$skill_hash" -v skill_rel="$skill_rel" \
      '$2 == hook_rel { sub($1, hook_hash) } $2 == skill_rel { sub($1, skill_hash) } { print }' \
      "$manifest" > "$TEMP_DIR/updated-manifest"
  mv "$TEMP_DIR/updated-manifest" "$manifest"

  run_installer --strategy upgrade --project-agent codex
  [ "$status" -eq 0 ]
  [[ "$output" == *"Updated: $hook_rel"* ]]
  [[ "$output" == *"Updated: $skill_rel"* ]]
  ! grep -q 'stale generated hook' "$hook"
  ! grep -q 'stale generated skill' "$skill"
}

@test "upgrade strategy: does not follow a Codex artifact symlink" {
  run_installer --strategy upgrade --project-agent codex
  [ "$status" -eq 0 ]

  local hook="$TEST_PROJECT/.codex/hooks/rig-adapter.sh"
  local outside="$TEMP_DIR/outside-hook.sh"
  printf '# outside sentinel\n' > "$outside"
  chmod +x "$outside"
  rm "$hook"
  ln -s "$outside" "$hook"

  run_installer --strategy upgrade --project-agent codex
  [ "$status" -eq 0 ]
  [[ "$output" == *"Customized symlink detected: .codex/hooks/rig-adapter.sh"* ]]
  [[ "$output" == *"Skipped conflicts: 1"* ]]
  [[ -L "$hook" ]]
  grep -q 'outside sentinel' "$outside"
}

@test "upgrade strategy: preserves a wrong-type destination" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]

  local hook="$TEST_PROJECT/.claude/hooks/pre-tool.sh"
  rm "$hook"
  mkdir "$hook"

  run_installer --strategy upgrade
  [ "$status" -eq 0 ]
  [ -d "$hook" ]
  [[ "$output" == *"Preserved conflicting upgrade destination: .claude/hooks/pre-tool.sh (directory)"* ]]
  [[ "$output" == *"Skipped conflicts:"* ]]
}

@test "upgrade strategy: preserves a dangling artifact symlink" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]

  local command="$TEST_PROJECT/.claude/commands/status.md"
  rm "$command"
  ln -s "$TEMP_DIR/missing-command.md" "$command"

  run_installer --strategy upgrade
  [ "$status" -eq 0 ]
  [ -L "$command" ]
  [ ! -e "$command" ]
  [[ "$output" == *"Customized symlink detected: .claude/commands/status.md"* ]]
  [[ "$output" == *"Skipped conflicts:"* ]]
}

@test "upgrade strategy: does not follow a symlinked artifact parent" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]

  local hooks="$TEST_PROJECT/.claude/hooks"
  local outside_hooks="$TEMP_DIR/outside-hooks"
  local outside_hook="$outside_hooks/pre-tool.sh"
  mkdir "$outside_hooks"
  mv "$hooks"/* "$outside_hooks/"
  rmdir "$hooks"
  ln -s "$outside_hooks" "$hooks"
  chmod 644 "$outside_hook"
  local before_hash; before_hash="$(_sha256 "$outside_hook")"

  run_installer --strategy upgrade
  [ "$status" -eq 0 ]
  [ -L "$hooks" ]
  [ "$(_sha256 "$outside_hook")" = "$before_hash" ]
  python3 -c "import os, stat; assert stat.S_IMODE(os.stat('$outside_hook').st_mode) == 0o644"
  [[ "$output" == *"symlinked-parent"* ]]
  [[ "$output" == *"Skipped conflicts:"* ]]
}

@test "upgrade strategy: confines post-copy project mutations" {
  run_installer --strategy skip --project-agent both --subagents
  [ "$status" -eq 0 ]

  local version="$TEST_PROJECT/.rig/VERSION"
  local claude="$TEST_PROJECT/CLAUDE.md"
  local settings="$TEST_PROJECT/.claude/settings.json"
  local config="$TEST_PROJECT/.codex/config.toml"
  local outside_version="$TEMP_DIR/outside-version"
  local outside_claude="$TEMP_DIR/outside-claude"
  local outside_settings="$TEMP_DIR/outside-settings.json"
  local outside_config="$TEMP_DIR/outside-config.toml"
  printf 'outside-version\n' > "$outside_version"
  printf 'outside-claude\n' > "$outside_claude"
  printf '{}\n' > "$outside_settings"
  printf 'project_doc_fallback_filenames = []\n' > "$outside_config"
  rm "$version" "$claude" "$settings" "$config"
  ln -s "$outside_version" "$version"
  ln -s "$outside_claude" "$claude"
  ln -s "$outside_settings" "$settings"
  ln -s "$outside_config" "$config"

  run_installer --strategy upgrade --project-agent both --subagents
  [ "$status" -eq 0 ]
  [ -L "$version" ] && [ -L "$claude" ] && [ -L "$settings" ] && [ -L "$config" ]
  [ "$(cat "$outside_version")" = "outside-version" ]
  [ "$(cat "$outside_claude")" = "outside-claude" ]
  [ "$(cat "$outside_settings")" = '{}' ]
  [ "$(cat "$outside_config")" = 'project_doc_fallback_filenames = []' ]
  [[ "$output" == *"Skipped conflicts:"* ]]
  [[ "$output" == *".rig/VERSION"* ]]
  [[ "$output" == *".codex/config.toml"* ]]
}

@test "upgrade strategy: rewrites generated settings paths after project relocation" {
  run_installer --strategy skip --subagents
  [ "$status" -eq 0 ]

  local old_project="$TEST_PROJECT"
  local old_abs; old_abs="$(cd "$old_project" && pwd)"
  local moved_project="$TEMP_DIR/moved-project"
  mv "$old_project" "$moved_project"
  TEST_PROJECT="$moved_project"
  local new_abs; new_abs="$(cd "$TEST_PROJECT" && pwd)"
  grep -qF "$old_abs/.claude/hooks/" "$TEST_PROJECT/.claude/settings.json"

  run_installer --strategy upgrade --subagents
  [ "$status" -eq 0 ]
  grep -qF "$new_abs/.claude/hooks/" "$TEST_PROJECT/.claude/settings.json"
  ! grep -qF "$old_abs/.claude/hooks/" "$TEST_PROJECT/.claude/settings.json"
  [[ "$output" == *"Updated moved-project paths in .claude/settings.json"* ]]

  cp "$TEST_PROJECT/.claude/settings.json" "$TEMP_DIR/settings-after-move.json"
  run_installer --strategy upgrade --subagents
  [ "$status" -eq 0 ]
  cmp -s "$TEMP_DIR/settings-after-move.json" "$TEST_PROJECT/.claude/settings.json"
}

@test "upgrade strategy: preserves an external .rigpath symlink" {
  local rig_ext="$TEMP_DIR/external-rig"
  run_installer --strategy skip --tracking stealth --rig-dir "$rig_ext"
  [ "$status" -eq 0 ]

  local pointer="$TEST_PROJECT/.rigpath"
  local outside_pointer="$TEMP_DIR/outside-rigpath"
  printf '%s\n' "$rig_ext" > "$outside_pointer"
  rm "$pointer"
  ln -s "$outside_pointer" "$pointer"

  run_installer --strategy upgrade --tracking stealth --rig-dir "$rig_ext"
  [ "$status" -eq 0 ]
  [ -L "$pointer" ]
  [ "$(cat "$outside_pointer")" = "$rig_ext" ]
  [[ "$output" == *"Preserved conflicting upgrade destination: .rigpath (symlink)"* ]]
}

@test "agent-plan detects a symlinked .rigpath conflict instead of silently missing it (retro-audit finding, PR #460)" {
  # Same bug class issue #458 fixed for the stealth git-hook install loop:
  # the .rigpath conflict-detection call used to live entirely inside the
  # AGENT_DRY_RUN guard, so agent-plan never evaluated it at all -- a real
  # conflict here would surface for the first time as an agent-upgrade
  # refusal the plan never warned about.
  local rig_ext="$TEMP_DIR/external-rig"
  run_installer --strategy skip --tracking stealth --rig-dir "$rig_ext"
  [ "$status" -eq 0 ]

  local pointer="$TEST_PROJECT/.rigpath"
  local outside_pointer="$TEMP_DIR/outside-rigpath"
  printf '%s\n' "$rig_ext" > "$outside_pointer"
  rm "$pointer"
  ln -s "$outside_pointer" "$pointer"

  run_installer --strategy agent-plan --tracking stealth --rig-dir "$rig_ext"
  [ "$status" -eq 3 ]
  [[ "$output" == *'".rigpath"'* ]]
  # Zero writes: agent-plan must never mutate the symlink itself.
  [ -L "$pointer" ]
  [ "$(cat "$outside_pointer")" = "$rig_ext" ]
}

matrix_upgrade_case() {
  local tracking="$1" agent="$2" project rig_dir state_file settings_file
  project="$TEMP_DIR/matrix-${tracking}-${agent}"
  mkdir -p "$project"
  git -C "$project" init -q
  git -C "$project" config user.email "test@test.com"
  git -C "$project" config user.name "Test"
  rig_dir="$TEMP_DIR/rig-${tracking}-${agent}"
  local args=(--project-only --target "$project" --project-name MatrixProject
    --strategy upgrade --project-agent "$agent" --tracking "$tracking")
  if [[ "$tracking" == external || "$tracking" == stealth ]]; then
    args+=(--rig-dir "$rig_dir")
  fi

  bash "$INSTALLER" "${args[@]}" >/dev/null 2>&1
  printf '\n# preserved matrix customization\n' >> "$project/CLAUDE.md"
  if [[ "$tracking" == external || "$tracking" == stealth ]]; then
    state_file="$rig_dir/install-targets.json"
  else
    state_file="$project/.rig/install-targets.json"
  fi
  [ -f "$state_file" ]
  printf '0.1.0\n' > "$(dirname "$state_file")/VERSION"

  bash "$INSTALLER" "${args[@]}" >/dev/null 2>&1
  grep -q 'preserved matrix customization' "$project/CLAUDE.md"
  if [[ "$agent" == claude || "$agent" == both ]]; then
    settings_file="$project/.claude/settings.json"
  else
    settings_file="$project/.codex/hooks.json"
  fi
  [ -f "$settings_file" ]
}

@test "upgrade matrix: repo Claude direct jump preserves customization" {
  matrix_upgrade_case repo claude
}

@test "upgrade matrix: local Codex direct jump preserves customization" {
  matrix_upgrade_case local codex
}

@test "upgrade matrix: external dual-provider direct jump preserves customization" {
  matrix_upgrade_case external both
}

@test "upgrade matrix: stealth dual-provider direct jump preserves customization" {
  matrix_upgrade_case stealth both
}

@test "upgrade strategy: preserves a legacy Codex artifact with no manifest entry" {
  run_installer --strategy merge --project-agent codex
  [ "$status" -eq 0 ]

  local hook="$TEST_PROJECT/.codex/hooks/rig-adapter.sh"
  local manifest="$TEST_PROJECT/.rig/memory/.rig-manifest"
  printf '\n# legacy customization\n' >> "$hook"
  grep -v '  .codex/hooks/rig-adapter.sh$' "$manifest" > "$TEMP_DIR/manifest"
  mv "$TEMP_DIR/manifest" "$manifest"

  run_installer --strategy upgrade --project-agent codex
  [ "$status" -eq 0 ]
  [[ "$output" == *"Preserved untracked Codex artifact: .codex/hooks/rig-adapter.sh"* ]]
  grep -q 'legacy customization' "$hook"
  grep -q '  .codex/hooks/rig-adapter.sh$' "$manifest"
}

@test "upgrade strategy: auto-updates unmodified Rig-owned file on re-install" {
  # First install
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]

  # Tamper with a Rig-owned file to simulate a newer Rig version
  local hook="$TEST_PROJECT/.claude/hooks/pre-tool.sh"
  local original_content
  original_content="$(cat "$hook")"

  # Overwrite with different content simulating "old version"
  echo "# OLD VERSION" > "$hook"

  # The manifest still has the hash of the original (first install), so
  # the current file hash differs from manifest → treated as customized.
  # Re-run with upgrade — since hash ≠ manifest, it would prompt.
  # We can't fully test the prompt path non-interactively, but we CAN verify
  # that a file whose hash MATCHES the manifest is auto-updated silently.

  # Reset the file to match what the manifest recorded (simulates unmodified)
  echo "$original_content" > "$hook"

  # Second install with upgrade — should auto-update silently (status 0, no prompt)
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]
}

@test "upgrade strategy: never overwrites user-owned files" {
  # First install to set up everything
  run_installer --strategy overwrite
  [ "$status" -eq 0 ]

  # Write distinctive content to a user-owned file
  echo "MY CUSTOM RULES" > "$TEST_PROJECT/CLAUDE.md"

  # Upgrade run must not touch CLAUDE.md
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]

  grep -q "MY CUSTOM RULES" "$TEST_PROJECT/CLAUDE.md"
}

@test "upgrade strategy: never overwrites RIG_GAPS.md" {
  run_installer --strategy overwrite
  [ "$status" -eq 0 ]

  echo "## 2099-01-01 — My Custom Gap" > "$TEST_PROJECT/.rig/memory/RIG_GAPS.md"

  run_installer --strategy upgrade
  [ "$status" -eq 0 ]

  grep -q "My Custom Gap" "$TEST_PROJECT/.rig/memory/RIG_GAPS.md"
}

@test "upgrade strategy: manifest tracks user-owned files after install" {
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]

  # CLAUDE.md is user-owned but should now appear in the manifest
  [ -f "$TEST_PROJECT/.rig/memory/.rig-manifest" ]
  grep -q "CLAUDE.md" "$TEST_PROJECT/.rig/memory/.rig-manifest"
}

@test "upgrade strategy: preserves user-modified user-owned file (non-interactive)" {
  # Install to establish manifest baseline for user-owned files
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]

  # User modifies CLAUDE.md — hash now differs from manifest
  echo "MY BESPOKE PROJECT CONFIG" >> "$TEST_PROJECT/CLAUDE.md"

  # Upgrade non-interactive: customized user-owned file must be skipped
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]

  grep -q "MY BESPOKE PROJECT CONFIG" "$TEST_PROJECT/CLAUDE.md"
}

@test "upgrade strategy: warns when CLAUDE.md references unset opt-in components" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]
  printf '\n@.claude/commands/doc-feature.md\n@.claude/commands/rig-gaps.md\n@.claude/hooks/subagent-start.sh\n' >> "$TEST_PROJECT/CLAUDE.md"

  run_installer --strategy upgrade
  [ "$status" -eq 0 ]
  [[ "$output" == *"rerun with --feature-docs"* ]]
  [[ "$output" == *"rerun with --contribute"* ]]
  [[ "$output" == *"rerun with --subagents"* ]]
}

@test "upgrade strategy: does not warn when referenced opt-in components are enabled" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]
  printf '\n@.claude/commands/doc-feature.md\n@.claude/commands/rig-gaps.md\n@.claude/hooks/subagent-start.sh\n' >> "$TEST_PROJECT/CLAUDE.md"

  run_installer --strategy upgrade --feature-docs --contribute --subagents
  [ "$status" -eq 0 ]
  [[ "$output" != *"Upgrade will skip"* ]]
}

@test "overwrite strategy: skips user-modified user-owned file in non-interactive mode" {
  # First install establishes manifest
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]

  # User modifies CLAUDE.md
  echo "MY CUSTOM OVERWRITE CONTENT" >> "$TEST_PROJECT/CLAUDE.md"

  # Overwrite non-interactive: confirm() defaults to "n", so customized file is skipped
  run_installer --strategy overwrite
  [ "$status" -eq 0 ]

  grep -q "MY CUSTOM OVERWRITE CONTENT" "$TEST_PROJECT/CLAUDE.md"
}

# ── stop.sh (SessionEnd) skips write_minimal_checkpoint if snap lock held ────

@test "stop.sh (SessionEnd): skips write_minimal_checkpoint when snapshot write lock exists" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]

  local rig_dir="$TEST_PROJECT/.rig"
  local stop_hook="$TEST_PROJECT/.claude/hooks/stop.sh"
  local session_log="$TEMP_DIR/the-rig-session-test.log"
  local snap_lock="$rig_dir/memory/.snapshot-write-in-progress"

  # Write a recognisable snapshot so we can detect if it was overwritten
  printf '**Last updated:** 2026-01-01 — original snapshot\n' \
    > "$rig_dir/memory/CONTEXT_SNAPSHOT.md"

  # Simulate /wrap holding the lock
  touch "$snap_lock"

  echo '{"source": "logout"}' \
    | ( cd "$TEST_PROJECT" && RIG_SESSION_LOG="$session_log" bash "$stop_hook" )

  # Snapshot must be unchanged — write_minimal_checkpoint was skipped
  grep -q "original snapshot" "$rig_dir/memory/CONTEXT_SNAPSHOT.md"
}

@test "stop.sh (SessionEnd): write_minimal_checkpoint runs normally when no lock exists" {
  run_installer --strategy skip
  [ "$status" -eq 0 ]

  local rig_dir="$TEST_PROJECT/.rig"
  local stop_hook="$TEST_PROJECT/.claude/hooks/stop.sh"
  local session_log="$TEMP_DIR/the-rig-session-test.log"
  local snap_lock="$rig_dir/memory/.snapshot-write-in-progress"

  printf '**Last updated:** 2026-01-01 — original snapshot\n' \
    > "$rig_dir/memory/CONTEXT_SNAPSHOT.md"
  # Ensure unexpanded stubs exist so the write-needed path is triggered
  printf '[10:00:00] PROGRESS stub: abc1234 feat(x): commit [#1]\n' >> "$session_log"
  printf '[10:01:00] PROGRESS stub: def5678 feat(x): commit [#2]\n' >> "$session_log"

  rm -f "$snap_lock"

  echo '{"source": "logout"}' \
    | ( cd "$TEST_PROJECT" && RIG_SESSION_LOG="$session_log" bash "$stop_hook" )

  # Snapshot must have been replaced with the minimal checkpoint content
  grep -q "session-end checkpoint" "$rig_dir/memory/CONTEXT_SNAPSHOT.md"
}

# ── Command behavior: /ship commit sentinel ───────────────────────────────────
# /ship Step 7 creates .rig-commit-ok before running git commit.
# pre-tool.sh checks for this sentinel (tested in the sentinel section above).
# Here we test the sentinel creation path used by /ship.

_ship_create_commit_sentinel() {
  # Mirrors Step 7 sentinel creation in /ship.
  # Creates .rig-commit-ok in $rig_dir/memory/.
  local rig_dir="$1"
  touch "$rig_dir/memory/.rig-commit-ok"
}

@test "ship sentinel: .rig-commit-ok created at correct path" {
  local rig_dir="$TEMP_DIR/rig"
  mkdir -p "$rig_dir/memory"

  _ship_create_commit_sentinel "$rig_dir"
  [[ -f "$rig_dir/memory/.rig-commit-ok" ]]
}

@test "ship sentinel: .rig-commit-ok absent before /ship creates it" {
  local rig_dir="$TEMP_DIR/rig"
  mkdir -p "$rig_dir/memory"

  [[ ! -f "$rig_dir/memory/.rig-commit-ok" ]]
}

@test "ship sentinel: pre-tool sentinel check passes once sentinel is created by /ship" {
  local rig_dir="$TEMP_DIR/rig"
  mkdir -p "$rig_dir/memory"

  # Sentinel absent → commit gate blocks
  run _sentinel_check "Bash" "$rig_dir" "git commit -m 'test'"
  [ "$status" -ne 0 ]

  # /ship creates the sentinel
  _ship_create_commit_sentinel "$rig_dir"

  # Sentinel present → commit gate allows
  run _sentinel_check "Bash" "$rig_dir" "git commit -m 'test'"
  [ "$status" -eq 0 ]
}

# ── Hook behavior: worktree write redirect (#242) ─────────────────────────────
# pre-tool.sh intercepts Write/Edit targeting .claude/worktrees/ paths and
# rewrites file_path to the main repo equivalent via updatedToolInput.

_worktree_redirect_path() {
  # Mirrors the worktree redirect logic in pre-tool.sh.
  # Prints the redirected path, or nothing if not a worktree path.
  local path="$1"
  echo "$path" | python3 -c "
import re, sys
path = sys.stdin.read().strip()
m = re.match(r'^(.*)/\.claude/worktrees/[^/]+(/.*|$)', path)
if not m:
    sys.exit(0)
print(m.group(1) + (m.group(2) if m.group(2) else '/'))
" 2>/dev/null || true
}

@test "worktree redirect: path inside worktree is redirected to main repo" {
  local result
  result=$(_worktree_redirect_path "/repo/.claude/worktrees/my-task/src/app.py")
  [ "$result" = "/repo/src/app.py" ]
}

@test "worktree redirect: deeply nested worktree path is redirected correctly" {
  local result
  result=$(_worktree_redirect_path "/Users/dev/project/.claude/worktrees/feat-x/lib/utils/helper.sh")
  [ "$result" = "/Users/dev/project/lib/utils/helper.sh" ]
}

@test "worktree redirect: non-worktree path is not redirected" {
  local result
  result=$(_worktree_redirect_path "/repo/src/app.py")
  [ -z "$result" ]
}

@test "worktree redirect: path in .claude/hooks is not redirected (not a worktree)" {
  local result
  result=$(_worktree_redirect_path "/repo/.claude/hooks/pre-tool.sh")
  [ -z "$result" ]
}

