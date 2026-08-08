#!/usr/bin/env bats
#
# tests/test_strategy_lookahead_last_wins.bats — issue #483
#
# The early, standalone --strategy lookahead added for issue #476
# (_EARLY_AGENT_MODE, near the top of install.sh, before the real
# _FLAG_STRATEGY parser exists yet) only ever sets _EARLY_AGENT_MODE=true
# when it sees "agent-plan"/"agent-upgrade" immediately after a --strategy
# flag, anywhere in the argument list, and never resets it on a later
# --strategy occurrence with a different value ("seen-anywhere" semantics).
# The real _FLAG_STRATEGY parser further down the script is a plain
# forward-loop overwrite -- naturally last-wins, matching how every other
# flag in this script is parsed. A duplicated --strategy flag (e.g.
# "--strategy agent-plan --strategy merge") therefore left
# _EARLY_AGENT_MODE=true even though the run actually resolves to "merge",
# a normal human/CI-capable strategy -- silently suppressing the
# installer-behind-remote branch-drift warning for a run that isn't
# actually in agent mode.
#
# Fixed by making the early lookahead unconditionally reassign
# _EARLY_AGENT_MODE on every --strategy occurrence, matching the real
# parser's last-wins semantics.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
INSTALLER="$REPO_ROOT/install.sh"

setup() {
  TEMP_DIR="$(mktemp -d)"
  TEST_PROJECT="$TEMP_DIR/project"
  mkdir -p "$TEST_PROJECT"
  git -C "$TEST_PROJECT" init -q
  git -C "$TEST_PROJECT" config user.email test@test.com
  git -C "$TEST_PROJECT" config user.name Test

  # agent-plan/agent-upgrade classify against an existing installation --
  # establish a real baseline first, same as test_branch_drift_agent_guard.bats
  # (issue #476) and every other agent-contract test in this suite. Without
  # this, the postflight capability smoke check fails on a target that was
  # never installed at all, unrelated to anything this test is exercising.
  # Deliberately run without a drift-dir override so the baseline install
  # itself isn't affected by the mock-drift setup below.
  bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking repo --strategy upgrade >/dev/null 2>&1

  # A mock installer checkout that's genuinely behind its remote tracking
  # branch, per the existing _RIG_DRIFT_DIR test-override convention
  # documented in install.sh's own comment above the drift check (same
  # setup as tests/test_branch_drift_agent_guard.bats, issue #476).
  REMOTE="$TEMP_DIR/remote.git"
  DRIFT_REPO="$TEMP_DIR/drift-repo"
  AHEAD_REPO="$TEMP_DIR/ahead-repo"
  git init -q --bare "$REMOTE"

  git clone -q "$REMOTE" "$AHEAD_REPO"
  git -C "$AHEAD_REPO" config user.email test@test.com
  git -C "$AHEAD_REPO" config user.name Test
  git -C "$AHEAD_REPO" checkout -q -b main
  git -C "$AHEAD_REPO" commit -q --allow-empty -m "c1"
  git -C "$AHEAD_REPO" push -q -u origin main

  git clone -q "$REMOTE" "$DRIFT_REPO"
  git -C "$DRIFT_REPO" config user.email test@test.com
  git -C "$DRIFT_REPO" config user.name Test
  # A bare repo's HEAD symref is fixed at `git init --bare` time from
  # init.defaultBranch, independent of which branch is later pushed to it.
  # If the environment's default differs from "main" (observed on the
  # hosted CI runner, not reproducible on every local machine), this clone
  # cannot check out any working-tree branch at all ("remote HEAD refers
  # to nonexistent ref, unable to checkout") and leaves no local branch,
  # so @{u} never resolves and the drift check silently finds nothing to
  # report -- not a real product bug, a test-fixture gap. Force a local
  # main tracking origin/main explicitly so @{u} resolution is
  # environment-independent, regardless of the bare repo's HEAD symref.
  git -C "$DRIFT_REPO" checkout -q -B main --track origin/main

  # Push a second commit DRIFT_REPO hasn't fetched yet -- its own `git
  # fetch` inside the drift check will discover it and see itself as
  # behind by exactly 1 commit.
  git -C "$AHEAD_REPO" commit -q --allow-empty -m "c2"
  git -C "$AHEAD_REPO" push -q origin main
}

teardown() { rm -rf "$TEMP_DIR"; }

@test "a duplicated --strategy flag resolving to a non-agent strategy still shows the branch-drift warning (#483)" {
  run env _RIG_DRIFT_DIR="$DRIFT_REPO" \
    bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking repo \
    --strategy agent-plan --strategy merge
  [ "$status" -eq 0 ]
  [[ "$output" == *"behind"*"main"* ]] || [[ "$output" == *"is 1 commit(s) behind"* ]]
  [[ "$output" == *"Proceeding with the current version"* ]]
}

@test "a duplicated --strategy flag resolving to agent-upgrade still suppresses the branch-drift warning" {
  # Sanity check for the opposite direction: when the LAST --strategy
  # occurrence really is agent-plan/agent-upgrade, the drift check must
  # still be skipped exactly as issue #476 intended.
  run env _RIG_DRIFT_DIR="$DRIFT_REPO" \
    bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking repo \
    --strategy merge --strategy agent-plan
  [ "$status" -eq 0 ] || [ "$status" -eq 3 ]

  local nonblank_lines
  nonblank_lines="$(printf '%s\n' "$output" | /usr/bin/grep -c .)"
  [ "$nonblank_lines" -eq 1 ]
  [[ "$output" == \{* ]]
  printf '%s\n' "$output" | python3 -c 'import json, sys; json.load(sys.stdin)'
}
