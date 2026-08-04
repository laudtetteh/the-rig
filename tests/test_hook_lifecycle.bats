#!/usr/bin/env bats
#
# tests/test_hook_lifecycle.bats — issue #444, lane 444-G
#
# Before this lane, stealth-mode .git/hooks/ installs were a plain `cp` with
# no manifest entry, no backup, and no customization check: a hand-written or
# third-party hook already living at .git/hooks/<name> was silently replaced,
# and there was nothing recorded to recover it from
# (docs/FULL_SCOPE_REVIEW_SYNTHESIS_444.md finding F-007).
#
# These tests prove:
#   - a first stealth install/upgrade tracks each installed hook in the
#     manifest (drift detection baseline for future runs);
#   - an ordinary (non-agent) upgrade keeps overwriting a customized hook
#     unchanged in outcome, but now backs it up first;
#   - agent-upgrade mode never overwrites a customized hook — it refuses and
#     reports the path in conflicts[], instead of the previous silent
#     replacement.

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

install_stealth() {
  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking stealth --rig-dir "$RIG_EXT" \
    --strategy upgrade
}

@test "stealth install tracks installed git hooks in the manifest" {
  install_stealth
  [ "$status" -eq 0 ]
  [ -x "$TEST_PROJECT/.git/hooks/pre-commit" ]
  grep -qF '.git/hooks/pre-commit' "$RIG_EXT/memory/.rig-manifest"
  grep -qF '.git/hooks/commit-msg' "$RIG_EXT/memory/.rig-manifest"
}

@test "ordinary upgrade backs up a customized git hook before overwriting it" {
  install_stealth
  [ "$status" -eq 0 ]

  printf '#!/bin/sh\necho hand-written-hook-marker\n' > "$TEST_PROJECT/.git/hooks/pre-commit"
  chmod +x "$TEST_PROJECT/.git/hooks/pre-commit"

  install_stealth
  [ "$status" -eq 0 ]
  [[ "$output" == *"customized or unrecognized git hook detected: .git/hooks/pre-commit"* ]]

  # Ordinary mode keeps its existing overwrite behavior — the Rig hook wins...
  ! grep -q 'hand-written-hook-marker' "$TEST_PROJECT/.git/hooks/pre-commit"
  # ...but the replaced content is now recoverable from a backup.
  run grep -rl 'hand-written-hook-marker' "$TEST_PROJECT/.rig-backup"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "agent-upgrade refuses to overwrite a customized git hook and reports a conflict" {
  install_stealth
  [ "$status" -eq 0 ]

  printf '#!/bin/sh\necho hand-written-hook-marker\n' > "$TEST_PROJECT/.git/hooks/pre-commit"
  chmod +x "$TEST_PROJECT/.git/hooks/pre-commit"

  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking stealth --rig-dir "$RIG_EXT" \
    --strategy agent-upgrade
  [ "$status" -eq 3 ]

  # Refused status, with the hook explicitly named in conflicts[]. $output is
  # raw JSON (plus a couple of narrative lines) — write it to a file rather
  # than interpolating it into a python -c string, since it's full of double
  # quotes that would otherwise break the shell's own quoting.
  printf '%s\n' "$output" > "$TEMP_DIR/agent-result.json"
  python3 -c "
import json
lines = [l for l in open('$TEMP_DIR/agent-result.json') if l.strip()]
doc = json.loads(lines[-1])
assert doc['status'] == 'refused', doc['status']
paths = [c['path'] for c in doc['conflicts']]
assert '.git/hooks/pre-commit' in paths, paths
"

  # The hand-written hook must survive untouched — agent mode never overwrites it.
  grep -q 'hand-written-hook-marker' "$TEST_PROJECT/.git/hooks/pre-commit"
}

@test "agent-upgrade leaves an unmodified Rig-installed hook classified up to date" {
  install_stealth
  [ "$status" -eq 0 ]

  # Exit code is deliberately not asserted here: [BASE_BRANCH]/[Project Name]
  # substitution runs after write_manifest_entry() records the pre-
  # substitution hash, which the project's own CLAUDE.md documents as a known
  # false-positive "Customized file detected" for process files — unrelated
  # to hook handling, and not something this lane changes. That alone can
  # push the run to refused/exit 3. What this test asserts is narrower: the
  # untouched pre-commit hook specifically is classified as installed, not
  # skipped as customized.
  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking stealth --rig-dir "$RIG_EXT" \
    --strategy agent-upgrade

  printf '%s\n' "$output" > "$TEMP_DIR/agent-result.json"
  python3 -c "
import json
lines = [l for l in open('$TEMP_DIR/agent-result.json') if l.strip()]
doc = json.loads(lines[-1])
entries = {a['path']: a for a in doc['artifacts']}
assert '.git/hooks/pre-commit' in entries, entries.keys()
assert entries['.git/hooks/pre-commit']['action'] != 'skip', entries['.git/hooks/pre-commit']
"
}
