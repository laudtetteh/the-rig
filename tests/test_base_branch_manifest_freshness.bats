#!/usr/bin/env bats
#
# tests/test_base_branch_manifest_freshness.bats — issue #498 (part 1)
#
# _subst_base_branch() runs near the end of the install flow, well after
# copy_file()/write_manifest_entry() already recorded each file's manifest
# hash from its pre-substitution content. Every file it touches (CLAUDE.md,
# .claude/commands/ship.md, .claude/commands/post-merge.md,
# .rig/processes/SHIP_WORKFLOW.md, .rig/processes/POST_MERGE_WORKFLOW.md)
# therefore had a stale manifest hash immediately after install -- not just
# on a later upgrade run, but on the very run that wrote it. Confirmed live
# under --strategy agent-upgrade: 4 of 5 updated files (every one actually
# containing [BASE_BRANCH]) kept their pre-substitution hash in both
# manifest files despite fresh on-disk content; the 5th (rig-upgrade.md)
# has no [BASE_BRANCH] placeholder at all, which is why it was the one file
# that happened to already work. This bug isn't agent-upgrade-specific --
# it reproduces on a plain first-time --strategy merge install too, since
# _subst_base_branch() always runs after the manifest-writing copy loop
# regardless of strategy.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
INSTALLER="$REPO_ROOT/install.sh"

setup() {
  TEMP_DIR="$(mktemp -d)"
  TEST_PROJECT="$TEMP_DIR/project"
  mkdir -p "$TEST_PROJECT"
  git -C "$TEST_PROJECT" init -q
  git -C "$TEST_PROJECT" config user.email test@test.com
  git -C "$TEST_PROJECT" config user.name Test
}

teardown() { rm -rf "$TEMP_DIR"; }

@test "every [BASE_BRANCH]-substituted file's manifest hash matches its actual on-disk content immediately after install" {
  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking repo --strategy merge
  [ "$status" -eq 0 ]

  local rel actual manifest
  for rel in CLAUDE.md .claude/commands/ship.md .claude/commands/post-merge.md \
             .rig/processes/SHIP_WORKFLOW.md .rig/processes/POST_MERGE_WORKFLOW.md; do
    [ -f "$TEST_PROJECT/$rel" ]
    # The file must actually have been substituted (sanity check the fixture
    # itself still contains a real [BASE_BRANCH] reference to substitute --
    # if this ever stops being true for a given rel, the test would pass
    # vacuously without proving anything).
    run grep -q '\[BASE_BRANCH\]' "$TEST_PROJECT/$rel"
    [ "$status" -ne 0 ]

    actual="$(sha256sum "$TEST_PROJECT/$rel" 2>/dev/null | awk '{print $1}' || shasum -a 256 "$TEST_PROJECT/$rel" | awk '{print $1}')"
    manifest="$(grep "  ${rel}$" "$TEST_PROJECT/.rig/memory/.rig-manifest" 2>/dev/null | awk '{print $1}')"
    [ -n "$manifest" ]
    [ "$actual" = "$manifest" ]

    run python3 -c "
import json, sys
with open('$TEST_PROJECT/.rig/memory/.rig-manifest.json') as f:
    d = json.load(f)
print(d['entries'].get('$rel', {}).get('sha256', ''))
"
    [ "$status" -eq 0 ]
    [ "$output" = "$actual" ]
  done
}
