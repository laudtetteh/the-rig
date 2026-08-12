#!/usr/bin/env bats
#
# tests/test_upgrade_agent_contract.bats — Coverage for the agent-driven
# upgrade contract added under issue #444 (lane 444-A): --strategy agent-plan
# and --strategy agent-upgrade.
#
# Run with: bats tests/test_upgrade_agent_contract.bats
#
# Both strategies reuse the exact same discovery/classification code path as
# --strategy upgrade (see install.sh's AGENT_DRY_RUN gating). agent-plan must
# never write to the target; agent-upgrade applies the same safe/convergeable
# actions as upgrade. Both emit one JSON document on stdout and refuse
# (status "refused", exit 3) whenever any file needs manual review.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
INSTALLER="$REPO_ROOT/install.sh"

setup() {
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
  # Convenience wrapper mirroring tests/test_install.bats' run_installer:
  # always project-only, into TEST_PROJECT, with a fixed name and repo
  # tracking (keeps the fixture fully inside TEMP_DIR).
  run bash "$INSTALLER" --project-only \
    --target "$TEST_PROJECT" \
    --project-name "TestProject" \
    --tracking repo \
    "$@"
}

_sha256() {
  sha256sum "$1" 2>/dev/null | awk '{print $1}' || shasum -a 256 "$1" | awk '{print $1}'
}

# install.sh has a known, pre-existing, documented ordering issue (see this
# repo's own CLAUDE.md "Known gotchas": "`main` substitution runs after
# `write_manifest_entry`"): [BASE_BRANCH]/[Project Name] substitution runs
# AFTER the manifest hash is recorded for a file, so a handful of template
# files always show as "customized" after the very first install, even with
# zero real user edits. That is unrelated to the 444-A agent contract under
# test here. Stabilize the manifest for those known files to their actual
# post-substitution content so a test can construct a genuinely-unmodified
# fixture and isolate what this lane actually changed.
stabilize_substitution_baseline() {
  local manifest="$TEST_PROJECT/.rig/memory/.rig-manifest"
  local rel f
  for rel in CLAUDE.md .claude/commands/ship.md .claude/commands/post-merge.md \
             .rig/processes/POST_MERGE_WORKFLOW.md .rig/processes/SHIP_WORKFLOW.md; do
    f="$TEST_PROJECT/$rel"
    [[ -f "$f" ]] || continue
    grep -v "  ${rel}\$" "$manifest" > "$manifest.tmp"
    printf '%s  %s\n' "$(_sha256 "$f")" "$rel" >> "$manifest.tmp"
    mv "$manifest.tmp" "$manifest"
  done
}

# Content+path snapshot of the whole target tree. Used to prove agent-plan
# performs zero writes: two snapshots taken before/after a run must be
# byte-for-byte identical (same files, same content, same names).
tree_snapshot() {
  find "$TEST_PROJECT" -type f | sort | xargs cksum
}

# Extracts the final JSON line from bats' $output (the agent contract always
# emits exactly one JSON document as the last line of stdout).
last_json_line() {
  printf '%s\n' "$output" | tail -1
}

# json_field <python-expression>  — expression must reference `d`, e.g.
# "d['status']" or "len(d['artifacts'])". Evaluates against the JSON on the
# final line of $output.
json_field() {
  printf '%s\n' "$output" | tail -1 | python3 -c "
import json, sys
d = json.load(sys.stdin)
print($1)
"
}

@test "agent-plan on a fresh clean upgrade emits a valid success JSON plan with zero writes" {
  # Establish a real, unmodified install first (so the manifest baseline
  # matches every installed file exactly — the "fresh/clean" case).
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]
  stabilize_substitution_baseline

  local before after
  before="$(tree_snapshot)"

  run_installer --strategy agent-plan
  [ "$status" -eq 0 ]

  after="$(tree_snapshot)"
  [ "$before" = "$after" ]

  [[ "$(last_json_line)" == \{* ]] || return 1
  [ "$(json_field "d['schema_version']")" = "1" ]
  [ "$(json_field "d['mode']")" = "plan" ]
  [ "$(json_field "d['status']")" = "success" ]
  [ "$(json_field "d['conflicts']")" = "[]" ]
  [ "$(json_field "len(d['artifacts'])")" != "0" ]
}

