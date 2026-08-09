#!/usr/bin/env bats
#
# tests/test_stale_manifest_layouts.bats — issue #444, lane 444-E
#
# Before this lane, report_stale_manifest_entries() only ran for repo/local
# tracking (install.sh gated the call on
# `[[ "$RIG_TRACKING" == repo || "$RIG_TRACKING" == local ]]`). External and
# stealth projects — whose manifest mixes $TARGET-rooted paths with
# ".rig/…"-rooted paths that actually live under the external .rig/ dir —
# got no stale-manifest audit at all
# (docs/FULL_SCOPE_REVIEW_SYNTHESIS_444.md finding F-005).
#
# It also only ever reported "gone" (os.path.lexists() false) as stale, so a
# tracked path that turned into a directory, a dangling symlink, or an
# unexpected symlink looked clean and was never surfaced for review.
#
# These tests prove: the audit now fires for stealth and external tracking
# using both roots correctly, --repair-stale removes genuinely missing
# entries, and wrong-type/symlink entries are always reported and never
# silently repaired.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
INSTALLER="$REPO_ROOT/install.sh"

setup() {
  TEMP_DIR="$(mktemp -d)"
  TEST_PROJECT="$TEMP_DIR/project"
  RIG_EXT="$TEMP_DIR/rig-external"
  mkdir -p "$TEST_PROJECT"
  git -C "$TEST_PROJECT" init -q
  git -C "$TEST_PROJECT" config user.email test@test.com
  git -C "$TEST_PROJECT" config user.name Test
}

teardown() { rm -rf "$TEMP_DIR"; }

# Inject a manifest entry (both the flat and JSON forms) for a path that will
# never be recreated by the ordinary template-copy step, so it stays stale
# long enough for the audit to see it. A real "renamed/removed Rig artifact"
# looks exactly like this: tracked, but no longer shipped in templates/.
inject_stale_entry() {
  local manifest_json="$1" rel="$2" owner="${3:-rig}" source="${4:-claude-native}"
  python3 -c "
import json
p = '$manifest_json'
d = json.load(open(p))
d['entries']['$rel'] = {
    'sha256': 'deadbeef', 'owner': '$owner', 'source': '$source',
    'type': 'file', 'mode': '644', 'installer_version': '0.0.1',
}
json.dump(d, open(p, 'w'), indent=2, sort_keys=True)
"
  printf 'deadbeef  %s\n' "$rel" >> "${manifest_json%.json}"
}

@test "stale-manifest audit fires for stealth tracking (both roots)" {
  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking stealth --rig-dir "$RIG_EXT" --strategy upgrade
  [ "$status" -eq 0 ]

  local manifest_json="$RIG_EXT/memory/.rig-manifest.json"
  # A $TARGET-rooted rel (ordinary project file) and a ".rig/"-rooted rel
  # (lives under $RIG_EXT with the ".rig/" prefix stripped) must both resolve.
  inject_stale_entry "$manifest_json" ".claude/commands/RETIRED_COMMAND.md"
  inject_stale_entry "$manifest_json" ".rig/rules/RETIRED_RULE.md" user shared-rig

  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking stealth --rig-dir "$RIG_EXT" --strategy upgrade
  [ "$status" -eq 0 ]
  [[ "$output" == *"Stale/missing tracked artifacts: 2"* ]] || return 1
  [[ "$output" == *"project:missing:.claude/commands/RETIRED_COMMAND.md"* ]] || return 1
  [[ "$output" == *"project:missing:.rig/rules/RETIRED_RULE.md"* ]] || return 1
}

@test "stale-manifest audit fires for external tracking (both roots)" {
  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking external --rig-dir "$RIG_EXT" --strategy upgrade
  [ "$status" -eq 0 ]

  local manifest_json="$RIG_EXT/memory/.rig-manifest.json"
  inject_stale_entry "$manifest_json" ".claude/commands/RETIRED_COMMAND.md"
  inject_stale_entry "$manifest_json" ".rig/rules/RETIRED_RULE.md" user shared-rig

  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking external --rig-dir "$RIG_EXT" --strategy upgrade
  [ "$status" -eq 0 ]
  [[ "$output" == *"Stale/missing tracked artifacts: 2"* ]] || return 1
}

@test "--repair-stale removes a genuinely missing stealth manifest entry" {
  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking stealth --rig-dir "$RIG_EXT" --strategy upgrade
  [ "$status" -eq 0 ]

  local manifest_json="$RIG_EXT/memory/.rig-manifest.json"
  inject_stale_entry "$manifest_json" ".rig/rules/RETIRED_RULE.md" user shared-rig

  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking stealth --rig-dir "$RIG_EXT" --repair-stale
  [ "$status" -eq 0 ]
  [[ "$output" == *"Repaired stale manifest entry: project:.rig/rules/RETIRED_RULE.md"* ]] || return 1
  if grep -qF '.rig/rules/RETIRED_RULE.md' "$RIG_EXT/memory/.rig-manifest"; then return 1; fi
  run python3 -c "
import json
d = json.load(open('$manifest_json'))
raise SystemExit(1 if '.rig/rules/RETIRED_RULE.md' in d['entries'] else 0)
"
  [ "$status" -eq 0 ]
}

@test "a tracked file replaced by a directory is reported as wrong-type, never silently changed" {
  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking repo --strategy upgrade
  [ "$status" -eq 0 ]

  rm -f "$TEST_PROJECT/.claude/commands/status.md"
  mkdir -p "$TEST_PROJECT/.claude/commands/status.md"

  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking repo --strategy upgrade
  [ "$status" -eq 0 ]
  [[ "$output" == *"wrong-type"*".claude/commands/status.md"* ]] || return 1
  [ -d "$TEST_PROJECT/.claude/commands/status.md" ]

  # --repair-stale must not touch it either — only "missing" is auto-repaired.
  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking repo --repair-stale
  [ "$status" -eq 0 ]
  [ -d "$TEST_PROJECT/.claude/commands/status.md" ]
  grep -qF '.claude/commands/status.md' "$TEST_PROJECT/.rig/memory/.rig-manifest"
}

@test "a tracked file replaced by a dangling symlink is reported, never silently removed" {
  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking repo --strategy upgrade
  [ "$status" -eq 0 ]

  rm -f "$TEST_PROJECT/.claude/commands/wrap.md"
  ln -s "/nonexistent-target-for-444-e" "$TEST_PROJECT/.claude/commands/wrap.md"

  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking repo --strategy upgrade
  [ "$status" -eq 0 ]
  [[ "$output" == *"dangling-symlink"*".claude/commands/wrap.md"* ]] || return 1
  [ -L "$TEST_PROJECT/.claude/commands/wrap.md" ]

  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking repo --repair-stale
  [ "$status" -eq 0 ]
  [ -L "$TEST_PROJECT/.claude/commands/wrap.md" ]
}
