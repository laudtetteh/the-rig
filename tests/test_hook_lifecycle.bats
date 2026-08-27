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

_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# Content+path snapshot of the target tree AND the external stealth .rig/
# dir (manifest lives there, not under TEST_PROJECT, in stealth mode). Used
# to prove agent-plan performs zero writes anywhere: two snapshots taken
# before/after a run must be byte-for-byte identical.
tree_snapshot() {
  find "$TEST_PROJECT" "$RIG_EXT" -type f 2>/dev/null | sort | xargs cksum 2>/dev/null
}

@test "stealth install tracks installed git hooks in the manifest" {
  install_stealth
  [ "$status" -eq 0 ]
  [ -x "$TEST_PROJECT/.git/hooks/pre-commit" ]
  grep -qF '.git/hooks/pre-commit' "$RIG_EXT/memory/.rig-manifest"
  grep -qF '.git/hooks/commit-msg' "$RIG_EXT/memory/.rig-manifest"
}

@test "a first-ever stealth git hook install journals a recovery record (retro-audit finding, found by the whole-branch review before merge)" {
  # Routing _stealth_install_git_hook() through upgrade_prepare_mutation()
  # for the symlink-refusal fix exposed a pre-existing gap in that shared
  # function: its "missing" branch never called ensure_upgrade_transaction()
  # / record_created() for ANY of its ~13 callers, not just the newly-routed
  # git-hook writer -- so a first-ever install left zero recovery record. If
  # the installer were killed mid-run, --recover would have nothing to roll
  # back to for a partially-written hook.
  install_stealth
  [ "$status" -eq 0 ]

  # The transaction must have been opened and finalized (not left
  # .in-progress), and the finalized journal must record at least one hook
  # as "created" -- proving this run actually journaled recovery state for
  # its first-ever hook writes, not just silently created them.
  #
  # A single project-only install opens more than one backup transaction
  # (each distinct `base` path passed to ensure_upgrade_transaction() gets
  # its own timestamped .rig-backup/<ts>_N dir and .journal), and the
  # git-hook "created" lines land in whichever one covers .git/hooks/. Search
  # every journal, not just the first one `find` happens to enumerate --
  # that enumeration order isn't guaranteed to put the hook-owning journal
  # first, which made this test flaky when it grabbed only `head -1`.
  [ ! -e "$TEST_PROJECT/.rig-backup/.in-progress" ]
  local journals
  journals="$(find "$TEST_PROJECT/.rig-backup" -name .journal -type f)"
  [ -n "$journals" ]
  echo "$journals" | xargs /usr/bin/grep -qE '^created[[:space:]]+\.git/hooks/pre-commit$'
}

