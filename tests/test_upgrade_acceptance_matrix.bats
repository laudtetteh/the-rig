#!/usr/bin/env bats
#
# tests/test_upgrade_acceptance_matrix.bats — Regression coverage added while
# executing issue #455's combined acceptance-matrix validation sweep across
# every #444 lane (A through I, including #451's E+F+G consolidation).
#
# Existing per-lane test files already cover their own scope in isolation
# (tests/test_upgrade_recovery.bats constructs synthetic interrupted-journal
# states; tests/test_stale_manifest_layouts.bats and
# tests/test_hook_lifecycle.bats cover stealth/external stale-manifest and
# git-hook lifecycle each on their own). What none of them exercise is a REAL
# process interruption (an actual SIGKILL mid-run, not a hand-constructed
# .rig-backup/.in-progress/.journal) combined with the stealth+external
# tracking layout -- the highest-value combination the #455 validation
# matrix flagged as under-covered, since stealth+external resolves manifest
# and backup paths against a RIG_DIR outside TARGET, a genuinely different
# code path than repo/local tracking's single-root resolution.
#
# Run with: bats tests/test_upgrade_acceptance_matrix.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
INSTALLER="$REPO_ROOT/install.sh"

setup() {
  TEMP_DIR="$(mktemp -d)"
  TEST_PROJECT="$TEMP_DIR/project"
  TEST_RIGDIR="$TEMP_DIR/external-rig"
  mkdir -p "$TEST_PROJECT"
  git -C "$TEST_PROJECT" init -q
  git -C "$TEST_PROJECT" config user.email test@test.com
  git -C "$TEST_PROJECT" config user.name Test
}

teardown() { rm -rf "$TEMP_DIR"; }

run_installer() {
  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking stealth --rig-dir "$TEST_RIGDIR" \
    --project-agent claude "$@"
}

snapshot_tree() {
  find "$TEST_PROJECT" \( -path "$TEST_PROJECT/.git" -o -path "$TEST_PROJECT/.rig-backup" \) -prune -o \
    -type f -print | sort | while IFS= read -r file; do
      rel="${file#"$TEST_PROJECT"/}"
      hash="$(sha256sum "$file" 2>/dev/null | awk '{print $1}' || shasum -a 256 "$file" | awk '{print $1}')"
      printf '%s %s\n' "$hash" "$rel"
    done
}

# macOS ships no GNU `timeout`; background the process and SIGKILL it after a
# short delay instead, so this test is portable across the CI (Linux) and
# local (macOS/BSD) runners the verification.md checklist expects to work on
# both of.
kill_after() {
  local delay="$1"; shift
  "$@" >/dev/null 2>&1 &
  local pid=$!
  ( sleep "$delay"; kill -9 "$pid" 2>/dev/null ) &
  local killer=$!
  wait "$pid" 2>/dev/null || true
  kill "$killer" 2>/dev/null || true
  wait "$killer" 2>/dev/null || true
  return 0
}

@test "a real SIGKILL mid-upgrade under stealth+external tracking recovers cleanly via --recover" {
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]
  local baseline; baseline="$(snapshot_tree)"

  rm -f "$TEST_PROJECT/.claude/commands/status.md"
  kill_after 0.5 bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking stealth --rig-dir "$TEST_RIGDIR" \
    --project-agent claude --strategy upgrade

  run_installer --recover
  [ "$status" -eq 0 ]
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]

  local after; after="$(snapshot_tree)"
  [ "$baseline" = "$after" ]
}

@test "agent-upgrade converges a non-colliding customization under stealth+external tracking, not just repo" {
  run_installer --strategy upgrade --project-agent both
  [ "$status" -eq 0 ]

  # Same known pre-existing ordering issue documented in this repo's CLAUDE.md
  # ("`main` substitution runs after `write_manifest_entry`"): stabilize the
  # manifest baseline for the handful of affected files so this test isolates
  # only the convergence behavior under test, matching the pattern used by
  # tests/test_upgrade_agent_contract.bats and tests/test_convergence_engine.bats.
  local manifest="$TEST_RIGDIR/memory/.rig-manifest"
  local rel f hash
  for rel in CLAUDE.md .claude/commands/ship.md .claude/commands/post-merge.md; do
    f="$TEST_PROJECT/$rel"
    [ -f "$f" ] || continue
    hash="$(sha256sum "$f" 2>/dev/null | awk '{print $1}' || shasum -a 256 "$f" | awk '{print $1}')"
    grep -v "  ${rel}\$" "$manifest" > "$manifest.tmp" 2>/dev/null || cp "$manifest" "$manifest.tmp"
    printf '%s  %s\n' "$hash" "$rel" >> "$manifest.tmp"
    mv "$manifest.tmp" "$manifest"
  done
  for rel in processes/SHIP_WORKFLOW.md processes/POST_MERGE_WORKFLOW.md; do
    f="$TEST_RIGDIR/$rel"
    [ -f "$f" ] || continue
    hash="$(sha256sum "$f" 2>/dev/null | awk '{print $1}' || shasum -a 256 "$f" | awk '{print $1}')"
    grep -v "  \.rig/${rel}\$" "$manifest" > "$manifest.tmp" 2>/dev/null || cp "$manifest" "$manifest.tmp"
    printf '%s  .rig/%s\n' "$hash" "$rel" >> "$manifest.tmp"
    mv "$manifest.tmp" "$manifest"
  done

  local hooks="$TEST_PROJECT/.codex/hooks.json"
  [ -f "$hooks" ]
  python3 -c "
import json
p = '$hooks'
data = json.load(open(p))
data['userCustomKey'] = 'kept-by-user'
json.dump(data, open(p, 'w'), indent=2)
"

  run_installer --strategy agent-upgrade --project-agent both
  [ "$status" -eq 0 ]

  json_field() { printf '%s\n' "$output" | tail -1 | python3 -c "
import json, sys
d = json.load(sys.stdin)
print($1)
"; }
  [ "$(json_field "d['status']")" = "success" ]
  [ "$(json_field "d['summary']['converged']")" -ge 1 ]
  grep -q "kept-by-user" "$hooks"
}
