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

@test "CLAUDE.md's manifest hash matches its on-disk content after the external/stealth @.rig/ import-path rewrite" {
  # A third CLAUDE.md mutation site, distinct from _subst_base_branch()'s own
  # touch: under external/stealth tracking only, install.sh separately
  # rewrites @.rig/ imports and context-loading paths to point at the
  # external $RIG_DIR, after _subst_base_branch() already ran and correctly
  # refreshed the manifest hash for ITS edit. This later rewrite has its own
  # write_manifest_entry() call now, same fix pattern as the rest of this
  # file -- found live via /rig-surface-review against the parent PR, not
  # caught by the sibling test above since that one only exercises
  # --tracking repo, which never reaches this external-only code path.
  local rig_dir="$TEMP_DIR/external-rig"
  mkdir -p "$rig_dir"

  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking external --rig-dir "$rig_dir" --strategy merge
  [ "$status" -eq 0 ]

  [ -f "$TEST_PROJECT/CLAUDE.md" ]
  run grep -q '@\.rig/' "$TEST_PROJECT/CLAUDE.md"
  [ "$status" -ne 0 ]

  local actual manifest
  actual="$(sha256sum "$TEST_PROJECT/CLAUDE.md" 2>/dev/null | awk '{print $1}' || shasum -a 256 "$TEST_PROJECT/CLAUDE.md" | awk '{print $1}')"
  manifest="$(grep "  CLAUDE.md$" "$rig_dir/memory/.rig-manifest" 2>/dev/null | awk '{print $1}')"
  [ -n "$manifest" ]
  [ "$actual" = "$manifest" ]
}

@test "agent-plan treats pre-498 raw-template manifest hashes as up to date when substituted content matches" {
  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking repo --strategy merge
  [ "$status" -eq 0 ]

  local rel raw_hash
  rel=".claude/commands/post-merge.md"
  raw_hash="$(sha256sum "$REPO_ROOT/templates/project/$rel" 2>/dev/null | awk '{print $1}' || shasum -a 256 "$REPO_ROOT/templates/project/$rel" | awk '{print $1}')"
  [ -n "$raw_hash" ]
  run grep -q '\[BASE_BRANCH\]' "$REPO_ROOT/templates/project/$rel"
  [ "$status" -eq 0 ]
  run grep -q '\[BASE_BRANCH\]' "$TEST_PROJECT/$rel"
  [ "$status" -ne 0 ]

  python3 - "$TEST_PROJECT/.rig/memory/.rig-manifest" "$TEST_PROJECT/.rig/memory/.rig-manifest.json" "$rel" "$raw_hash" <<'PYEOF'
import json
import sys

manifest, metadata, rel, raw_hash = sys.argv[1:]
lines = []
with open(manifest) as fh:
    for line in fh:
        if line.endswith(f"  {rel}\n"):
            lines.append(f"{raw_hash}  {rel}\n")
        else:
            lines.append(line)
with open(manifest, "w") as fh:
    fh.writelines(lines)

with open(metadata) as fh:
    doc = json.load(fh)
doc["entries"][rel]["sha256"] = raw_hash
with open(metadata, "w") as fh:
    json.dump(doc, fh, indent=2)
    fh.write("\n")
PYEOF

  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking repo --strategy agent-plan
  [ "$status" -eq 0 ]

  printf '%s\n' "$output" > "$TEMP_DIR/agent-plan.json"
  python3 - "$TEMP_DIR/agent-plan.json" "$rel" <<'PYEOF'
import json
import sys

doc = json.load(open(sys.argv[1]))
rel = sys.argv[2]
assert doc["status"] == "success"
entries = {a["path"]: a for a in doc["artifacts"]}
assert entries[rel]["classification"] == "up-to-date"
assert rel not in {c["path"] for c in doc["conflicts"]}
PYEOF
}