@test "ordinary upgrade backs up a customized git hook before overwriting it" {
  install_stealth
  [ "$status" -eq 0 ]

  printf '#!/bin/sh\necho hand-written-hook-marker\n' > "$TEST_PROJECT/.git/hooks/pre-commit"
  chmod +x "$TEST_PROJECT/.git/hooks/pre-commit"

  install_stealth
  [ "$status" -eq 0 ]
  [[ "$output" == *"customized or unrecognized git hook detected: .git/hooks/pre-commit"* ]] || return 1

  # Ordinary mode keeps its existing overwrite behavior — the Rig hook wins...
  if grep -q 'hand-written-hook-marker' "$TEST_PROJECT/.git/hooks/pre-commit"; then return 1; fi
  # ...but the replaced content is now recoverable from a backup.
  run grep -rl 'hand-written-hook-marker' "$TEST_PROJECT/.rig-backup"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "a symlinked git hook is refused, never silently destroying its target (retro-audit finding, PR #451)" {
  # Before this fix, a symlinked .git/hooks/<name> matched neither of
  # _stealth_install_git_hook()'s backup-gating branches (both required
  # "not a symlink"), so no backup/journal happened, yet cp still ran --
  # cp follows an existing symlink and overwrites whatever it points to,
  # in place, even if that target lives entirely outside the project.
  install_stealth
  [ "$status" -eq 0 ]

  local external_target="$TEMP_DIR/external-hook-target.sh"
  printf '#!/bin/sh\necho this-file-lives-outside-the-project\n' > "$external_target"
  rm -f "$TEST_PROJECT/.git/hooks/pre-commit"
  ln -s "$external_target" "$TEST_PROJECT/.git/hooks/pre-commit"

  install_stealth
  [ "$status" -eq 0 ]

  # The external file must survive completely untouched.
  grep -q 'this-file-lives-outside-the-project' "$external_target"
  # The symlink itself must still point at it (never replaced with a
  # regular file copy of the Rig hook).
  [ -L "$TEST_PROJECT/.git/hooks/pre-commit" ]
  [[ "$(readlink "$TEST_PROJECT/.git/hooks/pre-commit")" == "$external_target" ]] || return 1
}

@test "a symlinked git hook is refused under --strategy merge too, not just upgrade (retro-audit finding, /rig-surface-review's first real run)" {
  # The test above proves symlink refusal under --strategy upgrade (this
  # file's install_stealth() helper hardcodes that strategy). It never
  # covered --strategy merge -- the actual default for every fresh
  # install -- and that gap hid a real regression: _stealth_install_git_
  # hook() routed its refusal check through upgrade_prepare_mutation(),
  # whose very first line is `[[ "$COLLISION_STRATEGY" == upgrade ]] ||
  # return 0`. Under merge (or skip/overwrite/interactive), that guard
  # silently no-ops the entire check -- no backup, no refusal -- and the
  # unconditional `cp` below it ran anyway, following the symlink and
  # overwriting whatever it pointed to, in place, even outside the
  # project. Fixed by extracting the check into guard_destination_before_
  # write() and calling that directly, unconditionally, instead of the
  # upgrade-only wrapper.
  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking stealth --rig-dir "$RIG_EXT" \
    --strategy merge
  [ "$status" -eq 0 ]

  local external_target="$TEMP_DIR/external-hook-target-merge.sh"
  printf '#!/bin/sh\necho this-file-lives-outside-the-project\n' > "$external_target"
  rm -f "$TEST_PROJECT/.git/hooks/pre-commit"
  ln -s "$external_target" "$TEST_PROJECT/.git/hooks/pre-commit"

  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking stealth --rig-dir "$RIG_EXT" \
    --strategy merge
  [ "$status" -eq 0 ]

  # The external file must survive completely untouched.
  grep -q 'this-file-lives-outside-the-project' "$external_target"
  # The symlink itself must still point at it (never replaced with a
  # regular file copy of the Rig hook).
  [ -L "$TEST_PROJECT/.git/hooks/pre-commit" ]
  readlink "$TEST_PROJECT/.git/hooks/pre-commit" | grep -qF "$external_target"
}

@test "a dangling symlinked git hook is refused without crashing the installer (retro-audit finding, PR #451)" {
  install_stealth
  [ "$status" -eq 0 ]

  rm -f "$TEST_PROJECT/.git/hooks/pre-commit"
  ln -s "$TEMP_DIR/does-not-exist.sh" "$TEST_PROJECT/.git/hooks/pre-commit"

  install_stealth
  [ "$status" -eq 0 ]
  [ -L "$TEST_PROJECT/.git/hooks/pre-commit" ]
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

# issue #458: agent-plan (AGENT_DRY_RUN=true) never called
# _stealth_install_git_hook() at all — the whole stealth hook-install loop
# lived inside the blanket "if AGENT_DRY_RUN != true" tracking-mode
# bookkeeping guard. So a customized hook that agent-upgrade correctly
# refuses on was invisible to agent-plan, which could report status:
# "success" right before agent-upgrade refused (exit 3) on the identical
# project. This test proves agent-plan now detects and reports the same
# conflict, with zero writes anywhere in the target tree.
@test "agent-plan detects a customized git hook and reports it in conflicts[] with zero writes (issue #458)" {
  install_stealth
  [ "$status" -eq 0 ]

  printf '#!/bin/sh\necho hand-written-hook-marker\n' > "$TEST_PROJECT/.git/hooks/pre-commit"
  chmod +x "$TEST_PROJECT/.git/hooks/pre-commit"

  local before after
  before="$(tree_snapshot)"

  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking stealth --rig-dir "$RIG_EXT" \
    --strategy agent-plan
  [ "$status" -eq 3 ]

  after="$(tree_snapshot)"
  [ "$before" = "$after" ]

  printf '%s\n' "$output" > "$TEMP_DIR/agent-plan-result.json"
  python3 -c "
import json
lines = [l for l in open('$TEMP_DIR/agent-plan-result.json') if l.strip()]
doc = json.loads(lines[-1])
assert doc['mode'] == 'plan', doc['mode']
assert doc['status'] == 'refused', doc['status']
paths = [c['path'] for c in doc['conflicts']]
assert '.git/hooks/pre-commit' in paths, paths
"

  # The hand-written hook must survive byte-identical — agent-plan never writes.
  grep -q 'hand-written-hook-marker' "$TEST_PROJECT/.git/hooks/pre-commit"
}

# Regression check: the agent-plan fix above must not change agent-upgrade's
# own (pre-existing, already-tested) refusal behavior on the same fixture.
@test "agent-upgrade on a customized git hook is unchanged: still refuses and preserves the hook byte-identical (issue #458 regression check)" {
  install_stealth
  [ "$status" -eq 0 ]

  printf '#!/bin/sh\necho hand-written-hook-marker\n' > "$TEST_PROJECT/.git/hooks/pre-commit"
  chmod +x "$TEST_PROJECT/.git/hooks/pre-commit"
  local before_hash
  before_hash="$(_sha256 "$TEST_PROJECT/.git/hooks/pre-commit")"

  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking stealth --rig-dir "$RIG_EXT" \
    --strategy agent-upgrade
  [ "$status" -eq 3 ]

  printf '%s\n' "$output" > "$TEMP_DIR/agent-upgrade-result.json"
  python3 -c "
import json
lines = [l for l in open('$TEMP_DIR/agent-upgrade-result.json') if l.strip()]
doc = json.loads(lines[-1])
assert doc['mode'] == 'apply', doc['mode']
assert doc['status'] == 'refused', doc['status']
paths = [c['path'] for c in doc['conflicts']]
assert '.git/hooks/pre-commit' in paths, paths
"

  local after_hash
  after_hash="$(_sha256 "$TEST_PROJECT/.git/hooks/pre-commit")"
  [ "$before_hash" = "$after_hash" ]
}

# Confirms the fix does not over-report: an unmodified, freshly-installed
# hook must classify as installed/convergeable, never appear in conflicts[].
@test "agent-plan on an unmodified git hook classifies it as installed, not a conflict, with zero writes" {
  install_stealth
  [ "$status" -eq 0 ]

  local before after
  before="$(tree_snapshot)"

  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking stealth --rig-dir "$RIG_EXT" \
    --strategy agent-plan

  after="$(tree_snapshot)"
  [ "$before" = "$after" ]

  # Exit code deliberately not asserted: [BASE_BRANCH]/[Project Name]
  # substitution running after write_manifest_entry() records the
  # pre-substitution hash is a documented, pre-existing false-positive
  # "customized" for unrelated process files (see this repo's CLAUDE.md
  # "Known gotchas"), which can push the overall run to refused/exit 3 for
  # reasons unrelated to hook handling. What matters here is narrower: the
  # untouched pre-commit hook specifically must not be reported as a
  # conflict.
  printf '%s\n' "$output" > "$TEMP_DIR/agent-plan-clean-result.json"
  python3 -c "
import json
lines = [l for l in open('$TEMP_DIR/agent-plan-clean-result.json') if l.strip()]
doc = json.loads(lines[-1])
entries = {a['path']: a for a in doc['artifacts']}
assert '.git/hooks/pre-commit' in entries, entries.keys()
assert entries['.git/hooks/pre-commit']['action'] != 'skip', entries['.git/hooks/pre-commit']
conflict_paths = [c['path'] for c in doc['conflicts']]
assert '.git/hooks/pre-commit' not in conflict_paths, conflict_paths
"
}

# issue #495: _stealth_install_git_hook() treated "no manifest entry" as
# an automatic customization, with no fallback comparison against the
# incoming hook content -- unlike _copy_file_upgrade()'s handling of every
# other Rig-owned file, which checks dest_hash == incoming_hash first. A
# hook installed by a pre-manifest-tracking Rig version (or one whose
# manifest entry was lost/never written) that still byte-for-byte matches
# the current template was permanently misreported as "customized" and
# stuck needing manual review forever, even though its content was never
# actually touched by hand. This test simulates that missing-baseline
# state directly (strip the manifest line after a normal install) and
# proves the fix falls back to a content comparison instead of assuming
# customization.
@test "agent-plan classifies a hook with no manifest baseline as up to date when its content already matches, not customized (issue #495)" {
  install_stealth
  [ "$status" -eq 0 ]

  # Simulate a hook installed before manifest tracking existed: same content
  # on disk, but no baseline entry recorded.
  grep -vF '.git/hooks/pre-commit' "$RIG_EXT/memory/.rig-manifest" > "$TEMP_DIR/manifest.tmp"
  mv "$TEMP_DIR/manifest.tmp" "$RIG_EXT/memory/.rig-manifest"
  if grep -qF '.git/hooks/pre-commit' "$RIG_EXT/memory/.rig-manifest"; then return 1; fi

  local before_hash
  before_hash="$(_sha256 "$TEST_PROJECT/.git/hooks/pre-commit")"

  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking stealth --rig-dir "$RIG_EXT" \
    --strategy agent-plan

  printf '%s\n' "$output" > "$TEMP_DIR/agent-plan-no-baseline-result.json"
  python3 -c "
import json
lines = [l for l in open('$TEMP_DIR/agent-plan-no-baseline-result.json') if l.strip()]
doc = json.loads(lines[-1])
entries = {a['path']: a for a in doc['artifacts']}
assert '.git/hooks/pre-commit' in entries, entries.keys()
assert entries['.git/hooks/pre-commit']['classification'] == 'up-to-date', entries['.git/hooks/pre-commit']
conflict_paths = [c['path'] for c in doc['conflicts']]
assert '.git/hooks/pre-commit' not in conflict_paths, conflict_paths
"

  # agent-plan never writes: the hook content must be untouched and the
  # manifest must still be missing the entry (only agent-upgrade would
  # actually record a fresh baseline).
  local after_hash
  after_hash="$(_sha256 "$TEST_PROJECT/.git/hooks/pre-commit")"
  [ "$before_hash" = "$after_hash" ]
  if grep -qF '.git/hooks/pre-commit' "$RIG_EXT/memory/.rig-manifest"; then return 1; fi
}

# Companion to the agent-plan test above: agent-upgrade (the real apply
# mode) must not just classify the no-baseline hook correctly but also
# heal the gap by writing a fresh manifest entry, so the false positive
# doesn't recur on every future run.
@test "agent-upgrade heals a hook with no manifest baseline by writing a fresh entry, without touching its content (issue #495)" {
  install_stealth
  [ "$status" -eq 0 ]

  grep -vF '.git/hooks/pre-commit' "$RIG_EXT/memory/.rig-manifest" > "$TEMP_DIR/manifest.tmp"
  mv "$TEMP_DIR/manifest.tmp" "$RIG_EXT/memory/.rig-manifest"
  if grep -qF '.git/hooks/pre-commit' "$RIG_EXT/memory/.rig-manifest"; then return 1; fi

  local before_hash
  before_hash="$(_sha256 "$TEST_PROJECT/.git/hooks/pre-commit")"

  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking stealth --rig-dir "$RIG_EXT" \
    --strategy agent-upgrade

  printf '%s\n' "$output" > "$TEMP_DIR/agent-upgrade-no-baseline-result.json"
  python3 -c "
import json
lines = [l for l in open('$TEMP_DIR/agent-upgrade-no-baseline-result.json') if l.strip()]
doc = json.loads(lines[-1])
entries = {a['path']: a for a in doc['artifacts']}
assert '.git/hooks/pre-commit' in entries, entries.keys()
assert entries['.git/hooks/pre-commit']['classification'] == 'up-to-date', entries['.git/hooks/pre-commit']
conflict_paths = [c['path'] for c in doc['conflicts']]
assert '.git/hooks/pre-commit' not in conflict_paths, conflict_paths
"

  local after_hash
  after_hash="$(_sha256 "$TEST_PROJECT/.git/hooks/pre-commit")"
  [ "$before_hash" = "$after_hash" ]
  grep -qF '.git/hooks/pre-commit' "$RIG_EXT/memory/.rig-manifest"
}

# Negative-case companion to the two tests above (flagged during independent
# review of issue #495's fix): a missing manifest baseline must NOT be
# treated as a free pass. When a hook has no manifest entry AND its content
# genuinely differs from the template, the fallback comparison must still
# resolve to customized -- proving the new fallback only waves through a
# true content match, not any hook that merely lacks a baseline.
@test "agent-upgrade still refuses a hand-edited hook with no manifest baseline, not waved through as up to date (issue #495)" {
  install_stealth
  [ "$status" -eq 0 ]

  printf '#!/bin/sh\necho hand-written-hook-marker\n' > "$TEST_PROJECT/.git/hooks/pre-commit"
  chmod +x "$TEST_PROJECT/.git/hooks/pre-commit"

  grep -vF '.git/hooks/pre-commit' "$RIG_EXT/memory/.rig-manifest" > "$TEMP_DIR/manifest.tmp"
  mv "$TEMP_DIR/manifest.tmp" "$RIG_EXT/memory/.rig-manifest"
  if grep -qF '.git/hooks/pre-commit' "$RIG_EXT/memory/.rig-manifest"; then return 1; fi

  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking stealth --rig-dir "$RIG_EXT" \
    --strategy agent-upgrade
  [ "$status" -eq 3 ]

  printf '%s\n' "$output" > "$TEMP_DIR/agent-upgrade-no-baseline-customized-result.json"
  python3 -c "
import json
lines = [l for l in open('$TEMP_DIR/agent-upgrade-no-baseline-customized-result.json') if l.strip()]
doc = json.loads(lines[-1])
assert doc['status'] == 'refused', doc['status']
paths = [c['path'] for c in doc['conflicts']]
assert '.git/hooks/pre-commit' in paths, paths
"

  # The hand-written hook must survive untouched.
  grep -q 'hand-written-hook-marker' "$TEST_PROJECT/.git/hooks/pre-commit"
  # And still no manifest entry -- agent-upgrade never writes one for a
  # refused/customized hook.
  if grep -qF '.git/hooks/pre-commit' "$RIG_EXT/memory/.rig-manifest"; then return 1; fi
}