@test "agent-plan stdout is exactly one JSON document, not preflight narration followed by JSON (retro-audit finding, PR #446)" {
  # The documented contract (UPGRADE_WORKFLOW.md, and this PR's own code
  # comment) is "prints exactly one JSON document on stdout." The preflight
  # narrative summary ("Target matrix: ...", "Missing prerequisites: ...",
  # etc.) was gated only on JSON_OUTPUT (true only for the separate,
  # explicit --preflight --json mode) -- never on AGENT_MODE -- so it
  # always printed several lines of human-oriented text before the real
  # result on every agent-plan/agent-upgrade run. A caller doing
  # json.loads(stdout) on the first (or only) line would break.
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]
  stabilize_substitution_baseline

  run_installer --strategy agent-plan
  [ "$status" -eq 0 ]

  local nonblank_lines
  nonblank_lines="$(printf '%s\n' "$output" | /usr/bin/grep -c .)"
  [ "$nonblank_lines" -eq 1 ]
  [[ "$output" != *"Target matrix:"* ]] || return 1
  [[ "$output" != *"Missing prerequisites:"* ]] || return 1
  [[ "$output" == \{* ]] || return 1
}

@test "agent-plan stdout stays exactly one JSON document when gitleaks is missing (retro-audit finding, PR #446 follow-up)" {
  # The previous test proved the render-preflight.py narrative summary no
  # longer leaks ahead of the JSON. It missed a second, unrelated leak in
  # the same file: the GITLEAKS CHECK block's remediation lines ("Install
  # it: ...", "Docs: ...") were plain echo, never routed through the
  # warn()/blank() AGENT_MODE-gating convention the rest of that block
  # already uses. This is invisible on any machine that happens to have
  # gitleaks installed (including wherever the previous test normally
  # runs), which is exactly how it shipped undetected and then broke CI,
  # where gitleaks isn't installed. _RIG_TEST_MISSING_COMMANDS forces the
  # check to behave as if gitleaks is absent regardless of the actual
  # host, so this test is portable and doesn't depend on the machine's
  # actual gitleaks state.
  run env _RIG_TEST_MISSING_COMMANDS=gitleaks bash "$INSTALLER" --project-only \
    --target "$TEST_PROJECT" --project-name "TestProject" --tracking repo \
    --strategy upgrade
  [ "$status" -eq 0 ]
  stabilize_substitution_baseline

  run env _RIG_TEST_MISSING_COMMANDS=gitleaks bash "$INSTALLER" --project-only \
    --target "$TEST_PROJECT" --project-name "TestProject" --tracking repo \
    --strategy agent-plan
  [ "$status" -eq 0 ]

  local nonblank_lines
  nonblank_lines="$(printf '%s\n' "$output" | /usr/bin/grep -c .)"
  [ "$nonblank_lines" -eq 1 ]
  [[ "$output" != *"Install it:"* ]] || return 1
  [[ "$output" != *"Docs: https://github.com/gitleaks"* ]] || return 1
  [[ "$output" == \{* ]] || return 1
}

@test "agent-plan on a target with a customized file emits refused with populated conflicts and exits 3" {
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]
  stabilize_substitution_baseline

  # Tamper with a Rig-owned file after the manifest baseline was recorded —
  # its hash now differs from the manifest, making it "customized".
  echo "# locally customized by the user" >> "$TEST_PROJECT/.claude/hooks/pre-tool.sh"

  local before after
  before="$(tree_snapshot)"

  run_installer --strategy agent-plan
  [ "$status" -eq 3 ]

  after="$(tree_snapshot)"
  [ "$before" = "$after" ]

  [ "$(json_field "d['status']")" = "refused" ]
  [ "$(json_field "len(d['conflicts'])")" != "0" ]
  [ "$(json_field "'.claude/hooks/pre-tool.sh' in [c['path'] for c in d['conflicts']]")" = "True" ]
  [ "$(json_field "bool(d['conflicts'][0]['repair_guidance'])")" = "True" ]

  # The customized file itself must be untouched.
  grep -q "locally customized by the user" "$TEST_PROJECT/.claude/hooks/pre-tool.sh"
}

@test "agent-plan never writes .codex/config.toml, even with --project-agent codex (retro-audit finding, PR #446)" {
  # Every other direct-writer mutation in install.sh (.rig/VERSION,
  # .rigpath, CLAUDE.md/settings.json substitution, the stealth git-hook
  # install loop) is wrapped in an AGENT_DRY_RUN guard. The Codex project-
  # config merge (merge-codex-config.py, invoked whenever --project-agent
  # is codex/both) had no such guard at all -- agent-plan actually mutated
  # .codex/config.toml on disk, violating the documented "zero writes,
  # read-only" contract this whole file exists to prove.
  #
  # The merge is idempotent once CLAUDE.md is already in
  # project_doc_fallback_filenames, so a fixture starting from that already-
  # merged state would mask the bug: the second write reuses identical
  # bytes and a plain content snapshot can't tell a real skipped write from
  # a same-content rewrite. A real prior --project-agent both install is
  # still required first, so every other Codex artifact (.codex/hooks.json,
  # .codex/hooks/rig-adapter.sh, .agents/skills) exists and agent-plan's own
  # postflight smoke check passes -- then the merged config.toml is reset
  # to an unmerged state (simulating a pre-existing Codex config Rig hasn't
  # touched yet) so a real (buggy) merge would visibly change its content.
  run_installer --strategy upgrade --project-agent both
  [ "$status" -eq 0 ]
  stabilize_substitution_baseline
  [ -f "$TEST_PROJECT/.codex/config.toml" ]

  printf 'model = "gpt-5"\n' > "$TEST_PROJECT/.codex/config.toml"

  local before after
  before="$(tree_snapshot)"

  run_installer --strategy agent-plan --project-agent both
  [ "$status" -eq 0 ]

  after="$(tree_snapshot)"
  [ "$before" = "$after" ]
  grep -q '^model = "gpt-5"$' "$TEST_PROJECT/.codex/config.toml"
  if grep -q 'project_doc_fallback_filenames' "$TEST_PROJECT/.codex/config.toml"; then return 1; fi
}

@test "agent-plan preserves Claude-only project metadata under a Codex runtime when selector is omitted" {
  # A release-pilot run from Codex should not implicitly retrofit Codex project
  # surfaces on a downstream project whose install-target metadata says Claude
  # only. Agent upgrade planning must classify the selected target, not the
  # coordinator's runtime.
  run_installer --strategy upgrade --project-agent claude
  [ "$status" -eq 0 ]
  stabilize_substitution_baseline
  [ ! -e "$TEST_PROJECT/.codex" ]
  /usr/bin/grep -q '"agents":\["claude"\]' "$TEST_PROJECT/.rig/install-targets.json"

  local before after
  before="$(tree_snapshot)"

  run env CODEX_THREAD_ID=codex-runtime bash "$INSTALLER" --project-only \
    --target "$TEST_PROJECT" \
    --project-name "TestProject" \
    --tracking repo \
    --strategy agent-plan
  [ "$status" -eq 0 ]

  after="$(tree_snapshot)"
  [ "$before" = "$after" ]
  [ "$(json_field "d['status']")" = "success" ]
  [ ! -e "$TEST_PROJECT/.codex" ]
  /usr/bin/grep -q '"agents":\["claude"\]' "$TEST_PROJECT/.rig/install-targets.json"
}

@test "agent-upgrade on a clean target applies updates and exits 0" {
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]
  stabilize_substitution_baseline

  # A missing tracked artifact is always safe to (re)create — the simplest
  # reliable way to force a real "updated" action in agent-upgrade.
  rm -f "$TEST_PROJECT/.claude/commands/status.md"

  run_installer --strategy agent-upgrade
  [ "$status" -eq 0 ]

  [ "$(json_field "d['status']")" = "success" ]
  [ "$(json_field "d['summary']['updated']")" != "0" ]
  [ -f "$TEST_PROJECT/.claude/commands/status.md" ]
}

@test "agent-upgrade on a target with a customized file applies safe updates but exits 3 refused and leaves it untouched" {
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]
  stabilize_substitution_baseline

  echo "# locally customized by the user" >> "$TEST_PROJECT/.claude/hooks/pre-tool.sh"
  rm -f "$TEST_PROJECT/.claude/commands/status.md"

  run_installer --strategy agent-upgrade
  [ "$status" -eq 3 ]

  [ "$(json_field "d['status']")" = "refused" ]
  [ "$(json_field "d['summary']['updated']")" != "0" ]
  [ "$(json_field "d['summary']['skipped_customized']")" != "0" ]

  # Safe/convergeable action was actually applied...
  [ -f "$TEST_PROJECT/.claude/commands/status.md" ]
  # ...but the customized file was never silently overwritten.
  grep -q "locally customized by the user" "$TEST_PROJECT/.claude/hooks/pre-tool.sh"
}

@test "agent-plan on a target with a future manifest base_revision emits refused, reports zero writes, and exits 3" {
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]
  stabilize_substitution_baseline

  # Simulate a bogus/corrupted or future-installer-written manifest entry:
  # a base_revision newer than the installer currently running (issue #463).
  # Deliberately NOT CLAUDE.md/ship.md/post-merge.md/SHIP_WORKFLOW.md/
  # POST_MERGE_WORKFLOW.md — those 5 are the known "main substitution runs
  # after write_manifest_entry" files (see this repo's own CLAUDE.md "Known
  # gotchas"); agent-upgrade legitimately re-writes them even after
  # stabilize_substitution_baseline, which would reset our tampered
  # base_revision back to a real value before this test could observe it.
  # .claude/hooks/pre-tool.sh is a plain, stable Rig-owned file with no such
  # quirk, so it stays untouched by agent-upgrade unless genuinely flagged.
  local metadata="$TEST_PROJECT/.rig/memory/.rig-manifest.json"
  jq '.entries[".claude/hooks/pre-tool.sh"].base_revision = "99.0.0"' "$metadata" > "$TEMP_DIR/future-metadata.json"
  mv "$TEMP_DIR/future-metadata.json" "$metadata"

  local before after
  before="$(tree_snapshot)"

  run_installer --strategy agent-plan
  [ "$status" -eq 3 ]

  after="$(tree_snapshot)"
  [ "$before" = "$after" ]

  [ "$(json_field "d['status']")" = "refused" ]
}

@test "agent-upgrade on a target with a future manifest base_revision refuses and exits 3, matching the fail-closed precedent" {
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]
  stabilize_substitution_baseline

  # See the agent-plan test above for why .claude/hooks/pre-tool.sh (not
  # CLAUDE.md) is used: it is not one of the 5 files affected by the
  # documented substitution-ordering quirk, so agent-upgrade's real write
  # path leaves its manifest entry (including our tampered base_revision)
  # untouched — this test needs the entry to survive an actual apply run.
  local metadata="$TEST_PROJECT/.rig/memory/.rig-manifest.json"
  jq '.entries[".claude/hooks/pre-tool.sh"].base_revision = "99.0.0"' "$metadata" > "$TEMP_DIR/future-metadata.json"
  mv "$TEMP_DIR/future-metadata.json" "$metadata"

  run_installer --strategy agent-upgrade
  [ "$status" -eq 3 ]
  [ "$(json_field "d['status']")" = "refused" ]
}

@test "agent-plan on an ordinary manifest (base_revision <= running installer) is unaffected by the future_revision check" {
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]
  stabilize_substitution_baseline

  run_installer --strategy agent-plan
  [ "$status" -eq 0 ]
  [ "$(json_field "d['status']")" = "success" ]
}

@test "existing --strategy upgrade behavior is unchanged by the agent contract" {
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]
  stabilize_substitution_baseline

  echo "# locally customized by the user" >> "$TEST_PROJECT/.claude/hooks/pre-tool.sh"
  rm -f "$TEST_PROJECT/.claude/commands/status.md"

  run_installer --strategy upgrade
  [ "$status" -eq 0 ]

  # Plain upgrade still exits 0 even when review is required (only the new
  # agent-* strategies gained exit code 3) and still prints the legacy
  # RIG_UPGRADE_REVIEW_REQUIRED marker instead of JSON.
  [[ "$output" == *"RIG_UPGRADE_REVIEW_REQUIRED=1"* ]] || return 1
  [[ "$output" != *'"schema_version"'* ]] || return 1
  [ -f "$TEST_PROJECT/.claude/commands/status.md" ]
  grep -q "locally customized by the user" "$TEST_PROJECT/.claude/hooks/pre-tool.sh"
}

@test "--help documents both new agent strategy values" {
  run bash "$INSTALLER" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"agent-plan"* ]] || return 1
  [[ "$output" == *"agent-upgrade"* ]] || return 1
}

@test "an unrecognized --strategy value still falls back to interactive, not agent mode" {
  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name "TestProject" --tracking repo --strategy bogus-value < /dev/null
  [[ "$output" != *'"schema_version"'* ]] || return 1
}

# ── Issue #475: CHANGELOG BREAKING-bullet stdout leak ─────────────────────────
#
# _show_breaking_changes() prints each CHANGELOG "BREAKING" bullet via a raw,
# unguarded `echo` inside a while-loop -- unlike every other narrative helper
# in this file (warn/info/blank), which self-gate on AGENT_MODE. It runs
# unconditionally whenever COLLISION_STRATEGY==upgrade, which both
# agent-plan and agent-upgrade set internally, so any run against a target
# whose installed version has a BREAKING changelog entry ahead of it leaked
# these bullet lines onto stdout ahead of the documented single JSON
# document. This repo's own CHANGELOG.md has a real BREAKING section under
# [1.18.0], so this was concretely reachable, not just theoretical.

write_breaking_changelog_fixture() {
  cat > "$TEMP_DIR/fixture-changelog.md" <<'EOF'
# Changelog

## [1.18.0]

### Changed — BREAKING

- Some breaking change bullet one
- Some breaking change bullet two

## [1.17.0]

### Added

- something
EOF
}

@test "agent-plan stdout stays exactly one JSON document when the target has a BREAKING changelog entry ahead of its installed version (issue #475)" {
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]
  stabilize_substitution_baseline
  write_breaking_changelog_fixture
  printf '1.17.0\n' > "$TEST_PROJECT/.rig/VERSION"

  run env _RIG_TEST_CHANGELOG="$TEMP_DIR/fixture-changelog.md" \
    bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name "TestProject" --tracking repo --strategy agent-plan

  local nonblank_lines
  nonblank_lines="$(printf '%s\n' "$output" | /usr/bin/grep -c .)"
  [ "$nonblank_lines" -eq 1 ]
  [[ "$output" != *"Some breaking change bullet"* ]] || return 1
  [[ "$output" == \{* ]] || return 1
  [ "$(json_field "d['schema_version']")" = "1" ]
}

@test "agent-upgrade stdout stays exactly one JSON document when the target has a BREAKING changelog entry ahead of its installed version (issue #475)" {
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]
  stabilize_substitution_baseline
  write_breaking_changelog_fixture
  printf '1.17.0\n' > "$TEST_PROJECT/.rig/VERSION"

  run env _RIG_TEST_CHANGELOG="$TEMP_DIR/fixture-changelog.md" \
    bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name "TestProject" --tracking repo --strategy agent-upgrade

  local nonblank_lines
  nonblank_lines="$(printf '%s\n' "$output" | /usr/bin/grep -c .)"
  [ "$nonblank_lines" -eq 1 ]
  [[ "$output" != *"Some breaking change bullet"* ]] || return 1
  [[ "$output" == \{* ]] || return 1
  [ "$(json_field "d['schema_version']")" = "1" ]
}
